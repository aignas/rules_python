# Copyright 2023 The Bazel Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""render_pkg_aliases tests"""

load("@rules_testing//lib:test_suite.bzl", "test_suite")
load("//python/private:render_pkg_aliases.bzl", "whl_alias", "whl_select_dict")  # buildifier: disable=bzl-visibility

_tests = []

def _test_select_dict_legacy(env):
    got, _ = whl_select_dict(
        hub_name = "hub",
        default_version = None,
        target_name = "pkg",
        versions = [
            whl_alias(repo = "foo"),
        ],
    )
    env.expect.that_str(got).equals("@foo//:pkg")

_tests.append(_test_select_dict_legacy)

def _test_select_dict_bzlmod(env):
    got, _ = whl_select_dict(
        hub_name = "hub",
        default_version = None,
        target_name = "pkg",
        versions = [
            whl_alias(repo = "foo", version = "3.1"),
            whl_alias(repo = "bar", version = "3.2"),
        ],
    )
    env.expect.that_dict(got).contains_exactly({
        "@bar//:pkg": ["//:is_python_3.2"],
        "@foo//:pkg": ["//:is_python_3.1"],
    })

_tests.append(_test_select_dict_bzlmod)

def _test_select_dict_with_default(env):
    got, _ = whl_select_dict(
        hub_name = "hub",
        default_version = "3.1",
        target_name = "pkg",
        versions = [
            whl_alias(repo = "foo", version = "3.1"),
            whl_alias(repo = "bar", version = "3.2"),
        ],
    )
    env.expect.that_dict(got).contains_exactly({
        "@bar//:pkg": ["//:is_python_3.2"],
        "@foo//:pkg": ["//:is_python_3.1", "//conditions:default"],
    })

_tests.append(_test_select_dict_with_default)

def _test_select_dist_sdist_only(env):
    got, _ = whl_select_dict(
        hub_name = "hub",
        default_version = "3.1",
        target_name = "pkg",
        dists = {
            a.filename: [(a.version, "")]
            for a in [
                whl_alias(version = "3.1", filename = "foo-0.0.1.tar.gz"),
            ]
        },
    )
    env.expect.that_dict(got).contains_exactly({
        "@hub_foo_0_0_1_sdist//:pkg": [
            "//:is_python_3.1",
            "//:is_python_3.1_sdist",
            "//:is_sdist",
            "//conditions:default",
        ],
    })

_tests.append(_test_select_dist_sdist_only)

def _test_select_dist_whl_sdist(env):
    got, _ = whl_select_dict(
        hub_name = "hub",
        default_version = "3.1",
        target_name = "pkg",
        dists = {
            a.filename: [(a.version, "")]
            for a in [
                whl_alias(version = "3.1", filename = "foo-0.0.1.tar.gz"),
                whl_alias(version = "3.1", filename = "foo-0.0.1-py3-none-any.whl"),
            ]
        },
    )
    env.expect.that_dict(got).contains_exactly({
        "@hub_foo_0_0_1_py3_none_any//:pkg": [
            "//:is_python_3.1",
            "//:is_python_3.1_whl",
            "//:is_whl",
            "//conditions:default",
        ],
        "@hub_foo_0_0_1_sdist//:pkg": [
            "//:is_python_3.1_sdist",
            "//:is_sdist",
        ],
    })

_tests.append(_test_select_dist_whl_sdist)

def whl_select_dict_test_suite(name):
    """Create the test suite.

    Args:
        name: the name of the test suite
    """
    test_suite(name = name, basic_tests = _tests)
