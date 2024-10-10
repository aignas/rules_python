# Copyright 2024 The Bazel Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
"""Tests for construction of Python version matching config settings."""

load("@rules_testing//lib:analysis_test.bzl", "analysis_test")
load("@rules_testing//lib:test_suite.bzl", "test_suite")
load("@rules_testing//lib:truth.bzl", "subjects")
load("@rules_testing//lib:util.bzl", test_util = "util")
load("//python/private/pypi:env_marker_feature_flag.bzl", "env_marker_feature_flag")  # buildifier: disable=bzl-visibility

def _subject_impl(ctx):
    _ = ctx  # @unused
    return [DefaultInfo()]

_subject = rule(
    implementation = _subject_impl,
    attrs = {
        "dist": attr.string(),
    },
)

_flag = struct(
    platform = lambda x: ("//command_line_option:platforms", str(Label("//tests/support:" + x))),
    pip_whl = lambda x: (str(Label("//python/config_settings:pip_whl")), str(x)),
    pip_whl_glibc_version = lambda x: (str(Label("//python/config_settings:pip_whl_glibc_version")), str(x)),
    pip_whl_muslc_version = lambda x: (str(Label("//python/config_settings:pip_whl_muslc_version")), str(x)),
    pip_whl_osx_version = lambda x: (str(Label("//python/config_settings:pip_whl_osx_version")), str(x)),
    pip_whl_osx_arch = lambda x: (str(Label("//python/config_settings:pip_whl_osx_arch")), str(x)),
    py_linux_libc = lambda x: (str(Label("//python/config_settings:py_linux_libc")), str(x)),
    python_version = lambda x: (str(Label("//python/config_settings:python_version")), str(x)),
)

def _analysis_test(*, name, dist, want, config_settings = [_flag.platform("linux_aarch64")]):
    subject_name = name + "_subject"
    test_util.helper_target(
        _subject,
        name = subject_name,
        dist = select(
            dist | {
                "//conditions:default": "no_match",
            },
        ),
    )
    config_settings = dict(config_settings)
    if not config_settings:
        fail("For reproducibility on different platforms, the config setting must be specified")
    python_version, default_value = _flag.python_version("3.7.10")
    config_settings.setdefault(python_version, default_value)

    analysis_test(
        name = name,
        target = subject_name,
        impl = lambda env, target: _match(env, target, want),
        config_settings = config_settings,
    )

def _match(env, target, want):
    target = env.expect.that_target(target)
    target.attr("dist", factory = subjects.str).equals(want)

_tests = []

def test_simple(name):
    _analysis_test(
        name = name,
        dist = {
            ":is_python_lt_39": "foo",
        },
        want = "foo",
        config_settings = [
            _flag.python_version("3.8"),
            _flag.platform("linux_x86_64"),
        ],
    )

_tests.append(test_simple)

def env_marker_feature_flag_test_suite(name):  # buildifier: disable=function-docstring
    test_suite(
        name = name,
        tests = _tests,
    )

    env_marker_feature_flag(
        name = "python_lt_39",
        marker = 'python_version < "3.9"',
        # The following could be set in a different rule and we could have a target //python/private/pypi:target_env
        os_name = select({
            "@platforms//os:windows": "nt",
            "@platforms//os:linux": "posix",
            "@platforms//os:osx": "posix",
            "//conditions:default": "",
        }),
        sys_platform = select({
            "@platforms//os:windows": "win32",
            "@platforms//os:linux": "posix",
            "@platforms//os:osx": "darwin",
            "//conditions:default": "",
        }),
        platform_system = select({
            "@platforms//os:windows": "Windows",
            "@platforms//os:linux": "Linux",
            "@platforms//os:osx": "Darwin",
            "//conditions:default": "",
        }),
        platform_machine = select({
            "@platforms//cpu:x86_64": "x86_64",
            # TODO @aignas 2024-10-10: handle the cases where we need os and arch tuples
            "@platforms//cpu:x86_32": "i386",
            "@platforms//cpu:ppc": "ppc64le",
            "@platforms//cpu:s390x": "s390x",
            "@platforms//cpu:aarch64": "aarch64",
            "//conditions:default": "",
        }),
    )
    native.config_setting(
        name = "is_python_lt_39",
        flag_values = {
            ":python_lt_39": "yes",
        },
    )

# # NOTE @aignas 2023-12-05: below is the minimum number of accessors that are defined in
# # https://peps.python.org/pep-0496/ to make rules_python generate dependencies.
# #
# # WARNING: It may not work in cases where the python implementation is different between
# # different platforms.
# 
# # derived from OS
# 
# # derived from OS and Arch
# @property
# def platform_machine(self) -> str:
#     if self.arch == Arch.x86_64:
#         return "x86_64"
#     elif self.arch == Arch.x86_32 and self.os != OS.osx:
#         return "i386"
#     elif self.arch == Arch.x86_32:
#         return ""
#     elif self.arch == Arch.aarch64 and self.os == OS.linux:
#         return "aarch64"
#     elif self.arch == Arch.aarch64:
#         # Assuming that OSX and Windows use this one since the precedent is set here:
#         # https://github.com/cgohlke/win_arm64-wheels
#         return "arm64"
#     elif self.os != OS.linux:
#         return ""
#     elif self.arch == Arch.ppc64le:
#         return "ppc64le"
#     elif self.arch == Arch.s390x:
#         return "s390x"
#     else:
#         return ""
# 
# def env_markers(self, extra: str) -> Dict[str, str]:
#     # If it is None, use the host version
#     minor_version = self.minor_version or host_interpreter_minor_version()
# 
#     return {
#         "extra": extra,
#         "os_name": self.os_name,
#         "sys_platform": self.sys_platform,
#         "platform_machine": self.platform_machine,
#         "platform_system": self.platform_system,
#         "platform_release": "",  # unset
#         "platform_version": "",  # unset
#         "python_version": f"3.{minor_version}",
#         # FIXME @aignas 2024-01-14: is putting zero last a good idea? Maybe we should
#         # use `20` or something else to avoid having weird issues where the full version is used for
#         # matching and the author decides to only support 3.y.5 upwards.
#         "implementation_version": f"3.{minor_version}.0",
#         "python_full_version": f"3.{minor_version}.0",
#         # we assume that the following are the same as the interpreter used to setup the deps:
#         # "implementation_name": "cpython"
#         # "platform_python_implementation: "CPython",
#     }
# },
