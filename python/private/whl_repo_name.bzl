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

"A simple module to generate a repo name from filename."

load(":normalize_name.bzl", "normalize_name")
load(":parse_whl_name.bzl", "parse_whl_name")

def whl_repo_name(filename):
    """Repo name for a dist

    Args:
        filename: str, the full filename of an sdist.

    Returns:
        A name of a whl_library repository to use for the downloaded dist.
    """
    filename = filename.lower()

    if filename.endswith(".whl"):
        whl = parse_whl_name(filename)

        # This uses all of the present components and emits a few for shorter
        # paths. In particular, we use a single platform_tag and python_tag as
        # they don't add extra value in partitioning the whl repos.
        return "_".join([
            normalize_name(whl.distribution),
            normalize_name("{}_{}".format(whl.version, whl.build_tag) if whl.build_tag else whl.version),
            whl.python_tag.rpartition(".")[-1],  # just pick the last one
            whl.abi_tag,
            whl.platform_tag.partition(".")[0],
        ])

    filename_no_ext = filename.lower()
    for ext in [".tar.gz", ".zip", ".tar"]:
        if filename_no_ext.endswith(ext):
            filename_no_ext = filename_no_ext[:-len(ext)]
            break

    if filename_no_ext == filename.lower():
        fail("unknown sdist extension: {}".format(filename_no_ext))

    return normalize_name(filename_no_ext) + "_sdist"
