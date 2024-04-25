# Copyright 2023 The Bazel Authors. All rights reserved.
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
A starlark implementation of the wheel platform tag parsing to get the target platform.
"""

load(":parse_whl_name.bzl", "parse_whl_name", "normalize_platform_tag")

# The order of the dictionaries is to keep definitions with their aliases next to each
# other
_CPU_ALIASES = {
    "x86_32": "x86_32",
    "i386": "x86_32",
    "i686": "x86_32",
    "x86": "x86_32",
    "x86_64": "x86_64",
    "amd64": "x86_64",
    "aarch64": "aarch64",
    "arm64": "aarch64",
    "ppc": "ppc",
    "ppc64": "ppc",
    "ppc64le": "ppc",
    "s390x": "s390x",
    "armv6l": "arm",
    "armv7l": "arm",
}  # buildifier: disable=unsorted-dict-items

_OS_PREFIXES = {
    "linux": "linux",
    "manylinux": "linux",
    "musllinux": "linux",
    "macos": "osx",
    "win": "windows",
}  # buildifier: disable=unsorted-dict-items

def select_whls(*, whls, want_pys = [], want_abis = [], want_platforms = []):
    """Select a subset of wheels suitable for target platforms from a list.

    Args:
        whls(list[struct]): A list of candidates.
        want_pys(list[str]): A list of Python versions that we should care about.
        want_abis(list[str]): A list of ABIs that are supported.
        want_platforms(str): The platforms

    Returns:
        None or a struct with `url`, `sha256` and `filename` attributes for the
        selected whl. If no match is found, None is returned.
    """
    if not whls:
        return whls

    want_platforms = [
        _normalize_platform(p)
        for p in want_platforms
    ]

    candidates = []
    for whl in whls:
        parsed = parse_whl_name(whl.filename)
        if parsed.abi_tag not in want_abis or not want_abis:
            # Filter out incompatible ABIs
            continue

        if parsed.platform_tag == "any" or not want_platforms:
            candidates.append(whl)
            continue

        compatible = False
        for p in whl_target_platforms(parsed.platform_tag):
            if p.target_platform in want_platforms:
                compatible = True
                break

        if compatible:
            candidates.append(whl)

    return candidates

def _normalize_platform(platform):
    cpus = _cpu_from_tag(platform)
    if len(cpus) > 1:
        fail("Expected the '{}' to only map to a single CPU, but got: {}".format(
            platform,
            cpus,
        ))

    for prefix, os in _OS_PREFIXES.items():
        if platform.startswith(prefix):
            return "{}_{}".format(os, cpus[0])

    # If it is not known, just return it back
    return platform

def whl_target_platforms(platform_tag, abi_tag = ""):
    """Parse the wheel abi and platform tags and return (os, cpu) tuples.

    Args:
        platform_tag (str): The platform_tag part of the wheel name. See
            ./parse_whl_name.bzl for more details.
        abi_tag (str): The abi tag that should be used for parsing.

    Returns:
        A list of structs, with attributes:
        * os: str, one of the _OS_PREFIXES values
        * cpu: str, one of the _CPU_PREFIXES values
        * abi: str, the ABI that the interpreter should have if it is passed.
        * target_platform: str, the target_platform that can be given to the
          wheel_installer for parsing whl METADATA.
    """
    platform_tag = normalize_platform_tag(platform_tag)
    cpus = _cpu_from_tag(platform_tag)

    abi = None
    if abi_tag not in ["", "none", "abi3"]:
        abi = abi_tag

    for prefix, os in _OS_PREFIXES.items():
        if not platform_tag.startswith(prefix):
            continue

        versions = []
        if prefix in ["manylinux", "musllinux", "macos"]:
            for p in platform_tag.split("."):
                _, _, tail = p.partition("_")
                major, _, tail = tail.partition("_")
                minor, _, tail = tail.partition("_")
                versions.append((int(major), int(minor)))

        return [
            struct(
                os = os,
                cpu = cpu,
                abi = abi,
                target_platform = "_".join([abi, os, cpu] if abi else [os, cpu]),
                flavor = _get_flavor(platform_tag),
                versions = versions,
            )
            for cpu in cpus
        ]

    print("WARNING: ignoring unknown platform_tag os: {}".format(platform_tag))  # buildifier: disable=print
    return []

def _get_flavor(tag):
    if "musl" in tag:
        return "musl"
    if "many" in tag:
        return "many"
    return ""

def _cpu_from_tag(tag):
    for input, cpu in _CPU_ALIASES.items():
        if tag.endswith(input):
            return [cpu]

    if tag == "win32":
        return ["x86_32"]
    elif tag == "win_ia64":
        return []
    elif tag.startswith("macosx"):
        if tag.endswith("universal2"):
            return ["x86_64", "aarch64"]
        elif tag.endswith("universal"):
            return ["x86_64", "aarch64"]
        elif tag.endswith("intel"):
            return ["x86_32"]

    return []
