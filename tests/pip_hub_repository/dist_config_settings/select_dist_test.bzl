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

load("@bazel_skylib//lib:selects.bzl", "selects")
load("@rules_testing//lib:analysis_test.bzl", "analysis_test")
load("@rules_testing//lib:test_suite.bzl", "test_suite")
load("@rules_testing//lib:truth.bzl", "subjects")
load("@rules_testing//lib:util.bzl", rt_util = "util")
load("//python/private:dist_config_settings.bzl", "dist_config_settings")
load("//python/private:render_pkg_aliases.bzl", "whl_select_dict")
load("//python/private:text_util.bzl", "render")

_PLATFORMS = [
    "manylinux1_x86_64",
    "manylinux_2_27_aarch64",
    "musllinux_1_1_x86_64",
    "musllinux_1_1_aarch64",
    "macosx_12_0_universal2",
    "macosx_12_0_aarch64",
    "macosx_12_0_x86_64",
    "win_amd64",
]

_tests = []

def _subject_impl(ctx):
    _ = ctx  # @unused
    return [DefaultInfo()]

_subject = rule(
    implementation = _subject_impl,
    attrs = {
        "all_dists_match": attr.string(),
        "any_match": attr.string(),
        "sdist_match": attr.string(),
    },
)

def _test_library_matching(name, test):
    select_values = {}
    dists = [
        (
            "foo-0.0.1{}".format(suffix),
            [
                ("3.11", None),
                ("3.12", None),
            ] if "-cp311-" not in suffix else [
                ("3.11", None),
            ],
        )
        for suffix in [
            ".tar.gz",
            "-py3-none-any.whl",
            #"-py3-abi3-any.whl",
        ] + [
            "-" + "-".join([py, abi_tag, platform + ".whl"])
            for py in ["py3"]
            # Let's simulate not all whls being available on cp312
            for abi_tag in ["none", "abi3", "cp311"]
            for platform in _PLATFORMS
        ]
    ]

    attr_dists = {
        "all_dists_match": dists,
        "any_match": [
            (
                "foo-0.0.1-py2.py3-none-any.whl",
                [
                    ("3.11", None),
                    ("3.12", None),
                ],
            ),
            (
                "foo-0.0.1.tar.gz",
                [
                    ("3.11", None),
                    ("3.12", None),
                ],
            ),
        ],
        "sdist_match": [
            (
                "foo-0.0.1.tar.gz",
                [
                    ("3.11", None),
                ],
            ),
        ],
    }
    for attr, dists in attr_dists.items():
        if attr not in test.attrs:
            continue
        select_value, _ = whl_select_dict(
            hub_name = "hub",
            default_version = "3.11",
            target_name = "pkg",
            dists = dists,
            condition_package = Label(":unused").package,
        )
        if getattr(test, "debug", None):
            print("Value of the dict:\n" + render.dict(
                select_value,
                key_repr = lambda x: render.tuple(x) if type(x) != type("") else repr(x),
            ))
        select_values[attr] = {
            tuple(v) if len(v) > 1 else v[0]: k
            for k, v in select_value.items()
        }

    rt_util.helper_target(
        _subject,
        name = name + "_subject",
        **{
            k: selects.with_or(v)
            for k, v in select_values.items()
        }
    )

    config_settings = {
        "cp311_linux_aarch64": {
            Label("//python/config_settings:python_version"): "3.11.1",
            "//command_line_option:platforms": Label(":linux_aarch64"),
        },
        "cp311_linux_aarch64_sdist": {
            Label(":whl"): "no",
            Label("//python/config_settings:python_version"): "3.11.1",
            "//command_line_option:platforms": Label(":linux_aarch64"),
        },
        "cp312_osx_aarch64": {
            Label("//python/config_settings:python_version"): "3.12.1",
            "//command_line_option:platforms": Label(":osx_aarch64"),
        },
        "linux_aarch64": {
            "//command_line_option:platforms": Label(":linux_aarch64"),
        },
        "linux_aarch64_musl": {
            Label(":whl_linux_libc"): "musl",
            "//command_line_option:platforms": Label(":linux_aarch64"),
        },
        "osx_aarch64_any": {
            Label(":whl_plat"): "no",
            "//command_line_option:platforms": Label(":osx_aarch64"),
        },
        "osx_aarch64_any_abi_none": {
            Label(":whl_abi3"): "no",
            Label(":whl_cpxy"): "no",
            Label(":whl_plat"): "no",
            "//command_line_option:platforms": Label(":osx_aarch64"),
        },
        "osx_aarch64_multiarch": {
            Label(":whl_osx_arch"): "multi",
            "//command_line_option:platforms": Label(":osx_aarch64"),
        },
    }

    analysis_test(
        name = name,
        target = name + "_subject",
        impl = test.expect,
        config_settings = {
            str(k): str(v)
            for k, v in config_settings[test.setting].items()
        },
    )

def _match(env, target, expect):
    target = env.expect.that_target(target)
    for attr, want in expect.items():
        target.attr(attr, factory = subjects.str).equals(want)

def _test_matching_defaults(name):
    _test_library_matching(
        name = name,
        test = struct(
            name = "selecting an any wheel by default",
            setting = "linux_aarch64",
            attrs = [
                "any_match",
                "all_dists_match",
                "sdist_match",
            ],
            expect = lambda env, target: _match(env, target, {
                "all_dists_match": "@hub_foo_0_0_1_py3_cp311_manylinux_2_27_aarch64//:pkg",
                "any_match": "@hub_foo_0_0_1_py3_none_any//:pkg",
                "sdist_match": "@hub_foo_0_0_1_sdist//:pkg",
            }),
        ),
    )

_tests.append(_test_matching_defaults)

def _test_matching_with_py_version(name):
    _test_library_matching(
        name = name,
        test = struct(
            name = "selecting an any wheel by default",
            setting = "cp311_linux_aarch64",
            attrs = [
                "any_match",
                "sdist_match",
            ],
            expect = lambda env, target: _match(env, target, {
                "any_match": "@hub_foo_0_0_1_py3_none_any//:pkg",
                "sdist_match": "@hub_foo_0_0_1_sdist//:pkg",
            }),
        ),
    )

_tests.append(_test_matching_with_py_version)

def _test_using_sdists(name):
    _test_library_matching(
        name = name,
        test = struct(
            setting = "cp311_linux_aarch64_sdist",
            attrs = [
                "all_dists_match",
                "sdist_match",
            ],
            expect = lambda env, target: _match(env, target, {
                "all_dists_match": "@hub_foo_0_0_1_sdist//:pkg",
                "sdist_match": "@hub_foo_0_0_1_sdist//:pkg",
            }),
        ),
    )

_tests.append(_test_using_sdists)

def _test_using_osx_fat_wheels(name):
    _test_library_matching(
        name = name,
        test = struct(
            setting = "osx_aarch64_multiarch",
            attrs = [
                "any_match",
                "all_dists_match",
                "sdist_match",
            ],
            expect = lambda env, target: _match(env, target, {
                "all_dists_match": "@hub_foo_0_0_1_py3_cp311_macosx_12_0_universal2//:pkg",
                "any_match": "@hub_foo_0_0_1_py3_none_any//:pkg",
                "sdist_match": "@hub_foo_0_0_1_sdist//:pkg",
            }),
        ),
    )

_tests.append(_test_using_osx_fat_wheels)

def _test_prefer_any_whls(name):
    _test_library_matching(
        name = name,
        test = struct(
            setting = "osx_aarch64_any",
            attrs = [
                "any_match",
                "all_dists_match",
                "sdist_match",
            ],
            expect = lambda env, target: _match(env, target, {
                "all_dists_match": "@hub_foo_0_0_1_py3_none_any//:pkg",
                "any_match": "@hub_foo_0_0_1_py3_none_any//:pkg",
                "sdist_match": "@hub_foo_0_0_1_sdist//:pkg",
            }),
        ),
    )

_tests.append(_test_prefer_any_whls)

def _test_using_musl_wheels(name):
    _test_library_matching(
        name = name,
        test = struct(
            setting = "linux_aarch64_musl",
            attrs = [
                "any_match",
                "all_dists_match",
                "sdist_match",
            ],
            expect = lambda env, target: _match(env, target, {
                "all_dists_match": "@hub_foo_0_0_1_py3_cp311_musllinux_1_1_aarch64//:pkg",
                "any_match": "@hub_foo_0_0_1_py3_none_any//:pkg",
                "sdist_match": "@hub_foo_0_0_1_sdist//:pkg",
            }),
        ),
    )

_tests.append(_test_using_musl_wheels)

def _test_prefer_abi_none_whls(name):
    _test_library_matching(
        name = name,
        test = struct(
            setting = "osx_aarch64_any_abi_none",
            attrs = [
                "any_match",
                "all_dists_match",
                "sdist_match",
            ],
            expect = lambda env, target: _match(env, target, {
                "all_dists_match": "@hub_foo_0_0_1_py3_none_any//:pkg",
                "any_match": "@hub_foo_0_0_1_py3_none_any//:pkg",
                "sdist_match": "@hub_foo_0_0_1_sdist//:pkg",
            }),
        ),
    )

_tests.append(_test_prefer_abi_none_whls)

def _test_new_version_of_python(name):
    _test_library_matching(
        name = name,
        test = struct(
            setting = "cp312_osx_aarch64",
            attrs = [
                "any_match",
                "all_dists_match",
                "sdist_match",
            ],
            expect = lambda env, target: _match(env, target, {
                "all_dists_match": "@hub_foo_0_0_1_py3_abi3_macosx_12_0_aarch64//:pkg",
                "any_match": "@hub_foo_0_0_1_py3_none_any//:pkg",
                "sdist_match": "@hub_foo_0_0_1_sdist//:pkg",
            }),
        ),
    )

_tests.append(_test_new_version_of_python)

def select_dist_test_suite(name):  # buildifier: disable=function-docstring
    test_suite(
        name = name,
        tests = _tests,
    )
    dist_config_settings(
        name = "config",
        python_versions = ["3.11", "3.12"],
        whl_platforms = _PLATFORMS,
    )

    native.platform(
        name = "linux_aarch64",
        constraint_values = [
            "@platforms//os:linux",
            "@platforms//cpu:aarch64",
        ],
    )

    native.platform(
        name = "osx_aarch64",
        constraint_values = [
            "@platforms//os:osx",
            "@platforms//cpu:aarch64",
        ],
    )

    native.platform(
        name = "win_aarch64",
        constraint_values = [
            "@platforms//os:windows",
            "@platforms//cpu:aarch64",
        ],
    )
