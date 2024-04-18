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

def dist_config_settings(name, default_whl_linux_libc = "glibc", default_whl_osx = "", default_use_sdist = "auto", **kwargs):
    """Create string flags for dist configuration.

    Args:
        name: Currently unused.
        default_whl_linux_libc: str, default for the string_flag controlling
            whether musl or glibc wheels are selected. Defaults to `glibc`.
        default_whl_osx: str, default for the string_flag controlling whether
            `universal2` or arch-specific wheels are used. Defaults to arch
            specific wheels.
        default_use_sdist: str, default for whether the sdist is used. Defaults
            to using `sdist` if there is no wheel available.
        **kwargs: Extra args passed to string_flags.
    """

    string_flag(
        name = "whl_linux_libc",
        build_setting_default = default_whl_linux_libc,
        values = ["glibc", "musl"],
        **kwargs
    )

    string_flag(
        name = "whl_osx",
        build_setting_default = default_whl_osx,
        values = ["", "multiarch"],
        **kwargs
    )

    string_flag(
        name = "use_sdist",
        build_setting_default = default_use_sdist,
        values = ["auto", "only"],
        **kwargs
    )
