# Copyright 2025 The Bazel Authors. All rights reserved.
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
"""Tests for parsing the requirement specifier."""

load("@rules_testing//lib:test_suite.bzl", "test_suite")
load("//python/private/pypi:pep508_requirement.bzl", "requirement")  # buildifier: disable=bzl-visibility

_tests = []

def _test_all(env):
    cases = [
        ("name[foo]", ("name", ["foo"])),
        ("name[ Foo123 ]", ("name", ["Foo123"])),
        (" name1[ foo ] ", ("name1", ["foo"])),
        ("Name[foo]", ("name", ["foo"])),
        ("name_foo[bar]", ("name-foo", ["bar"])),
        (
            "name [fred,bar] @ http://foo.com ; python_version=='2.7'",
            ("name", ["fred", "bar"]),
        ),
        (
            "name[quux, strange];python_version<'2.7' and platform_version=='2'",
            ("name", ["quux", "strange"]),
        ),
        (
            "name; (os_name=='a' or os_name=='b') and os_name=='c'",
            ("name", None),
        ),
        (
            "name@http://foo.com",
            ("name", None),
        ),
    ]

    for case, expected in cases:
        got = requirement(case)
        env.expect.that_str(got.name).equals(expected[0])
        if expected[1] != None:
            env.expect.that_collection(got.extras).contains_exactly(expected[1])

_tests.append(_test_all)

def requirement_test_suite(name):  # buildifier: disable=function-docstring
    test_suite(
        name = name,
        basic_tests = _tests,
    )
