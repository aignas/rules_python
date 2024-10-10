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
_given = []

_given.append(("is_python_lt_39", "python_version < '3.9'"))

def test_simple(name):
    _analysis_test(
        name = name,
        dist = {":is_python_lt_39": "foo"},
        want = "foo",
        config_settings = [_flag.python_version("3.8")],
    )

_tests.append(test_simple)

_given.append(("is_python_gt_39", "python_version > '3.9'"))

def test_simple_2(name):
    _analysis_test(
        name = name,
        dist = {":is_python_gt_39": "foo"},
        want = "no_match",
        config_settings = [_flag.python_version("3.8")],
    )

_tests.append(test_simple_2)

def env_marker_feature_flag_test_suite(name):  # buildifier: disable=function-docstring
    test_suite(
        name = name,
        tests = _tests,
    )

    for name, marker in _given:
        env_marker_feature_flag(
            name = "_" + name,
            marker = marker,
        )
        native.config_setting(
            name = name,
            flag_values = {":_" + name: "yes"},
        )
