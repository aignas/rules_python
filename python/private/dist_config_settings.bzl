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

We also would like to ensure that we match the python version tag, it can be:
- py2.py3 - all python 3 versions
- py3 - all python 3 versions
- cp38 - all CPython 3.8 and above
- cp39 - all CPython 3.9 and above
- cp310 - all CPython 3.10 and above

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
    glibc_versions = {}
    muslc_versions = {}
    for target_platform in whl_platforms:
        for p in whl_target_platforms(target_platform):
            plat_label = "{}_{}".format(p.os, p.cpu)
            constraint_values[plat_label] = [
                "@platforms//os:" + p.os,
                "@platforms//cpu:" + p.cpu,
            ]

            if not p.versions:
                continue

            if p.flavor == "many":
                for v in p.versions:
                    glibc_versions[(int(v[0]), int(v[1]))] = None
            elif p.flavor == "musl":
                for v in p.versions:
                    muslc_versions[(int(v[0]), int(v[1]))] = None
            elif p.os == "osx":
                for v in p.versions:
                    osx_versions[(int(v[0]), int(v[1]))] = None

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
    for plat, config_settings_args in presets.items():
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
                **config_settings_args
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
                **config_settings_args
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
                    **config_settings_args
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
                            whl_osx_arch = whl_osx_arch,
                            whl_plat = "auto",
                            **flag_values
                        ),
                        **config_settings_args
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
                            whl_linux_libc = whl_linux_libc,
                            whl_plat = "auto",
                            **flag_values
                        ),
                        **config_settings_args
                    )
            else:
                fail("unknown platform: '{}'".format(plat))

    # TODO @aignas 2024-04-25: if we target a libc version `1.1`, then that
    # means that the target application has to be compatible with the libc
    # version of 1.1 or above, which means that our wheels need to be built for
    # 1.1 or lower.
    #
    # This means that a binary with 1.1 libc (or osx version) should match when
    # the `experimental_whl_foo_version` is set to 1.1 and above, but not when
    # the flag is set to 1.0. This means that for versions 1.2, 1.1, 1.0 we
    # have to have a config_setting group layout of something similar to:
    #   * whl_foo_version_1.2 - matches 1.2
    #   * whl_foo_version_1.1 - matches 1.2 or 1.1
    #   * whl_foo_version_1.0 - matches 1.2 or 1.1 or 1.0
    #
    # And if we have multiple artifacts matched, I think that the one with the closest
    # match should take precedence, i.e. if we set the flag value to version 1.3, we 
    # should get whl_foo_version_1.2. Note, that all three wheels are
    # compatible, but we should somehow get the precedence correct.
    #
    # All of the inspiration is coming from the selects.config_setting_group
    # [1], where they have a select statement, which we can adapt to our
    # situation like follows:
    #
    # alias(
    #   name = "whl_matching_1.2_or_lower"
    #   actual = select({
    #      "flag_eq_1.2": "actual_whl_1.2",
    #      ":default": "whl_matching_1.1_or_lower",
    #   })
    # )
    #
    # alias(
    #   name = "whl_matching_1.1_or_lower"
    #   actual = select({
    #      "flag_eq_1.1": "actual_whl_1.1",
    #      ":default": "whl_matching_1.0",
    #   })
    # )
    #
    # alias(
    #   name = "whl_matching_1.0",
    #   actual = select(
    #      {
    #          "flag_eq_1.0": "actual_whl_1.0",
    #      },
    #      no_match_error = "Could not match, the target supports versions 1.2, 1.1 and 1.0", but you have selected something outside this range.
    #   )
    # )
    #
    # alias(
    #   name = "whl_matching_2.27_or_lower"
    #   actual = select({
    #      "flag_eq_2.28": "actual_whl_2.27",  # The highest libc version value as noted
    #                                          # in the string_flag.
    #      "flag_eq_2.27": "actual_whl_2.27",
    #      ":default": "whl_matching_2.22_or_lower",
    #   })
    # )
    #
    # alias(
    #   name = "whl_matching_1.1_or_lower"
    #   actual = select({
    #      "flag_eq_2.26": "actual_whl_2.22",
    #      "flag_eq_2.25": "actual_whl_2.22",
    #      "flag_eq_2.24": "actual_whl_2.22",
    #      "flag_eq_2.23": "actual_whl_2.22",
    #      "flag_eq_2.22": "actual_whl_2.22",
    #      ":default": "whl_matching_2.5",
    #   })
    # )
    #
    # alias(
    #   name = "whl_matching_1.0",
    #   actual = select(
    #      {
    #          ...
    #          "flag_eq_2.5": "actual_whl_2.5",
    #      },
    #      no_match_error = "Could not match, the lowest value of libc that is supported is 2.5 (this is the whls property), please select something higher for your target.".
    #   )
    # )
    #
    # This requires the hub repo to create these extra alias for the special flags, but
    # it makes the config settings for those special flags independent of python_version,
    # which is a nice simplification.
    #
    # [1]: https://github.com/bazelbuild/bazel-skylib/blob/main/lib/selects.bzl

    # FIXME @aignas 2024-04-28: what to do when we cross multiple major versions?
    # maybe there is nothing to be done?
    for version_name, versions in {
        "whl_glibc_version": _stringify_versions(glibc_versions.keys()),
        "whl_muslc_version": _stringify_versions(muslc_versions.keys()),
        "whl_osx_version": _stringify_versions(osx_versions.keys()),
    }.items():
        string_flag(
            name = version_name,
            build_setting_default = versions[0],
            values = versions,
            **kwargs
        )

        for version in versions:
            native.config_setting(
                name = "is_{}_{}".format(version_name, version),
                flag_values = {
                    ":{}".format(version_name): version,
                },
                visibility = [
                    native.package_relative_label(":__subpackages__"),
                ],
            )

def _stringify_versions(versions):
    return ["{}.{}".format(major, minor) for major, minor in sorted(versions)]

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
