# Description: This file has all the functions to construct unity tests
"""
This file contains so called macros which are just functions written
in skylark (googles own constraint subset of python). For a quick
summary of what is different between python and skylark see:
https://docs.bazel.build/versions/master/skylark/language.html
"""

# i guess this could be done more elegant using the File class but it does what we want
def strip_extension(file_name):
    return file_name[0:-2]

def runner_base_name(file_name):
    return strip_extension(file_name) + "_Runner"

def runner_file_name(file_name):
    return runner_base_name(file_name) + ".c"

def mock_module_name(file_name):
    package_name = file_name.split(":")[0]
    label_name = file_name.split(":")[1]
    return package_name + ":Mock" + strip_extension(label_name)

"""
Use the helper scripts shipped with unity to
generate a test runner for the specified file.
The genrule used here executes cmd to produce
the files specified in the outs attribute.
In the tools attribute we need to specify all the
files, that are needed during the execution of cmd.

srcs lists all input files and outs all output files.

Side fact:
The cmd is executed in bash.
The $(location ...) and $(SRC),$(OUTS) stuff is expanded
before handing it over to bash.

More Info:
https://docs.bazel.build/versions/master/be/general.html#genrule
"""
def generate_test_runner(file_name, visibility=None):
    native.genrule(
        name = runner_base_name(file_name),
        srcs = [file_name],
        outs = [runner_file_name(file_name)],
        cmd = "ruby $(location @Unity//:TestRunnerGenerator) $(SRCS) $(OUTS)",
        tools = ["@Unity//:TestRunnerGenerator",
                 "@Unity//:HelperScripts"],
        visibility = visibility,
    )

"""
This macro creates a cc_test rule and a genrule (that creates
the test runner) for a given file.
It adds unity as dependency so the user doesn't have to do it himself.
Additional dependencies can be specified using the deps parameter.

The source files for the test are only the *_Test.c that the user writes
and the corresponding generated *_Test_Runner.c file.
"""
def unity_test(file_name, deps=[], mocks=[], copts=[], size="small", linkopts=[], visibility=None, additional_srcs=[]):
    for target in mocks:
        mock_name = mock_module_name(target)
        deps = deps + [mock_name]   # add created mock to testing dependencies
    generate_test_runner(file_name, visibility)
    native.cc_test(
        name = strip_extension(file_name),
        srcs = [file_name, runner_file_name(file_name)] + additional_srcs,
        visibility = visibility,
        deps = deps + ["@Unity//:Unity"],
        size = size,
        linkopts = linkopts,
        copts = copts,
    )

def generate_mocks_for_every_header(file_list=[], deps=[], visibility=None, copts=[]):
    for target in file_list:
        mock_name = mock_module_name(target)
        mock(
            name = mock_name,
            file = target,
            deps = deps,
            visibility = visibility,
            copts = copts
        )

"""
Convenience macro that generates a unity test for every file in a given list
using the same parameters.
"""
def generate_a_unity_test_for_every_file(file_list, deps=[], mocks=[], copts=None, linkopts=None, size="small", visibility=None):
    for file in file_list:
        unity_test(
            file_name = file,
            deps = deps,
            mocks = mocks,
            visibility = visibility,
            copts = copts,
            size = size,
            linkopts = linkopts,
        )

def _replace_extension_with(file_path, replacement):
  file_path_without_extension = file_path.rsplit(".")[0]
  new_file_path = ".".join([file_path_without_extension, replacement])
  return new_file_path

def _generate_mock_srcs_impl(ctx):
  delimiter = "/"
  mock_hdr = ctx.outputs.mock_hdr
  mock_src = ctx.outputs.mock_src
  input = ctx.files.srcs[0]
  unity_helpers = ctx.attr._unity
  unity_env = unity_helpers.label.workspace_root
  original_hdr_path = input.path
  subdir = ctx.files.srcs[0].dirname
  mock_generator = ctx.file._cmock_generator
  mock_helpers = ctx.files._cmock_helper_scripts
  plugins_argument = "--plugins="
  mock_path = delimiter.join([ctx.genfiles_dir.path, ctx.label.package, "mocks"])
  for plugin_name in ctx.attr.plugins:
    plugins_argument += plugin_name + ";"

  arguments = [mock_generator.path,
               "--mock_path="+mock_path,
               "--subdir=" + subdir,
               plugins_argument,
               original_hdr_path]

  ctx.actions.run(
      outputs = [mock_src, mock_hdr],
      inputs = [input]+ unity_helpers.files.to_list() + mock_helpers,
      executable = "ruby",
      env = {"UNITY_DIR": unity_env},
      arguments = arguments,
  )


def _construct_mock_output(srcs, deps=None):
    delimiter = "/"
    hdr = srcs[0]
    hdr_basename = hdr.name.split(delimiter)[-1]
    hdr_dir_relative_to_package = hdr.name.rstrip(hdr_basename).rstrip(delimiter)
    path_name_parts = ["mocks", hdr.package, hdr_dir_relative_to_package, "Mock"];
    prefix = delimiter.join(path_name_parts).replace("//", "/");
    hdr_path = prefix + _replace_extension_with(hdr_basename, "h")
    src_path = prefix + _replace_extension_with(hdr_basename, "c")
    dict = {"mock_hdr": hdr_path, "mock_src": src_path}
    return dict


generate_mock_srcs = rule(
    implementation=_generate_mock_srcs_impl,
    attrs = {"srcs": attr.label_list(mandatory=True, allow_files=[".h"]),
             "deps": attr.label(default=None),
             "plugins": attr.string_list(default=["ignore", "ignore_arg", "expect_any_args", "cexception", "callback", "return_thru_ptr", "array"]),
             "_unity": attr.label(default="@Unity//:HelperScripts"),
             "_cmock_generator": attr.label(default="@CMock//:MockGenerator", allow_single_file=[".rb"]),
             "_cmock_helper_scripts": attr.label(default="@CMock//:HelperScripts", allow_files=[".rb"]),
             },
    outputs= _construct_mock_output,
    output_to_genfiles=True,

)

def mock(name, file, deps=[], visibility=None, copts=[]):
  target_name = name.split(":")[-1]
  native.cc_library(
      name =  target_name + "OriginalHdrLib",
      hdrs = [file],
      linkstatic = 1,
  )
  generate_mock_srcs(
      name = target_name + "Srcs",
      srcs = [file],
  )
  native.cc_library(
      name = target_name,
      srcs = [target_name+"Srcs"],
      hdrs = [target_name+"Srcs"],
      strip_include_prefix = "mocks",
	  copts = copts,
      deps = [
          "@Unity//:Unity",
          "@CMock//:CMock",
          "@CException//:CException",
          target_name.split(":")[-1] + "OriginalHdrLib",
      ] + deps,
      visibility = visibility,
  )
