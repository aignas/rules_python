"""A repository with the targets of a package that is built from its sdist by a user provided macro."""

load(":labels.bzl", "DATA_LABEL", "DIST_INFO_LABEL", "EXTRACTED_WHEEL_FILES", "PY_SRCS_LABEL", "WHEEL_FILE")

def render_built_whl_build(*, builder, builder_symbol, sdist, package_name, version):
    """Render the BUILD file that calls the sdist builder.

    The builder macro is called with:
    * `name`: the name of the library with the sources of the package, which
      needs to provide `PyInfo` and must not depend on the other packages.
    * `sdist`: the label of the sdist file.
    * `package_name`, `version`: the package name and version.
    * `whl_name`: the name of the target with the built wheel file.
    * `dist_info_name`: the name of the target with the `.dist-info` files,
      e.g. the `entry_points.txt`.
    * `visibility`: the visibility of the targets.

    The builder should accept `**kwargs`, so that new arguments can be added.

    Args:
        builder: {type}`str` the canonical label of the `.bzl` file.
        builder_symbol: {type}`str` the name of the macro in the file.
        sdist: {type}`str` the canonical label of the sdist file.
        package_name: {type}`str` the name of the package.
        version: {type}`str` the version of the package.

    Returns:
        {type}`str` the BUILD file contents.
    """
    return """load({builder}, _sdist_builder = {builder_symbol})

package(default_visibility = ["//visibility:public"])

_sdist_builder(
    name = {srcs},
    sdist = {sdist},
    package_name = {package_name},
    version = {version},
    whl_name = {whl_file},
    dist_info_name = {dist_info},
    visibility = ["//visibility:public"],
)

filegroup(
    name = {data},
    srcs = [],
)

filegroup(
    name = {extracted_whl_files},
    srcs = [],
)
""".format(
        builder = repr(builder),
        builder_symbol = repr(builder_symbol),
        srcs = repr(PY_SRCS_LABEL),
        sdist = repr(sdist),
        package_name = repr(package_name),
        version = repr(version),
        whl_file = repr(WHEEL_FILE),
        dist_info = repr(DIST_INFO_LABEL),
        data = repr(DATA_LABEL),
        extracted_whl_files = repr(EXTRACTED_WHEEL_FILES),
    )

def _impl(rctx):
    rctx.file("BUILD.bazel", render_built_whl_build(
        builder = rctx.attr.builder,
        builder_symbol = rctx.attr.builder_symbol,
        sdist = rctx.attr.sdist,
        package_name = rctx.attr.package_name,
        version = rctx.attr.version,
    ))

built_whl_repo = repository_rule(
    implementation = _impl,
    attrs = {
        "builder": attr.string(mandatory = True, doc = "The canonical label of the `.bzl` file with the builder macro."),
        "builder_symbol": attr.string(mandatory = True, doc = "The name of the builder macro."),
        "package_name": attr.string(mandatory = True, doc = "The name of the package."),
        "sdist": attr.string(mandatory = True, doc = "The canonical label of the sdist file."),
        "version": attr.string(mandatory = True, doc = "The version of the package."),
    },
    doc = """A repository with the `srcs`, `whl_file`, `dist_info`, `data` and
`extracted_whl_files` targets of a package that is built from its sdist by a
user provided macro, so that a `whl_deps_repo` can create the other targets.

INTERNAL USE ONLY.""",
)
