"""A repository with the targets of a package that is replaced by user provided targets."""

load(":labels.bzl", "DATA_LABEL", "DIST_INFO_LABEL", "EXTRACTED_WHEEL_FILES", "PY_SRCS_LABEL", "WHEEL_FILE")

_BUILD = """\
package(default_visibility = ["//visibility:public"])

alias(
    name = "{srcs}",
    actual = "{target}",
)

filegroup(
    name = "{whl_file}",
    srcs = {whl},
)

filegroup(
    name = "{dist_info}",
    srcs = {dist_info_srcs},
)

filegroup(
    name = "{data}",
    srcs = [],
)

filegroup(
    name = "{extracted_whl_files}",
    srcs = [],
)
"""

def _impl(rctx):
    rctx.file("BUILD.bazel", _BUILD.format(
        srcs = PY_SRCS_LABEL,
        target = str(rctx.attr.target),
        whl_file = WHEEL_FILE,
        whl = repr([str(rctx.attr.whl)] if rctx.attr.whl else []),
        dist_info = DIST_INFO_LABEL,
        dist_info_srcs = repr([str(rctx.attr.dist_info)] if rctx.attr.dist_info else []),
        data = DATA_LABEL,
        extracted_whl_files = EXTRACTED_WHEEL_FILES,
    ))

replaced_whl_repo = repository_rule(
    implementation = _impl,
    attrs = {
        "dist_info": attr.label(doc = "The optional `dist_info` target, e.g. with the `entry_points.txt`."),
        "target": attr.label(mandatory = True, doc = "The target that provides the sources of the package."),
        "whl": attr.label(doc = "The optional wheel file of the package."),
    },
    doc = """\
A repository with the `srcs`, `whl_file`, `dist_info`, `data` and
`extracted_whl_files` targets of a package that come from the user provided
targets, so that a `whl_deps_repo` can create the other targets.

INTERNAL USE ONLY.""",
)
