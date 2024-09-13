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

"A semver version parser"

def _key(version):
    return (
        version.pre_release == "",
        tuple([
            (
                i if not i.isdigit() else "",
                # digit values take precedence
                int(i) if i.isdigit() else 0,
            )
            for i in version.pre_release.split(".")
        ]) if version.pre_release else None,
        version.patch,
        version.minor,
        version.major,
    )

def semver(version):
    """Parse the semver version and return the values as a struct.

    Args:
        version: {type}`str` the version string

    Returns:
        A {type}`struct` with `major`, `minor`, `patch` and `build` attributes.
    """

    # Implement the https://semver.org/ spec
    major, _, version = version.partition(".")
    minor, _, version = version.partition(".")
    patch, _, build = version.partition("+")
    patch, _, pre_release = patch.partition("-")

    public = struct(
        # use semver vocabulary here
        major = int(major),
        minor = int(minor or "0"),
        # NOTE: this is called `micro` in the Python interpreter versioning scheme
        patch = int(patch or "0"),
        pre_release = pre_release,
        build = build,
        # buildifier: disable=uninitialized
        key = lambda: _key(self.actual),
    )
    self = struct(actual = public)
    return public
