# Copyright 2024 The Bazel Authors. All rights reserved.
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

"""This module is for implementing PEP508 in starlark as FeatureFlagInfo
"""

load("//python/private:semver.bzl", "semver")

def _version(value, *, env):
    value = value.strip(" \"'")
    return semver(env.get(value, value)).key()

# Taken from
# https://peps.python.org/pep-0508/#grammar
#
# version_cmp   = wsp* '<' | '<=' | '!=' | '==' | '>=' | '>' | '~=' | '==='
VERSION_CMP = [
    i.strip(" '")
    for i in "'<' | '<=' | '!=' | '==' | '>=' | '>' | '~=' | '==='".split(" | ")
]

def _cmp(left, op, right, *, env):
    op = op.strip()

    if op in VERSION_CMP:
        left = _version(left, env = env)
        right = _version(right, env = env)
        if op == "<":
            return left < right
        elif op == ">":
            return left > right
        elif op == "<=":
            return left <= right
        elif op == ">=":
            return left >= right
        elif op == "!=" or op == "~=":
            return left != right
        elif op == "==" or "===":
            return left == right
        else:
            fail("BUG: missed op for comparing versions: '{}'".format(op))
    else:
        fail("TODO")

def _impl(ctx):
    current_env = {
        key: getattr(ctx.attr, "_" + key)[config_common.FeatureFlagInfo].value
        for key in [
            "implementation_name",
            "implementation_version",
            "os_name",
            "platform_machine",
            "platform_python_implementation",
            "platform_release",
            "platform_system",
            "platform_version",
            "python_full_version",
            "python_version",
            "sys_platform",
        ]
    }
    marker = ctx.attr.marker
    if current_env:
        left, _, marker = marker.partition(" ")
        op, _, right = marker.partition(" ")
        value = "yes" if _cmp(left, op, right, env = current_env) else "no"
    else:
        value = ""

    return [config_common.FeatureFlagInfo(value = value)]

env_marker_feature_flag = rule(
    implementation = _impl,
    attrs = {
        "marker": attr.string(mandatory = True),
        # See https://peps.python.org/pep-0508
        "_implementation_name": attr.label(default = "//python/private/pypi:pep508_implementation_name"),
        "_implementation_version": attr.label(default = "//python/config_settings:python_version"),
        "_os_name": attr.label(default = "//python/private/pypi:pep508_os_name"),
        "_platform_machine": attr.label(default = "//python/private/pypi:pep508_platform_machine"),
        "_platform_python_implementation": attr.label(default = "//python/private/pypi:pep508_platform_python_implementation"),
        "_platform_release": attr.label(default = "//python/private/pypi:pep508_platform_release"),
        "_platform_system": attr.label(default = "//python/private/pypi:pep508_platform_system"),
        "_platform_version": attr.label(default = "//python/private/pypi:pep508_platform_version"),
        "_python_full_version": attr.label(default = "//python/config_settings:python_version"),
        "_python_version": attr.label(default = "//python/config_settings:python_version_major_minor"),
        "_sys_platform": attr.label(default = "//python/private/pypi:pep508_sys_platform"),
    },
)

def _impl_pep508_env(ctx):
    return [config_common.FeatureFlagInfo(value = ctx.attr.value)]

pep508_env = rule(
    implementation = _impl_pep508_env,
    attrs = {
        "value": attr.string(mandatory = True),
    },
)
