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
load("//python/private:bzlmod_enabled.bzl", "BZLMOD_ENABLED")  # buildifier: disable=bzl-visibility
load("//python/private:render_pkg_aliases.bzl", "render_pkg_aliases", "whl_alias")  # buildifier: disable=bzl-visibility

def _normalize_label_strings(want):
    """normalize expected strings.

    This function ensures that the desired `render_pkg_aliases` outputs are
    normalized from `bzlmod` to `WORKSPACE` values so that we don't have to
    have to sets of expected strings. The main difference is that under
    `bzlmod` the `str(Label("//my_label"))` results in `"@@//my_label"` whereas
    under `non-bzlmod` we have `"@//my_label"`. This function does
    `string.replace("@@", "@")` to normalize the strings.

    NOTE, in tests, we should only use keep `@@` usage in expectation values
    for the test cases where the whl_alias has the `config_setting` constructed
    from a `Label` instance.
    """
    if "@@" not in want:
        fail("The expected string does not have '@@' labels, consider not using the function")

    if BZLMOD_ENABLED:
        # our expectations are already with double @
        return want

    return want.replace("@@", "@")

_tests = []

def _test_empty(env):
    actual = render_pkg_aliases(
        hub_name = "",
        aliases = None,
    )

    want = {}

    env.expect.that_dict(actual).contains_exactly(want)

_tests.append(_test_empty)

def _test_legacy_aliases(env):
    actual = render_pkg_aliases(
        hub_name = "",
        aliases = {
            "foo": [
                whl_alias(repo = "pypi_foo"),
            ],
        },
    )

    want_key = "foo/BUILD.bazel"
    want_content = """\
load("@@//python/private:render_pkg_aliases.bzl", "whl_library_aliases")

package(default_visibility = ["//visibility:public"])

whl_library_aliases(
    name = "bar_baz",
    aliases = {
        "pkg": "pkg",
        "whl": "whl",
        "data": "data",
        "dist_info": "dist_info",
    },
    config_settings = [
        ("pypi_32_bar_baz", "//:is_python_3.2"),
        ("pypi_31_bar_baz", "//:is_python_3.1"),
    ],
)"""

    env.expect.that_dict(actual).contains_exactly({
        want_key: _normalize_label_strings(want_content),
    })

_tests.append(_test_legacy_aliases)

def _test_bzlmod_aliases(env):
    actual = render_pkg_aliases(
        hub_name = "",
        default_version = "3.2",
        aliases = {
            "bar-baz": [
                whl_alias(version = "3.2", repo = "pypi_32_bar_baz"),
            ],
        },
    )

    want_key = "bar_baz/BUILD.bazel"
    want_content = """\
load("@@//python/private:render_pkg_aliases.bzl", "whl_library_aliases")

package(default_visibility = ["//visibility:public"])

whl_library_aliases(
    name = "bar_baz",
    aliases = {
        "pkg": "pkg",
        "whl": "whl",
        "data": "data",
        "dist_info": "dist_info",
    },
    config_settings = [
        ("pypi_32_bar_baz", "//:is_python_3.2"),
        ("pypi_32_bar_baz", "//conditions:default"),
        ("pypi_31_bar_baz", "//:is_python_3.1"),
    ],
)"""

    env.expect.that_collection(actual.keys()).contains_exactly(["BUILD.bazel", want_key])
    env.expect.that_str(actual[want_key]).equals(_normalize_label_strings(want_content))

_tests.append(_test_bzlmod_aliases)

def _test_bzlmod_aliases_with_no_default_version(env):
    actual = render_pkg_aliases(
        hub_name = "",
        default_version = None,
        aliases = {
            "bar-baz": [
                whl_alias(
                    version = "3.2",
                    repo = "pypi_32_bar_baz",
                ),
                whl_alias(version = "3.1", repo = "pypi_31_bar_baz"),
            ],
        },
    )

    want_key = "bar_baz/BUILD.bazel"
    want_content = """\
load("@bazel_skylib//lib:selects.bzl", "selects")

package(default_visibility = ["//visibility:public"])

_NO_MATCH_ERROR = \"\"\"\\
No matching wheel for current configuration's Python version.

The current build configuration's Python version doesn't match any of the Python
versions available for this wheel. This wheel supports the following Python versions:
    3.1, 3.2

As matched by the `@rules_python//python/config_settings:is_python_<version>`
configuration settings.

To determine the current configuration's Python version, run:
    `bazel config <config id>` (shown further below)
and look for
    rules_python//python/config_settings:python_version

If the value is missing, then the "default" Python version is being used,
which has a "null" version value and will not match version constraints.
\"\"\"

alias(
    name = "bar_baz",
    actual = ":pkg",
)

alias(
    name = "pkg",
    actual = selects.with_or(
        {
            "//:is_python_3.1": "@pypi_31_bar_baz//:pkg",
            "//:is_python_3.2": "@pypi_32_bar_baz//:pkg",
        },
        no_match_error = _NO_MATCH_ERROR,
    ),
)

alias(
    name = "whl",
    actual = selects.with_or(
        {
            "//:is_python_3.1": "@pypi_31_bar_baz//:whl",
            "//:is_python_3.2": "@pypi_32_bar_baz//:whl",
        },
        no_match_error = _NO_MATCH_ERROR,
    ),
)

alias(
    name = "data",
    actual = selects.with_or(
        {
            "//:is_python_3.1": "@pypi_31_bar_baz//:data",
            "//:is_python_3.2": "@pypi_32_bar_baz//:data",
        },
        no_match_error = _NO_MATCH_ERROR,
    ),
)

alias(
    name = "dist_info",
    actual = selects.with_or(
        {
            "//:is_python_3.1": "@pypi_31_bar_baz//:dist_info",
            "//:is_python_3.2": "@pypi_32_bar_baz//:dist_info",
        },
        no_match_error = _NO_MATCH_ERROR,
    ),
)"""

    env.expect.that_collection(actual.keys()).contains_exactly(["BUILD.bazel", want_key])
    env.expect.that_str(actual[want_key]).equals(want_content)

_tests.append(_test_bzlmod_aliases_with_no_default_version)

def _test_bzlmod_aliases_for_non_root_modules(env):
    actual = render_pkg_aliases(
        hub_name = "",
        # NOTE @aignas 2024-01-17: if the default X.Y version coincides with the
        # versions that are used in the root module, then this would be the same as
        # as _test_bzlmod_aliases.
        #
        # However, if the root module uses a different default version than the
        # non-root module, then we will have a no-match-error because the default_version
        # is not in the list of the versions in the whl_map.
        default_version = "3.3",
        aliases = {
            "bar-baz": [
                whl_alias(version = "3.2", repo = "pypi_32_bar_baz"),
                whl_alias(version = "3.1", repo = "pypi_31_bar_baz"),
            ],
        },
    )

    want_key = "bar_baz/BUILD.bazel"
    want_content = """\
load("@bazel_skylib//lib:selects.bzl", "selects")

package(default_visibility = ["//visibility:public"])

_NO_MATCH_ERROR = \"\"\"\\
No matching wheel for current configuration's Python version.

The current build configuration's Python version doesn't match any of the Python
versions available for this wheel. This wheel supports the following Python versions:
    3.1, 3.2

As matched by the `@rules_python//python/config_settings:is_python_<version>`
configuration settings.

To determine the current configuration's Python version, run:
    `bazel config <config id>` (shown further below)
and look for
    rules_python//python/config_settings:python_version

If the value is missing, then the "default" Python version is being used,
which has a "null" version value and will not match version constraints.
\"\"\"

alias(
    name = "bar_baz",
    actual = ":pkg",
)

alias(
    name = "pkg",
    actual = selects.with_or(
        {
            "//:is_python_3.1": "@pypi_31_bar_baz//:pkg",
            "//:is_python_3.2": "@pypi_32_bar_baz//:pkg",
        },
        no_match_error = _NO_MATCH_ERROR,
    ),
)

alias(
    name = "whl",
    actual = selects.with_or(
        {
            "//:is_python_3.1": "@pypi_31_bar_baz//:whl",
            "//:is_python_3.2": "@pypi_32_bar_baz//:whl",
        },
        no_match_error = _NO_MATCH_ERROR,
    ),
)

alias(
    name = "data",
    actual = selects.with_or(
        {
            "//:is_python_3.1": "@pypi_31_bar_baz//:data",
            "//:is_python_3.2": "@pypi_32_bar_baz//:data",
        },
        no_match_error = _NO_MATCH_ERROR,
    ),
)

alias(
    name = "dist_info",
    actual = selects.with_or(
        {
            "//:is_python_3.1": "@pypi_31_bar_baz//:dist_info",
            "//:is_python_3.2": "@pypi_32_bar_baz//:dist_info",
        },
        no_match_error = _NO_MATCH_ERROR,
    ),
)"""

    env.expect.that_collection(actual.keys()).contains_exactly(["BUILD.bazel", want_key])
    env.expect.that_str(actual[want_key]).equals(want_content)

_tests.append(_test_bzlmod_aliases_for_non_root_modules)

def _test_aliases_are_created_for_all_wheels(env):
    actual = render_pkg_aliases(
        hub_name = "",
        default_version = "3.2",
        aliases = {
            "bar": [
                whl_alias(version = "3.1", repo = "pypi_31_bar"),
                whl_alias(version = "3.2", repo = "pypi_32_bar"),
            ],
            "foo": [
                whl_alias(version = "3.1", repo = "pypi_32_foo"),
                whl_alias(version = "3.2", repo = "pypi_31_foo"),
            ],
        },
    )

    want_files = [
        "bar/BUILD.bazel",
        "foo/BUILD.bazel",
        "BUILD.bazel",
    ]

    env.expect.that_dict(actual).keys().contains_exactly(want_files)

_tests.append(_test_aliases_are_created_for_all_wheels)

def _test_version_config_settings(env):
    actual = render_pkg_aliases(
        hub_name = "",
        default_version = "3.2",
        aliases = {
            "bar": [
                whl_alias(version = "3.1", repo = "pypi_31_bar"),
                whl_alias(version = "3.2", repo = "pypi_32_bar"),
            ],
            "foo": [
                whl_alias(version = "3.1", repo = "pypi_32_foo"),
                whl_alias(version = "3.2", repo = "pypi_31_foo"),
            ],
        },
    )

    want_files = [
        "bar/BUILD.bazel",
        "foo/BUILD.bazel",
        "BUILD.bazel",
    ]

    want_content = """\
load("@@//python/config_settings:config_settings.bzl", "is_python_config_setting")
load("@@//python/private:dist_config_settings.bzl", "dist_config_settings")

dist_config_settings(
    name = "dist_config_settings",
    visibility = ["//visibility:public"],
)

alias(
    name = "is_python_3.1",
    actual = "@@//python/config_settings:is_python_3.1",
    visibility = ["//:__subpackages__"],
)

alias(
    name = "is_python_3.2",
    actual = "@@//python/config_settings:is_python_3.2",
    visibility = ["//:__subpackages__"],
)"""

    env.expect.that_dict(actual).keys().contains_exactly(want_files)
    env.expect.that_str(actual["BUILD.bazel"]).equals(_normalize_label_strings(want_content))

_tests.append(_test_version_config_settings)

def _test_single_any_whl(env):
    actual = render_pkg_aliases(
        hub_name = "",
        default_version = "3.2",
        aliases = {
            "foo": [
                whl_alias(
                    version = "3.1",
                    repo = "pypi",
                    filename = "foo-0.0.1-py2.py3-none-any.whl",
                ),
            ],
        },
    )

    want_files = [
        "foo/BUILD.bazel",
    ]

    env.expect.that_dict(actual).keys().contains_exactly(want_files)

    want_content = """\
load("@bazel_skylib//lib:selects.bzl", "selects")

package(default_visibility = ["//visibility:public"])

alias(
    name = "foo",
    actual = ":pkg",
)

alias(
    name = "pkg",
    actual = "@pypi_foo_0_0_1_py3_none_any//:pkg",
)

alias(
    name = "whl",
    actual = "@pypi_foo_0_0_1_py3_none_any//:whl",
)

alias(
    name = "data",
    actual = "@pypi_foo_0_0_1_py3_none_any//:data",
)

alias(
    name = "dist_info",
    actual = "@pypi_foo_0_0_1_py3_none_any//:dist_info",
)"""
    env.expect.that_str(actual["foo/BUILD.bazel"]).equals(want_content)

_tests.append(_test_single_any_whl)

def _test_single_any_whl_with_sdist(env):
    actual = render_pkg_aliases(
        hub_name = "",
        default_version = "3.2",
        aliases = {
            "foo": [
                whl_alias(
                    version = "3.1",
                    repo = "pypi",
                    filename = "foo-0.0.1-py2.py3-none-any.whl",
                ),
                whl_alias(
                    version = "3.1",
                    repo = "pypi",
                    filename = "foo-0.0.1.tar.gz",
                ),
            ],
        },
    )

    want_files = [
        "foo/BUILD.bazel",
        "BUILD.bazel",
    ]

    want_content = """\
load("@@//python/config_settings:config_settings.bzl", "is_python_config_setting")
load("@@//python/private:dist_config_settings.bzl", "dist_config_settings")

dist_config_settings(
    name = "dist_config_settings",
    visibility = ["//visibility:public"],
)

config_setting(
    name = "is_any",
    flag_values = {
        "//:use_sdist": "auto",
    },
    visibility = ["//:__subpackages__"],
)

is_python_config_setting(
    name = "is_python_3.1_any",
    python_version = "3.1",
    flag_values = {
        "//:use_sdist": "auto",
    },
    visibility = ["//:__subpackages__"],
)

is_python_config_setting(
    name = "is_python_3.1",
    python_version = "3.1",
    visibility = ["//:__subpackages__"],
)"""

    env.expect.that_dict(actual).keys().contains_exactly(want_files)
    env.expect.that_str(actual["BUILD.bazel"]).equals(_normalize_label_strings(want_content))

    # If we have an `any` whl with no abi constraints, then we should use it by
    # default if `sdist` is not selected.  sdist should be only used for the python
    # version that has the interpreter configuration, so we should just leave
    # it with `is_python_3.1`.
    want_content = """\
load("@bazel_skylib//lib:selects.bzl", "selects")

package(default_visibility = ["//visibility:public"])

alias(
    name = "foo",
    actual = ":pkg",
)

alias(
    name = "pkg",
    actual = selects.with_or(
        {
            (
                "//:is_python_3.1_any",
                "//:is_any",
                "//conditions:default",
            ): "@pypi_foo_0_0_1_py3_none_any//:pkg",
            "//:is_python_3.1": "@pypi_foo_0_0_1_sdist//:pkg",
        },
    ),
)

alias(
    name = "whl",
    actual = selects.with_or(
        {
            (
                "//:is_python_3.1_any",
                "//:is_any",
                "//conditions:default",
            ): "@pypi_foo_0_0_1_py3_none_any//:whl",
            "//:is_python_3.1": "@pypi_foo_0_0_1_sdist//:whl",
        },
    ),
)

alias(
    name = "data",
    actual = selects.with_or(
        {
            (
                "//:is_python_3.1_any",
                "//:is_any",
                "//conditions:default",
            ): "@pypi_foo_0_0_1_py3_none_any//:data",
            "//:is_python_3.1": "@pypi_foo_0_0_1_sdist//:data",
        },
    ),
)

alias(
    name = "dist_info",
    actual = selects.with_or(
        {
            (
                "//:is_python_3.1_any",
                "//:is_any",
                "//conditions:default",
            ): "@pypi_foo_0_0_1_py3_none_any//:dist_info",
            "//:is_python_3.1": "@pypi_foo_0_0_1_sdist//:dist_info",
        },
    ),
)"""
    env.expect.that_str(actual["foo/BUILD.bazel"]).equals(want_content)

_tests.append(_test_single_any_whl_with_sdist)

def _test_single_any_whl_with_sdist_default_version(env):
    actual = render_pkg_aliases(
        hub_name = "",
        default_version = "3.1",
        aliases = {
            "foo": [
                whl_alias(
                    version = "3.1",
                    repo = "pypi",
                    filename = "foo-0.0.1-py2.py3-none-any.whl",
                ),
                whl_alias(
                    version = "3.1",
                    repo = "pypi",
                    filename = "foo-0.0.1.tar.gz",
                ),
            ],
        },
    )

    want_files = [
        "foo/BUILD.bazel",
        "BUILD.bazel",
    ]

    want_content = """\
load("@@//python/config_settings:config_settings.bzl", "is_python_config_setting")
load("@@//python/private:dist_config_settings.bzl", "dist_config_settings")

dist_config_settings(
    name = "dist_config_settings",
    visibility = ["//visibility:public"],
)

config_setting(
    name = "is_any",
    flag_values = {
        "//:use_sdist": "auto",
    },
    visibility = ["//:__subpackages__"],
)

is_python_config_setting(
    name = "is_python_3.1_any",
    python_version = "3.1",
    flag_values = {
        "//:use_sdist": "auto",
    },
    visibility = ["//:__subpackages__"],
)

is_python_config_setting(
    name = "is_python_3.1",
    python_version = "3.1",
    visibility = ["//:__subpackages__"],
)"""

    env.expect.that_dict(actual).keys().contains_exactly(want_files)
    env.expect.that_str(actual["BUILD.bazel"]).equals(_normalize_label_strings(want_content))

    # If we have an `any` whl with no abi constraints, then we should use it by
    # default if `sdist` is not selected.  sdist should be only used for the python
    # version that has the interpreter configuration, so we should just leave
    # it with `is_python_3.1`.
    want_content = """\
load("@bazel_skylib//lib:selects.bzl", "selects")

package(default_visibility = ["//visibility:public"])

alias(
    name = "foo",
    actual = ":pkg",
)

alias(
    name = "pkg",
    actual = selects.with_or(
        {
            (
                "//:is_python_3.1_any",
                "//:is_any",
                "//conditions:default",
            ): "@pypi_foo_0_0_1_py3_none_any//:pkg",
            "//:is_python_3.1": "@pypi_foo_0_0_1_sdist//:pkg",
        },
    ),
)

alias(
    name = "whl",
    actual = selects.with_or(
        {
            (
                "//:is_python_3.1_any",
                "//:is_any",
                "//conditions:default",
            ): "@pypi_foo_0_0_1_py3_none_any//:whl",
            "//:is_python_3.1": "@pypi_foo_0_0_1_sdist//:whl",
        },
    ),
)

alias(
    name = "data",
    actual = selects.with_or(
        {
            (
                "//:is_python_3.1_any",
                "//:is_any",
                "//conditions:default",
            ): "@pypi_foo_0_0_1_py3_none_any//:data",
            "//:is_python_3.1": "@pypi_foo_0_0_1_sdist//:data",
        },
    ),
)

alias(
    name = "dist_info",
    actual = selects.with_or(
        {
            (
                "//:is_python_3.1_any",
                "//:is_any",
                "//conditions:default",
            ): "@pypi_foo_0_0_1_py3_none_any//:dist_info",
            "//:is_python_3.1": "@pypi_foo_0_0_1_sdist//:dist_info",
        },
    ),
)"""
    env.expect.that_str(actual["foo/BUILD.bazel"]).equals(want_content)

_tests.append(_test_single_any_whl_with_sdist_default_version)

def _test_aliases_with_groups(env):
    actual = render_pkg_aliases(
        hub_name = "",
        default_version = "3.2",
        aliases = {
            "bar": [
                whl_alias(version = "3.1", repo = "pypi_31_bar"),
                whl_alias(version = "3.2", repo = "pypi_32_bar"),
            ],
            "baz": [
                whl_alias(version = "3.1", repo = "pypi_31_baz"),
                whl_alias(version = "3.2", repo = "pypi_32_baz"),
            ],
            "foo": [
                whl_alias(version = "3.1", repo = "pypi_32_foo"),
                whl_alias(version = "3.2", repo = "pypi_31_foo"),
            ],
        },
        requirement_cycles = {
            "group": ["bar", "baz"],
        },
    )

    want_files = [
        "bar/BUILD.bazel",
        "foo/BUILD.bazel",
        "baz/BUILD.bazel",
        "_groups/BUILD.bazel",
        "BUILD.bazel",
    ]
    env.expect.that_dict(actual).keys().contains_exactly(want_files)

    want_key = "_groups/BUILD.bazel"

    # Just check that it contains a private whl
    env.expect.that_str(actual[want_key]).contains("//bar:_whl")

    want_key = "bar/BUILD.bazel"

    # Just check that it contains a private whl
    env.expect.that_str(actual[want_key]).contains("name = \"_whl\"")
    env.expect.that_str(actual[want_key]).contains("name = \"whl\"")
    env.expect.that_str(actual[want_key]).contains("\"//_groups:group_whl\"")

_tests.append(_test_aliases_with_groups)

def render_pkg_aliases_test_suite(name):
    """Create the test suite.

    Args:
        name: the name of the test suite
    """
    test_suite(name = name, basic_tests = _tests)
