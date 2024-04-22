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

"""This module is used to construct the config settings for selecting which distribution is used in the pip hub repository.
"""

load("@bazel_skylib//rules:common_settings.bzl", "string_flag")
load(":config_settings.bzl", "is_python_config_setting")
load(":whl_target_platforms.bzl", "whl_target_platforms")

def dist_config_settings(
        name,
        python_versions,
        whl_platforms,
        **kwargs):
    """Create string flags for dist configuration.

    Args:
        name: Currently unused.
        python_versions: list[str] A list of python version to generate
            config_setting targets for.
        whl_platforms: list[str] A list of whl platforms that should be used
            to generate the config_setting targets.
        **kwargs: Extra args passed to string_flags.
    """

    whl_abi_values = ["auto", "none", "abi3", "cp"]

    string_flag(
        name = "whl_abi",
        build_setting_default = "auto",
        values = whl_abi_values,
        **kwargs
    )

    string_flag(
        name = "whl_flavor",
        build_setting_default = "auto",
        values = ["auto", "any", "glibc", "musl", "multiarch"],
        **kwargs
    )

    string_flag(
        name = "dist_type",
        build_setting_default = "whl",
        values = ["whl", "sdist"],
        **kwargs
    )

    visibility = [
        native.package_relative_label(":__subpackages__"),
    ]

    target_platforms = [None] + list({
        p.target_platform: None
        for target_platform in whl_platforms
        for p in whl_target_platforms(target_platform)
    })
    for target_platform in target_platforms:
        if target_platform:
            os, _, cpu = target_platform.partition("_")
            constraint_values = [
                "@platforms//os:" + os,
                "@platforms//cpu:" + cpu,
            ]
            if "linux" in os:
                whl_flavors = ["", "any", "musl", "glibc"]
            elif "osx" in os:
                whl_flavors = ["", "any", "multiarch"]
            else:
                whl_flavors = ["", "any"]
        else:
            constraint_values = None
            whl_flavors = ["", "any"]

        # TODO @aignas 2024-04-22: replace with injected values
        for python_version in python_versions:
            for whl_abi in whl_abi_values:
                for whl_flavor in whl_flavors:
                    _config_setting(
                        name = [
                            "is",
                            "python_%s" % python_version if python_version else "",
                            whl_abi,
                            target_platform,
                            whl_flavor,
                            "whl",
                        ],
                        python_version = python_version,
                        whl_flavor = whl_flavor,
                        whl_abi = whl_abi,
                        dist_type = "whl",
                        constraint_values = constraint_values,
                        visibility = visibility,
                    )

            _config_setting(
                name = [
                    "is",
                    "python_%s" % python_version if python_version else "",
                    target_platform,
                    "sdist",
                ],
                dist_type = "sdist",
                constraint_values = constraint_values,
                visibility = visibility,
            )

def _config_setting(
        *,
        name,
        python_version = None,
        whl_abi = "auto",
        whl_flavor = "auto",
        dist_type = "auto",
        constraint_values = None,
        **kwargs):
    name = "_".join([n for n in name if n and n != "auto"]) if type(name) == type([]) else name
    flag_values = {
        k: v
        for k, v in {
            ":dist_type": dist_type,
            ":whl_abi": whl_abi,
            ":whl_flavor": whl_flavor,
        }.items()
        if v and v != "auto"
    }

    if python_version:
        is_python_config_setting(
            name = name,
            python_version = python_version,
            flag_values = flag_values,
            constraint_values = constraint_values,
            **kwargs
        )
    elif flag_values or constraint_values:
        native.config_setting(
            name = name,
            flag_values = flag_values,
            constraint_values = constraint_values,
            **kwargs
        )

    # else:
    #    print(
    #        "At least one of 'constraint_values' or 'flag_values' needs " +
    #        "to be specified, '{}' did not specify them".format(name),
    #    )
