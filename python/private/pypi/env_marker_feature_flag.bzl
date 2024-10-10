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

def _impl(ctx):
    python_version = ctx.attr._python_version_flag[config_common.FeatureFlagInfo].value
    marker = ctx.attr.marker
    if python_version:
        version = semver(python_version)
        self = ctx.attr
        current_env = {
            "os_name": self.os_name,
            "sys_platform": self.sys_platform,
            "platform_machine": self.platform_machine,
            "platform_system": self.platform_system,
            "python_version": "{}.{}".format(version.major, version.minor),
            # FIXME @aignas 2024-01-14: is putting zero last a good idea? Maybe we should
            # use `20` or something else to avoid having weird issues where the full version is used for
            # matching and the author decides to only support 3.y.5 upwards.
            "implementation_version": python_version,
            "python_full_version": python_version,
            # TODO @aignas 2024-10-10: maybe support taking this from the toolchain
            "implementation_name": "cpython",
            "platform_python_implementation": "CPython",
            # TODO @aignas 2024-10-10: Maybe support taking this from the user where we could have string_flag
            # values and the user could fully specify that.
            "platform_release": "",  # unset
            "platform_version": "1.0.0",  # set to a dummy value
        }

        left, _, marker = marker.partition(" ")
        op, _, right = marker.partition(" ")
        left = left.strip(" \"'")
        right = right.strip(" \"'")
        left = current_env.get(left, left)
        right = current_env.get(right, right)
        op = op.strip()

        if op == "<":
            value = "yes" if semver(left).key() < semver(right).key() else "no"
        else:
            fail("Unsupported op: '{}'".format(op))
    else:
        value = ""

    return [config_common.FeatureFlagInfo(value = value)]

env_marker_feature_flag = rule(
    implementation = _impl,
    attrs = {
        "marker": attr.string(mandatory = True),
        "_python_version_flag": attr.label(default = "//python/config_settings:python_version"),
        # TODO @aignas 2024-10-10: split out into a separate rule
        "os_name": attr.string(mandatory = True),
        "platform_machine": attr.string(mandatory = True),
        "platform_system": attr.string(mandatory = True),
        "sys_platform": attr.string(mandatory = True),
    },
)
