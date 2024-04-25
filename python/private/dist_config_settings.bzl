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

The list of specialization of the dists goes like follows:
* sdist
* -none-any.whl
* -abi3-any.whl
* -cpxy-any.whl
* -none-plat.whl
* -abi3-plat.whl
* -cpxy-plat.whl

Note, that here the specialization of musl vs manylinux wheels is the same in
order to not match an incompatible version in case the user specifies the version
of the libc to match. By default we do not match against the libc version and pick
some whl.

That should cover the majority of cases as only a single `whl`.

Use cases that this code strives to support:
* sdist only - Setting the flag `:whl=no` should do the trick
* whl only - Will be handled differently (i.e. filtering elsewhere). By default
  we will give preference to whls, so this should not be necessary most of the
  times.
* select only pure python versions of wheels. This may not work all of the time
  unless building from `sdist` is disabled.
* select to target a particular libc version
* select to target a particular osx version
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
        build_setting_default = "singlearch",
        values = ["singlearch", "multiarch"],
        **kwargs
    )

    osx_versions = {}
    for p in sorted(whl_platforms):
        if "macos" not in p:
            continue

        _, _, tail = p.partition("_")
        major, _, tail = tail.partition("_")
        minor, _, _ = tail.partition("_")
        osx_versions[p] = "{}.{}".format(major, minor)

    string_flag(
        name = "whl_linux_libc",
        build_setting_default = "glibc",
        values = ["glibc", "musl"],
        **kwargs
    )

    constraint_values = {
        "": None,
    }
    osx_versions = {}
    libc_versions = {}
    for target_platform in whl_platforms:
        for p in whl_target_platforms(target_platform):
            plat_label = "{}_{}".format(p.os, p.cpu)
            constraint_values[plat_label] = [
                "@platforms//os:" + p.os,
                "@platforms//cpu:" + p.cpu,
            ]

            if not p.versions:
                continue

            if p.os == "linux":
                for v in p.versions:
                    libc_versions.setdefault("{}.{}".format(v[0], v[1]), []).append(
                        p.flavor + plat_label
                    )
            elif p.os == "osx":
                for v in p.versions:
                    osx_versions.setdefault("{}.{}".format(v[0], v[1]), []).append(
                        plat_label
                    )

    # FIXME @aignas 2024-04-25: if we target version `1.1`, then we should be OK
    # to select versions that are lower, but we should not select versions that are
    # higher.
    #
    # I have added these flags here so that the behaviour could be somewhat configurable
    # as the majority of the wheels on PyPI are built against the earliest possible
    # target platform that the CI provider supports, hence the list here is expected to
    # be not too large.

    string_flag(
        name = "experimental_whl_osx_version",
        build_setting_default = "",
        values = [""] + sorted(osx_versions.keys()),
        **kwargs
    )

    string_flag(
        name = "experimental_whl_linux_libc_version",
        build_setting_default = "",
        values = [""] + sorted(libc_versions.keys()),
        **kwargs
    )

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
            "": {},
            "sdist": {"whl": "no"},
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
                for name, whl_osx_arch in {
                    plat: "singlearch",
                    plat + "_universal2": "multiarch",
                }.items():
                    _config_settings(
                        name = [prefix, name],
                        flag_values = dict(
                            experimental_whl_osx_version = "",
                            whl_osx_arch = whl_osx_arch,
                            whl_plat = "auto",
                            **flag_values
                        ),
                        **kwargs
                    )

                    for version, plats in osx_versions.items():
                        if plat not in plats:
                            continue

                        os, _, cpu = name.partition("_")

                        _config_settings(
                            name = [prefix, os, version.replace(".", "_"), cpu],
                            flag_values = dict(
                                experimental_whl_osx_version = version,
                                whl_osx_arch = whl_osx_arch,
                                whl_plat = "auto",
                                **flag_values
                            ),
                            **kwargs
                        )

            elif "linux" in plat:
                # [none|abi3|cp]-[|many|musl]linux_arch.whl
                for name, whl_linux_libc in {
                    plat: None,
                    "many" + plat: "glibc",
                    "musl" + plat: "musl",
                }.items():
                    _config_settings(
                        name = [prefix, name],
                        flag_values = dict(
                            experimental_whl_linux_libc_version = "",
                            whl_linux_libc = whl_linux_libc,
                            whl_plat = "auto",
                            **flag_values
                        ),
                        **kwargs
                    )

                    for version, plats in libc_versions.items():
                        if name not in plats:
                            continue

                        os, _, cpu = name.partition("_")

                        _config_settings(
                            name = [prefix, os, version.replace(".", "_"), cpu],
                            flag_values = dict(
                                whl_linux_libc = whl_linux_libc,
                                experimental_whl_linux_libc_version = version,
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
        if v != None
    }

    if flag_values or constraint_values:
        native.config_setting(
            name = name,
            # NOTE @aignas 2024-04-25: we need to add this so that we ensure that
            # all config settings have the same number of flag values so that
            # the different wheel arches are specializations of each other and
            # so that the modelling works fully.
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
