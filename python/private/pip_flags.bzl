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

"""Values and helpers for pip_repository related flags.

NOTE: The transitive loads of this should be kept minimal. This avoids loading
unnecessary files when all that are needed are flag definitions.
"""

load("//python/private:enum.bzl", "enum")

# Determines if we should use whls for third party
#
# buildifier: disable=name-conventions
UseWhlFlag = enum(
    # Automatically decide the effective value based on environment, target
    # platform and the presence of distributions for a particular package.
    AUTO = "auto",
    # Do not use whl distributions and instead build the whls from `sdist`.
    NO = "no",
)

# Determines if we should enable usage of `abi3` wheels.
#
# buildifier: disable=name-conventions
UseWhlAbi3Flag = enum(
    # Automatically decide the effective value based on environment, target
    # platform and the presence of distributions for a particular package.
    AUTO = "auto",
    # Do not use whl distributions with the `abi3` tag
    NO = "no",
)

# Determines if we should enable usage of `cpxy` wheels (e.g. cp38, cp311, etc).
#
# buildifier: disable=name-conventions
UseWhlAbiCpFlag = enum(
    # Automatically decide the effective value based on environment, target
    # platform and the presence of distributions for a particular package.
    AUTO = "auto",
    # Do not use whl distributions with the `cpxy` tag. This could be useful to
    # keep the dependency closure compatible with any Python toolchain and it
    # could be used in scenarios where custom toolchains are defined and used.
    NO = "no",
)

# Determines whether platform-specific wheels should be used.
#
# buildifier: disable=name-conventions
UseWhlPlatformFlag = enum(
    # Automatically decide the effective value based on environment, target
    # platform and the presence of distributions for a particular package.
    AUTO = "auto",
    # Do not use whl distributions that are targeting a particular platform.
    # This allows the host platform to use the same python packages as any
    # other target platform, which could be useful in more complex cases.
    NO = "no",
)

# Determines whether universal wheels should be preferred over arch platform specific ones.
#
# buildifier: disable=name-conventions
UniversalWhlFlag = enum(
    # Prefer platform-specific wheels over universal wheels.
    ARCH = "arch",
    # Prefer universal wheels over platform-specific wheels.
    UNIVERSAL = "universal",
)

# Determines which libc flavor is preferred when selecting the linux whl distributions.
#
# buildifier: disable=name-conventions
WhlLibcFlag = enum(
    # Prefer glibc wheels (e.g. manylinux_2_17_x86_64)
    GLIBC = "glibc",
    # Prefer musl wheels (e.g. musllinux_2_17_x86_64)
    MUSL = "musl",
)
