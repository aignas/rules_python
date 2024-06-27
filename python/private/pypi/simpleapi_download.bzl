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
A file that houses private functions used in the `bzlmod` extension with the same name.
"""

load("@bazel_features//:features.bzl", "bazel_features")
load("//python/private:auth.bzl", "get_auth")
load("//python/private:envsubst.bzl", "envsubst")
load("//python/private:normalize_name.bzl", "normalize_name")
load(":parse_simpleapi_html.bzl", "parse_simpleapi_html")

visibility("private")

def simpleapi_download(ctx, *, attr, parallel_download = True):
    """Download Simple API HTML.

    Args:
        ctx: The module_ctx or repository_ctx.
        attr: Contains the parameters for the download. They are grouped into a
          struct for better clarity. It must have attributes:
           * index_url: str, the index.
           * index_url_overrides: dict[str, str], the index overrides for
             separate packages.
           * extra_index_urls: Extra index URLs that will be looked up after
             the main is looked up.
           * sources: dict[str, struct], the sources to download things for.
             Each value is a struct having a `versions` attribute and a
             concatenated requirement lines.
           * envsubst: list[str], the envsubst vars for performing substitution in index url.
           * netrc: The netrc parameter for ctx.download, see http_file for docs.
           * auth_patterns: The auth_patterns parameter for ctx.download, see
               http_file for docs.
        parallel_download: A boolean to enable usage of bazel 7.1 non-blocking downloads.

    Returns:
        dict of pkg name to the parsed HTML contents - a list of structs.
    """
    index_url_overrides = {
        normalize_name(p): i
        for p, i in (attr.index_url_overrides or {}).items()
    }

    download_kwargs = {}
    if bazel_features.external_deps.download_has_block_param:
        download_kwargs["block"] = not parallel_download

    # NOTE @aignas 2024-03-31: we are not merging results from multiple indexes
    # to replicate how `pip` would handle this case.
    async_downloads = {}
    contents = {}
    index_urls = [attr.index_url] + attr.extra_index_urls
    for pkg, req in attr.sources.items():
        pkg_normalized = normalize_name(pkg)

        success = False
        for index_url in index_urls:
            result = read_simpleapi(
                ctx = ctx,
                url = "{}/{}/".format(
                    index_url_overrides.get(pkg_normalized, index_url).rstrip("/"),
                    pkg,
                ),
                attr = attr,
                versions = req.versions,
                cache_key = req.cache_key,
                **download_kwargs
            )
            if hasattr(result, "wait"):
                # We will process it in a separate loop:
                async_downloads.setdefault(pkg_normalized, []).append(
                    struct(
                        pkg_normalized = pkg_normalized,
                        wait = result.wait,
                    ),
                )
                continue

            if result.success:
                contents[pkg_normalized] = result.output
                success = True
                break

        if not async_downloads and not success:
            fail("Failed to download metadata from urls: {}".format(
                ", ".join(index_urls),
            ))

    if not async_downloads:
        return contents

    # If we use `block` == False, then we need to have a second loop that is
    # collecting all of the results as they were being downloaded in parallel.
    for pkg, downloads in async_downloads.items():
        success = False
        for download in downloads:
            result = download.wait()

            if result.success and download.pkg_normalized not in contents:
                contents[download.pkg_normalized] = result.output
                success = True

        if not success:
            fail("Failed to download metadata from urls: {}".format(
                ", ".join(index_urls),
            ))

    return contents

def read_simpleapi(ctx, url, attr, versions, cache_key, **download_kwargs):
    """Read SimpleAPI.

    Args:
        ctx: The module_ctx or repository_ctx. We use:
            * ctx.path
            * ctx.download
            * ctx.read
            * ctx.getenv or ctx.os.environ.get
        url: str, the url parameter that can be passed to ctx.download.
        versions: str, the version for which we want the metadata, used to
            construct a filename for outputing a file. Whilst it is not optimal
            to call the same URL multiple times for different package versions,
            it allows us to have a correct caching scheme for caching the
            results and not needed to refetch the metadata if the lock file
            does not change or if only certain packages change.
        cache_key: str, the unique cache_key that is used to construct the
            canonical_id.
        attr: The attribute that contains necessary info for downloading. The
          following attributes must be present:
           * envsubst: The envsubst values for performing substitutions in the URL.
           * netrc: The netrc parameter for ctx.download, see http_file for docs.
           * auth_patterns: The auth_patterns parameter for ctx.download, see
               http_file for docs.
        **download_kwargs: Any extra params to ctx.download.
            Note that output and auth will be passed for you.

    Returns:
        A similar object to what `download` would return except that in result.out
        will be the parsed simple api contents.
    """
    # NOTE @aignas 2024-03-31: some of the simple APIs use relative URLs for
    # the whl location and we cannot handle multiple URLs at once by passing
    # them to ctx.download if we want to correctly handle the relative URLs.
    # TODO: Add a test that env subbed index urls do not leak into the lock file.

    real_url = envsubst(
        url,
        attr.envsubst,
        ctx.getenv if hasattr(ctx, "getenv") else ctx.os.environ.get,
    )

    output_str = envsubst(
        url,
        attr.envsubst,
        # Use env names in the subst values - this will be unique over
        # the lifetime of the execution of this function and we also use
        # `+` as the separator to ensure that we don't get clashes.
        {e: "+{}+".format(e) for e in attr.envsubst}.get,
    )
    output_str = "++".join([output_str, versions])

    # Transform the URL into a valid filename
    for char in [":", "/", "\\", "-"]:
        output_str = output_str.replace(char, "_")

    output_str = output_str.strip("_").lower()

    output = ctx.path(output_str + ".html")

    # NOTE: this may have block = True or block = False in the download_kwargs
    download = ctx.download(
        url = [real_url],
        output = output,
        auth = get_auth(ctx, [real_url], ctx_attr = attr),
        canonical_id = output_str + "." + cache_key,
        allow_fail = True,
        **download_kwargs
    )

    if download_kwargs.get("block") == False:
        # Simulate the same API as ctx.download has
        return struct(
            wait = lambda: _read_index_result(ctx, download.wait(), output, url),
        )

    return _read_index_result(ctx, download, output, url)

def _read_index_result(ctx, result, output, url):
    if not result.success:
        return struct(success = False)

    content = ctx.read(output)

    output = parse_simpleapi_html(url = url, content = content)
    if output:
        return struct(success = True, output = output)
    else:
        return struct(success = False)
