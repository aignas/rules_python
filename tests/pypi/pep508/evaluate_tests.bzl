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

load("@rules_testing//lib:test_suite.bzl", "test_suite")
load("//python/private/pypi:pep508.bzl", "tokenize")  # buildifier: disable=bzl-visibility

_tests = []

def tokenize_tests(env):
    for input, want in {
        "": [],
        "()": ["(", ")"],
        # "(os_name == 'osx' and not os_name == 'posix') or os_name = 'win'": [
        #     "(",
        #     "os_name",
        #     "==",
        #     "osx",
        #     "and",
        #     "not",
        #     "os_name",
        #     "==",
        #     "posix",
        #     ")",
        #     "os_name",
        #     "==",
        #     "win",
        # ],
        "os_name == 'osx'": ["os_name", "==", "osx"],
        "python_version <= \"1.0\"": ["python_version", "<=", "1.0"],
        "python_version>='1.0.0'": ["python_version", ">=", "1.0.0"],
    }.items():
        got = tokenize(input)
        env.expect.that_collection(got).contains_exactly(want).in_order()

_tests.append(tokenize_tests)

def evaluate_test_suite(name):  # buildifier: disable=function-docstring
    test_suite(
        name = name,
        basic_tests = _tests,
    )
