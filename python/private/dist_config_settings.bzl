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

"""
This module is used to construct the config settings for selecting which distribution is used in the pip hub repository.

Bazel's selects work by selecting the most-specialized configuration setting
that matches the target platform. We can leverage this fact to ensure that the
most specialized wheels are used by default with the users being able to
configure string_flag values to select the less specialized ones.

The list of the dists by specialization (from least specialized) goes like below.

The following are cross-platform wheels, which can be present in different
versions for different configurations (e.g. linux_x86_64 has a different
version from osx_aarch64) and the same is true for python versions. What is more
we should be able to prefer an any whl for a particular platform (e.g. use platform-specific wheels for linux, but cross-platform for win_amd64)
1. sdist
    * Can be for a particular platform or python version because the dist version numbers may differ.
    * should error out if we have dist_type = whl, hence we cannot have a `//conditions:default` here.
    * only the following should be present:
        * default
        * py3x
        * py3x_plat
1. (none, any) whl, similar to sdist but should be preferred over it.
        * default, none_abi=auto|yes
        * py3x, none_abi=auto|yes
        * py3x_plat, none_abi=auto|yes
1. (abi3, any) whl, similar to sdist but should be preferred.
        * default, abi=auto, abi3=auto|yes
        * py3x, abi=auto, abi3=auto|yes
        * py3x_plat, abi=auto, abi3=auto|yes
1. (cp, any) whl, similar to sdist but should be preferred.
        * default, abi=auto, abi3=auto, cpabi=auto|yes
        * py3x, abi=auto, abi3=auto, cpabi=auto|yes
        * py3x_plat, abi=auto, abi3=auto, cpabi=auto|yes

The following is for platform-specific wheels. We should not have plat that is not supported by the wheel in the constraints here. We should filter the incoming dist list based on the target platform:
1. ([none|abi3|cp], plat) whl, similar to sdist but should be preferred.
        * py3x_plat, none_abi=auto|yes, plat=auto
        * py3x_plat, abi=auto, abi3=auto|yes, plat=auto
        * py3x_plat, abi=auto, abi3=auto, cpabi=auto|yes, plat=auto
1. ([none|abi3|cp], [manylinux|musllinux]) whl, similar to sdist but should be preferred.
        * py3x_plat, none_abi=auto|yes, plat=auto, linux_whl=[manylinux|musllinux]
        * py3x_plat, abi=auto, abi3=auto|yes, plat=auto, linux_whl=[manylinux|musllinux]
        * py3x_plat, abi=auto, abi3=auto, plat=auto, cpabi=auto|yes, linux_whl=[manylinux|musllinux]
1. ([none|abi3|cp], [os_arch|multiarch]) whl, similar to sdist but should be preferred.
        * py3x_plat, none_abi=auto|yes, plat=auto, osx_whl=[|multiarch]
        * py3x_plat, abi=auto, abi3=auto|yes, plat=auto, osx_whl=[|multiarch]
        * py3x_plat, abi=auto, abi3=auto, cpabi=auto|yes, plat=auto, osx_whl=[|multiarch]

The flag_values:
1. osx_flavor - os_arch, multiarch - default os_arch
1. linux_whl - glibc, musl - default glibc
1. plat:
      * auto - Default - prefer platform available
      * no - Do not include platform-specific wheels
      * NOTE @aignas 2024-04-24: yes does not make senses because not all
        wheels have plat specific wheel, but sometimes they do have
        cross-platform alternatives that we should be able to configure.

Not sure about the following three flags, but when we have tests, maybe we can simplify
1. use_abi_none - auto, only
1. use_abi_abi3 - auto, no
1. use_abi_cpxy - auto, no

Use cases:
* sdist only - do not register wheels or have a separate select for that
* whl only - do not register sdists or have a separate select for that
* auto only - register all
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

    string_flag(
        name = "whl",
        build_setting_default = "auto",
        values = ["auto", "no"],
        **kwargs
    )

    string_flag(
        name = "whl_abi3",
        build_setting_default = "auto",
        values = ["auto", "no"],
        **kwargs
    )

    string_flag(
        name = "whl_cpxy",
        build_setting_default = "auto",
        values = ["auto", "no"],
        **kwargs
    )

    string_flag(
        name = "whl_plat",
        build_setting_default = "auto",
        values = ["auto", "no"],
        **kwargs
    )

    string_flag(
        name = "whl_osx_arch",
        build_setting_default = "auto",
        values = ["auto", "single", "multi"],
        **kwargs
    )

    string_flag(
        name = "whl_linux_libc",
        build_setting_default = "glibc",
        values = ["glibc", "musl"],
        **kwargs
    )

    # NOTE @aignas 2024-04-25: it should be theoretically possible to get the
    # glibc and muslc versions from the `whl_platforms` variable, but how to
    # make use of it requires further analysis.

    constraint_values = {
        "": None,
    } | {
        "{}_{}".format(os, cpu): [
            "@platforms//os:" + os,
            "@platforms//cpu:" + cpu,
        ]
        # Unique os, cpu tuples derived from whl_target_platforms
        for (os, cpu) in {
            (p.os, p.cpu): None
            for target_platform in whl_platforms
            for p in whl_target_platforms(target_platform)
        }
    }

    presets = {
        name: {
            "constraint_values": cvs,
            "python_versions": python_versions,
            "visibility": [
                native.package_relative_label(":__subpackages__"),
            ],
        }
        for name, cvs in constraint_values.items()
    }

    # Creating config_setting values so that we can
    # * sdist - use if this exists or disable usage of it.
    # * none-any.whl - use if this exists or use only these in case we need pure python whls.
    # * abi3-any.whl - use if this exists and prefer it over none whls
    # * cp3x-any.whl - use if this exists and prefer it over abi3 and none whls
    for plat, kwargs in presets.items():
        # A different way to model this would be to ask the user to explicitly allow sdists
        # - use only whls (do not register sdist, should be a flag to pip.parse)
        # - fallback to sdist (default)
        # - use only sdist (disable whls) (flag)
        for prefix, flag_values in {
            "": {},  # fallback to sdist
        }.items():
            _config_settings(
                name = [prefix, plat],
                flag_values = flag_values,
                # in theory this can only work with the host platform as we
                # don't support cross-building the wheels from sdist. If we did
                # support that, then it could be different. However, we need
                # the `constraint_values` on os and arch to support the case
                # where we have different versions on different platforms,
                # because we are supplying different requirement files.
                **kwargs
            )

        for prefix, flag_values in {
            # All of these fallback to sdist
            "whl_none": {"whl": "auto"},
            "whl_abi3": {"whl": "auto", "whl_abi3": "auto"},
            "whl_cpxy": {"whl": "auto", "whl_abi3": "auto", "whl_cpxy": "auto"},
        }.items():  # buildifier: disable=unsorted-dict-items as they have meaning
            # [none|abi3|cp]-any.whl
            # the platform suffix is for the cases when we have different dists
            # on different platforms.
            _config_settings(
                name = [prefix, "any", plat],
                flag_values = flag_values,
                **kwargs
            )

            if plat == "":
                # We are dealing with platform-specific wheels, so the default
                # platform does not make sense here.
                continue
            elif "windows" in plat:
                # [none|abi3|cp]-plat.whl
                _config_settings(
                    name = [prefix, plat],
                    flag_values = dict(
                        whl_plat = "auto",
                        **flag_values
                    ),
                    **kwargs
                )
            elif "osx" in plat:
                # [none|abi3|cp]-macosx-arch.whl
                for suffix, whl_osx_arch in {
                    plat: "auto",
                    plat + "_slim": "single",
                    plat + "_universal2": "multi",
                }.items():
                    _config_settings(
                        name = [prefix, suffix],
                        flag_values = dict(
                            whl_osx_arch = whl_osx_arch,
                            whl_plat = "auto",
                            **flag_values
                        ),
                        **kwargs
                    )
            elif "linux" in plat:
                # TODO @aignas 2024-04-25: register config settings for different libc versions
                # [none|abi3|cp]-[|many|musl]linux_arch.whl
                for name, whl_linux_libc in {
                    plat: None,
                    "many" + plat: "glibc",
                    "musl" + plat: "musl",
                }.items():
                    _config_settings(
                        name = [prefix, name],
                        flag_values = dict(
                            whl_linux_libc = whl_linux_libc,
                            whl_plat = "auto",
                            **flag_values
                        ),
                        **kwargs
                    )
            else:
                fail("unknown platform: '{}'".format(plat))

def _config_settings(
        *,
        name,
        python_versions,
        flag_values,
        constraint_values = None,
        **kwargs):
    name = "_".join(["is"] + [n for n in name if n and n != "auto"])

    flag_values = {
        k: v
        for k, v in flag_values.items()
        if v
    }

    if flag_values or constraint_values:
        native.config_setting(
            name = name,
            # TODO @aignas 2024-04-25: the fact that we need to add this is fishy
            flag_values = flag_values | {
                str(Label("//python/config_settings:python_version")): "",
            },
            constraint_values = constraint_values,
            **kwargs
        )
    for python_version in python_versions:
        is_python_config_setting(
            name = "is_python_{}{}".format(python_version, name[len("is"):]),
            python_version = python_version,
            flag_values = flag_values,
            constraint_values = constraint_values,
            **kwargs
        )
