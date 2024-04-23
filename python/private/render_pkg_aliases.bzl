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

"""render_pkg_aliases is a function to generate BUILD.bazel contents used to create user-friendly aliases.

This is used in bzlmod and non-bzlmod setups."""

load("@bazel_skylib//lib:selects.bzl", "selects")
load(
    "//python/pip_install/private:generate_group_library_build_bazel.bzl",
    "generate_group_library_build_bazel",
)  # buildifier: disable=bzl-visibility
load(
    ":labels.bzl",
    "DATA_LABEL",
    "DIST_INFO_LABEL",
    "PY_LIBRARY_IMPL_LABEL",
    "PY_LIBRARY_PUBLIC_LABEL",
    "WHEEL_FILE_IMPL_LABEL",
    "WHEEL_FILE_PUBLIC_LABEL",
)
load(":normalize_name.bzl", "normalize_name")
load(":parse_whl_name.bzl", "parse_whl_name")
load(":text_util.bzl", "render")

NO_MATCH_ERROR_MESSAGE_TEMPLATE = """\
No matching wheel for current configuration's Python version.

The current build configuration's Python version doesn't match any of the Python
versions available for this wheel. This wheel supports the following Python versions:
    {versions}

As matched by the `@{rules_python}//python/config_settings:is_python_<version>`
configuration settings.

To determine the current configuration's Python version, run:
    `bazel config <config id>` (shown further below)
and look for
    {rules_python}//python/config_settings:python_version

If the value is missing, then the "default" Python version is being used,
which has a "null" version value and will not match version constraints.
"""

_DEFAULT_CONFIG_SETTING = "//conditions:default"

# TODO buildifier: disable=function-docstring
def whl_library_aliases(
        name,
        aliases,
        default_version = None,
        versions = None,
        hub_name = None,
        dists = None,
        **kwargs):
    """Create all macros for a given package.

    This is getting the config settings and then creating a list of aliases. The
    main idea is to use a macro that can be easily changed and we don't need to
    rely on inspecting generating code too much, we could test the macro
    separately.

    This is for internal use only.

    Args:
        name: str, the name of the whl package, normalized.
        aliases: the dictinoary of aliases that need to be created for the
            target whl.
        default_version: the default python version, if any.
        hub_name: the hub name that the dists are located in.
        dists: the dist filenames and the target platforms.
        versions: TODO
        **kwargs: Any extra kwargs to pass to `native.alias`.
    """
    native.alias(
        name = name,
        actual = ":pkg",
    )

    actual, has_default = whl_select_dict(
        target_name = "{target_name}",  # So that we can use this as a template later
        hub_name = hub_name,
        default_version = default_version,
        versions = versions,
        dists = dists,
    )

    if type(actual) == type(""):
        for target_name, name in aliases.items():
            native.alias(
                name = name,
                actual = actual.format(target_name = target_name),
                **kwargs
            )
        return

    if not has_default:
        # This is to avoid templating too much
        no_match_error = NO_MATCH_ERROR_MESSAGE_TEMPLATE.format(
            versions = ", ".join([c[1] for c in versions]),
            # TODO @aignas 2024-04-22: use a proper thing
            rules_python = "@rules_python",
        )
    else:
        no_match_error = ""

    for target_name, name in aliases.items():
        native.alias(
            name = name,
            actual = selects.with_or(
                {
                    k: v.format(target_name = target_name)
                    for k, v in actual.items()
                },
                no_match_error = no_match_error,
            ),
            **kwargs
        )

def whl_select_dict(hub_name, target_name, default_version, dists = None, versions = None, condition_package = ""):
    """Return an actual label value (or a dict that can be used in a select).

    Args:
        hub_name: str, the hub name that the dists are located in.
        target_name: str, the target name to use. Can be a template token.
        default_version: str or None, the default version.
        dists: dict[str, (str, str | None)] a dict of distributions for the
            keys are filenames and the values are lists of version and target
            platforms tuples. The target platform can be a `None`.
        versions: list[(str, str)] a list of repo and version
            values that we should use for this whl.
        condition_package: str, used in tests to change where the conditions
            are located.

    Returns:
        a dict or a string that can be used in an alias and a second parameter
        to know if the match can be found for all target platforms. If not,
        then we can construct the no_match_error. The dict can be used in
        @bazel_skylib//lib:selects.bzl#selects.with_or.
    """
    if not dists and not versions:
        fail("At least one of 'dists' and 'versions' is required")
    if dists and versions:
        fail("At most one of 'dists' and 'versions' can be specified")

    config_settings = {}
    if versions:
        for alias in versions:
            if not alias.version or alias.version == default_version:
                config_settings[_DEFAULT_CONFIG_SETTING] = alias.repo
            if alias.version:
                config_settings["//:is_python_" + alias.version] = alias.repo

    if dists:
        defaults = []
        for filename, cfgs in _get_dist_config_setting_names(dists, default_version).items():
            repo = "{}_{}".format(hub_name, _get_repo_name(filename))
            for plat_label in cfgs:
                if plat_label:
                    plat_label = "//{}:{}".format(
                        condition_package,
                        plat_label,
                    )
                else:
                    defaults.append(filename)
                    continue

                if plat_label in config_settings:
                    fail(
                        "Adding '{}' for the second time for {}, ".format(
                            plat_label,
                            repo,
                        ) +
                        "this is already configured for {}".format(config_settings[plat_label]),
                    )
                config_settings[plat_label] = repo

        # Select the only default if there is a single thing
        if len(defaults) == 1:
            repo = "{}_{}".format(hub_name, _get_repo_name(defaults[0]))
            config_settings[_DEFAULT_CONFIG_SETTING] = repo
        elif defaults:
            # whl and sdist is in here, let's chose the whl
            whl_defaults = [d for d in defaults if d.endswith(".whl")]
            if len(whl_defaults) != 1:
                fail("TODO")
            else:
                repo = "{}_{}".format(hub_name, _get_repo_name(whl_defaults[0]))
                config_settings[_DEFAULT_CONFIG_SETTING] = repo

        print(config_settings)

    if len(config_settings) == 1 and _DEFAULT_CONFIG_SETTING in config_settings:
        return "@{repo}//:{target_name}".format(
            repo = config_settings[_DEFAULT_CONFIG_SETTING],
            target_name = target_name,
        ), True

    # Create the alias repositories which contains different select
    # statements  These select statements point to the different pip
    # whls that are based on a specific version of Python.
    items = {}
    for config_setting, repo in config_settings.items():
        items.setdefault(repo, []).append(config_setting)

    return {
        "@{repo}//:{target_name}".format(
            repo = repo,
            target_name = target_name,
        ): sorted(v)
        for repo, v in sorted(items.items())
    }, _DEFAULT_CONFIG_SETTING in config_settings

def _render_whl_library_aliases(
        *,
        name,
        hub_name,
        default_version,
        versions,
        aliases,
        dists = None,
        visibility = None):
    lines = [
        "name = \"{}\"".format(name),
        "aliases = {}".format(render.dict(aliases)),
        "default_version = \"{}\"".format(default_version),
    ]
    if versions:
        lines.append("versions = {}".format(render.list(versions)))
    elif dists:
        lines.append("hub_name = \"{}\"".format(hub_name))
        lines.append("dists = {}".format(
            render.dict(dists, value_repr = render.list),
        ))

    if visibility:
        lines.append("visibility = {}".format(render.list(visibility)))

    return "\n".join([
        "whl_library_aliases(",
    ] + [render.indent(line) + "," for line in lines] + [
        ")",
    ])

def _render_common_aliases(*, name, hub_name, aliases, default_version, group_name = None):
    lines = [
        """load("{}", "whl_library_aliases")""".format(
            str(Label("//python/private:render_pkg_aliases.bzl")),
        ),
        """package(default_visibility = ["//visibility:public"])""",
        _render_whl_library_aliases(
            name = name,
            hub_name = hub_name,
            default_version = default_version,
            versions = [
                (alias.repo, alias.version)
                for alias in aliases
                if not alias.filename
            ],
            dists = {
                alias.filename: alias.target_platforms
                for alias in aliases
                if alias.filename
            },
            aliases = {
                PY_LIBRARY_PUBLIC_LABEL: PY_LIBRARY_IMPL_LABEL if group_name else PY_LIBRARY_PUBLIC_LABEL,
                WHEEL_FILE_PUBLIC_LABEL: WHEEL_FILE_IMPL_LABEL if group_name else WHEEL_FILE_PUBLIC_LABEL,
                DATA_LABEL: DATA_LABEL,
                DIST_INFO_LABEL: DIST_INFO_LABEL,
            },
            visibility = ["//_groups:__subpackages__"] if name.startswith("_") else None,
        ),
    ]
    if group_name:
        lines.extend(
            [
                render.alias(
                    name = "pkg",
                    actual = repr("//_groups:{}_pkg".format(group_name)),
                ),
                render.alias(
                    name = "whl",
                    actual = repr("//_groups:{}_whl".format(group_name)),
                ),
            ],
        )

    return "\n\n".join(lines)

def _render_dist_config_settings(*, name, python_versions, whl_platforms, visibility):
    lines = [
        "name = \"{}\"".format(name),
        "python_versions = {}".format(render.list(python_versions)),
        "whl_platforms = {}".format(render.list(whl_platforms)),
        "visibility = {}".format(render.list(visibility)),
    ]
    return "\n".join([
        "dist_config_settings(",
    ] + [
        render.indent(line + ",")
        for line in lines
    ] + [
        ")",
    ])

def render_pkg_aliases(*, hub_name, aliases, default_version = None, requirement_cycles = None):
    """Create alias declarations for each PyPI package.

    The aliases should be appended to the pip_repository BUILD.bazel file. These aliases
    allow users to use requirement() without needed a corresponding `use_repo()` for each dep
    when using bzlmod.

    Args:
        hub_name: str, the name of the hub repo.
        aliases: dict, the keys are normalized distribution names and values are the
            whl_alias instances.
        default_version: the default python version to be used for the aliases.
        requirement_cycles: any package groups to also add.

    Returns:
        A dict of file paths and their contents.
    """
    contents = {}
    if not aliases:
        return contents
    elif type(aliases) != type({}):
        fail("The aliases need to be provided as a dict, got: {}".format(type(aliases)))

    whl_group_mapping = {}
    if requirement_cycles:
        requirement_cycles = {
            name: [normalize_name(whl_name) for whl_name in whls]
            for name, whls in requirement_cycles.items()
        }

        whl_group_mapping = {
            whl_name: group_name
            for group_name, group_whls in requirement_cycles.items()
            for whl_name in group_whls
        }

    whl_platforms, _aliases = _get_aliases(
        aliases = aliases,
        default_version = default_version,
    )

    files = {
        "{}/BUILD.bazel".format(normalize_name(name)): _render_common_aliases(
            name = normalize_name(name),
            hub_name = hub_name,
            aliases = pkg_aliases,
            default_version = default_version,
            group_name = whl_group_mapping.get(normalize_name(name)),
        ).strip()
        for name, pkg_aliases in _aliases.items()
    }
    if requirement_cycles:
        files["_groups/BUILD.bazel"] = generate_group_library_build_bazel("", requirement_cycles)
    if whl_platforms:
        rules_python, _, _ = str(Label("//:unused")).partition("//")
        loads = [
            """load("{}//python/private:dist_config_settings.bzl", "dist_config_settings")""".format(rules_python),
        ]
        files["BUILD.bazel"] = "\n\n".join(
            [
                "\n".join(sorted(loads)),
                _render_dist_config_settings(
                    name = "dist_config_settings",
                    python_versions = sorted({
                        v[0]: None
                        for version_platforms in whl_platforms.values()
                        for v in version_platforms
                    }),
                    whl_platforms = sorted([
                        p
                        for p in whl_platforms
                        if p != "any"
                    ]),
                    visibility = ["//visibility:public"],
                ),
            ],
        )

    return files

def _get_aliases(*, aliases):
    ret = {}
    whl_platforms = {}
    for whl_name, pkg_aliases in aliases.items():
        alias_target_platforms = {}
        ret[whl_name] = []
        for alias in pkg_aliases:
            if not alias.filename:
                ret[whl_name].append(alias)
                continue

            _target_plats = alias_target_platforms.setdefault(alias.filename, [])
            if alias.target_platforms:
                _target_plats.extend([(alias.version, p) for p in alias.target_platforms])
            else:
                _target_plats.append((alias.version, None))

        for filename, target_platforms in alias_target_platforms.items():
            ret[whl_name].append(
                whl_alias(
                    filename = filename,
                    target_platforms = target_platforms,
                ),
            )

            whl_platform = parse_whl_name(filename).platform_tag if filename.endswith(".whl") else None
            if whl_platform:
                for version, p in target_platforms:
                    whl_platforms.setdefault(whl_platform, {})[(version, p)] = None

    return whl_platforms, ret

def _get_repo_name(filename):
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

def _get_dist_config_setting_names(dists, default_version):
    config_settings = {}
    seen_platforms = {}

    for filename, target_platforms_ in sorted(dists.items(), key = lambda x: _more_specific_first(x[0])):
        parsed = parse_whl_name(filename) if filename.endswith(".whl") else None
        for (version, plat) in target_platforms_:
            dist_types = ["", "whl" if parsed else "sdist"]
            names = []
            for dist_type in dist_types:
                if version == default_version:
                    if dist_type == "":
                        name = ""
                    else:
                        name = "is_{}".format(dist_type)
                    names.append(name)

                if dist_type == "":
                    name = "is_python_{}".format(version)
                else:
                    name = "is_python_{}_{}".format(version, dist_type)
                names.append(name)

            for name in names:
                config_settings.setdefault(name, []).append(filename)

    ret = {}
    for setting, filenames in config_settings.items():
        filenames = sorted(filenames, key = _more_specific_first)
        ret.setdefault(filenames[0], []).append(setting)

    return ret

def _more_specific_first(filename):
    if not filename.endswith(".whl"):
        return (
            True,
        )

    parsed = parse_whl_name(filename)

    # This ensures that we get the correct priority for the `auto` value of the
    # string flags
    return (
        False,
        parsed.abi_tag == "none",
        parsed.abi_tag == "abi3",
        parsed.abi_tag not in ["none", "abi3"],
        parsed.platform_tag == "any",
        "musl" in parsed.platform_tag,
        "many" in parsed.platform_tag,
        "linux" in parsed.platform_tag,
        "universal2" in parsed.platform_tag,
    )

def whl_alias(*, repo = None, version = None, filename = None, target_platforms = None):
    """The bzl_packages value used by by the render_pkg_aliases function.

    This contains the minimum amount of information required to generate correct
    aliases in a hub repository.

    Args:
        repo: str, the repo of where to find the things to be aliased.
        version: optional(str), the version of the python toolchain that this
            whl alias is for. If not set, then non-version aware aliases will be
            constructed. This is mainly used for better error messages when there
            is no match found during a select.
        filename: The filename of the dist that the aliases need to be created for.
        target_platforms: The target platforms that the dist is targeting. This
            is only needed for `sdist` or `any` dists that target a subset of
            platforms.

    Returns:
        a struct with the validated and parsed values.
    """
    attrs = dict(
        repo = repo,
        version = version,
        filename = filename,
    )
    if filename:
        attrs["target_platforms"] = target_platforms

    return struct(**attrs)
