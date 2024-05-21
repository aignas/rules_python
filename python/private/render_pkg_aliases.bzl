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
load(":whl_repo_name.bzl", "whl_repo_name")
load(":whl_target_platforms.bzl", "whl_platform_constraints_and_versions", "whl_target_platforms")

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

def whl_library_aliases(
        name,
        aliases,
        actual,
        no_match_error = "",
        extra_aliases = {},
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
        actual: The value that is going to be interpolated and passed to alias
            actual attribute.
        no_match_error: The error to be forwarded to the select. Optional.
        extra_aliases: The dictionary of extra aliases to render that are needed
            for libc and osx matching.
        **kwargs: Any extra kwargs to pass to `native.alias`.
    """
    native.alias(
        name = name,
        actual = ":pkg",
    )

    if type(actual) == type(""):
        for target_name, name in aliases.items():
            native.alias(
                name = name,
                actual = actual.format(target_name = target_name),
                **kwargs
            )
        return

    for target_name, name in aliases.items():
        for alias_name, s in extra_aliases.items():
            _actual = {
                k: v.format(target_name = target_name)
                for k, v in s.items()
                if k != "no_match_error"
            }
            native.alias(
                name = alias_name.format(target_name = target_name),
                actual = select(
                    _actual,
                    no_match_error = s.get("no_match_error", ""),
                ),
                visibility = ["//visibility:private"],
            )

        native.alias(
            name = name,
            actual = selects.with_or(
                {k: v.format(target_name = target_name) for k, v in actual.items()},
                no_match_error = no_match_error,
            ),
            **kwargs
        )

def _render_whl_library_aliases(
        *,
        name,
        hub_name,
        default_version,
        repo_aliases,
        aliases,
        dists = None,
        whl_constraints_and_versions = None,
        visibility = None):
    lines = [
        "name = \"{}\"".format(name),
        "aliases = {}".format(render.dict(aliases)),
    ]
    actual, has_default, extra_aliases = whl_select_dict(
        target_name = "{target_name}",  # So that we can use this as a template later
        hub_name = hub_name,
        default_version = default_version,
        repo_aliases = repo_aliases,
        dists = dists,
        whl_constraints_and_versions = whl_constraints_and_versions,
    )
    lines.append("actual = {}".format(
        render.dict(actual, key_repr = render.tuple),
    ))
    if extra_aliases:
        lines.append("extra_aliases = {}".format(
            render.dict({k: render.dict(v) for k, v in extra_aliases.items()}, value_repr = lambda x: x),
        ))
    if not has_default:
        lines.append("no_match_error = \"{}\"".format("TODO"))

    if visibility:
        lines.append("visibility = {}".format(render.list(visibility)))

    return "\n".join([
        "whl_library_aliases(",
    ] + [render.indent(line) + "," for line in lines] + [
        ")",
    ])

def _render_common_aliases(*, name, hub_name, aliases, default_version, group_name = None, whl_constraints_and_versions = None):
    lines = [
        """load("{}", "whl_library_aliases")""".format(
            str(Label("//python/private:render_pkg_aliases.bzl")),
        ),
        """package(default_visibility = ["//visibility:public"])""",
        _render_whl_library_aliases(
            name = name,
            hub_name = hub_name,
            default_version = default_version,
            repo_aliases = [
                alias
                for alias in aliases
                if not alias.filename
            ],
            dists = [
                (alias.filename, alias.target_platforms)
                for alias in aliases
                if alias.filename
            ],
            aliases = {
                PY_LIBRARY_PUBLIC_LABEL: PY_LIBRARY_IMPL_LABEL if group_name else PY_LIBRARY_PUBLIC_LABEL,
                WHEEL_FILE_PUBLIC_LABEL: WHEEL_FILE_IMPL_LABEL if group_name else WHEEL_FILE_PUBLIC_LABEL,
                DATA_LABEL: DATA_LABEL,
                DIST_INFO_LABEL: DIST_INFO_LABEL,
            },
            visibility = ["//_groups:__subpackages__"] if name.startswith("_") else None,
            whl_constraints_and_versions = whl_constraints_and_versions,
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

def _render_dist_config_settings(*, name, python_versions, whl_constraints_and_versions, visibility):
    lines = [
        "name = \"{}\"".format(name),
        "python_versions = {}".format(render.list(python_versions)),
    ]

    if whl_constraints_and_versions:
        for key, (value, value_repr) in {
            "constraint_values": (whl_constraints_and_versions.constraint_values, render.dict),
            "glibc_versions": (whl_constraints_and_versions.glibc_versions.keys(), render.list),
            "muslc_versions": (whl_constraints_and_versions.muslc_versions.keys(), render.list),
            "osx_versions": (whl_constraints_and_versions.osx_versions.keys(), render.list),
        }.items():
            if not value:
                continue

            lines.append("{} = {}".format(key, value_repr(value)))

    lines.append("visibility = {}".format(render.list(visibility)))
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

    versions, whl_constraints_and_versions, _aliases = _get_aliases(aliases = aliases)

    files = {}
    for name, pkg_aliases in _aliases.items():
        name = normalize_name(name)
        filename = "{}/BUILD.bazel".format(name)
        contents = _render_common_aliases(
            name = name,
            hub_name = hub_name,
            aliases = pkg_aliases,
            default_version = default_version,
            group_name = whl_group_mapping.get(name),
            whl_constraints_and_versions = whl_constraints_and_versions,
        )
        files[filename] = contents.strip()

    if requirement_cycles:
        files["_groups/BUILD.bazel"] = generate_group_library_build_bazel("", requirement_cycles)

    if whl_constraints_and_versions or versions:
        rules_python, _, _ = str(Label("//:unused")).partition("//")
        loads = [
            """load("{}//python/private:dist_config_settings.bzl", "dist_config_settings")""".format(rules_python),
        ]
        files["BUILD.bazel"] = "\n\n".join(
            [
                "\n".join(sorted(loads)),
                _render_dist_config_settings(
                    name = "dist_config_settings",
                    python_versions = versions,
                    whl_constraints_and_versions = whl_constraints_and_versions,
                    visibility = ["//:__subpackages__"],
                ),
            ],
        )

    return files

def _get_aliases(*, aliases):
    ret = {}
    versions = {}
    whl_platforms = {}
    extra_platforms = {}
    for whl_name, pkg_aliases in aliases.items():
        alias_target_platforms = {}
        ret[whl_name] = []
        for alias in pkg_aliases:
            if alias.version:
                versions[alias.version] = None

            if alias.filename:
                alias_target_platforms.setdefault(alias.filename, []).extend([
                    (alias.version, p)
                    for p in alias.target_platforms or [None]
                ])
            else:
                ret[whl_name].append(alias)

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
                    if p:
                        extra_platforms[p] = None
                    whl_platforms.setdefault(whl_platform, {})[(version, p)] = None

    if whl_platforms:
        whl_constraints_and_versions = whl_platform_constraints_and_versions(
            whl_platform_tags = whl_platforms,
            extra_platforms = extra_platforms,
        )
    else:
        whl_constraints_and_versions = None

    return sorted(versions), whl_constraints_and_versions, ret

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

def whl_select_dict(hub_name, target_name, default_version, dists = None, repo_aliases = None, whl_constraints_and_versions = None, condition_package = ""):
    """Return an actual label value (or a dict that can be used in a select).

    Args:
        hub_name: str, the hub name that the dists are located in.
        target_name: str, the target name to use. Can be a template token.
        default_version: str or None, the default version.
        dists: dict[str, (str, str | None)] a dict of distributions for the
            keys are filenames and the values are lists of version and target
            platforms tuples. The target platform can be a `None`.
        repo_aliases: list[(str, str)] a list of repo and version
            values that we should use for this whl.
        condition_package: str, used in tests to change where the conditions
            are located.
        whl_constraints_and_versions: TODO

    Returns:
        a dict or a string that can be used in an alias and a second parameter
        to know if the match can be found for all target platforms. If not,
        then we can construct the no_match_error. The dict can be used in
        @bazel_skylib//lib:selects.bzl#selects.with_or.
    """
    if not dists and not repo_aliases:
        fail("At least one of 'dists' and 'repo_aliases' is required")
    if dists and repo_aliases:
        fail("At most one of 'dists' and 'repo_aliases' can be specified")

    config_settings = {}
    extra_aliases = {}
    if repo_aliases:
        for alias in repo_aliases:
            if not alias.version or alias.version == default_version:
                config_settings[_DEFAULT_CONFIG_SETTING] = alias.repo
            if alias.version:
                config_settings["//:is_python_" + alias.version] = alias.repo

    if dists:
        result = _get_dist_config_setting_names(
            dists,
            default_version,
            whl_constraints_and_versions = whl_constraints_and_versions,
        )
        for prefix, cfgs in result.config_settings.items():
            if prefix.startswith(":"):
                prefix = prefix + "_"
            else:
                prefix = "@{}_{}//:".format(hub_name, whl_repo_name(prefix))

            for plat_label in cfgs:
                if plat_label:
                    plat_label = "//{}:{}".format(condition_package, plat_label)
                else:
                    plat_label = _DEFAULT_CONFIG_SETTING

                if plat_label in config_settings:
                    fail(
                        "Adding '{}' for the second time for {}, ".format(
                            plat_label,
                            prefix,
                        ) +
                        "this is already configured for {}".format(config_settings[plat_label]),
                    )
                config_settings[plat_label] = prefix

        if result.aliases:
            extra_aliases = {
                "{}_{}".format(prefix, target_name): _version_select(
                    hub_name = hub_name,
                    target_name = target_name,
                    **values
                )
                for prefix, values in result.aliases.items()
            }

    if len(config_settings) == 1 and _DEFAULT_CONFIG_SETTING in config_settings:
        return "{prefix}{target_name}".format(
            prefix = config_settings[_DEFAULT_CONFIG_SETTING],
            target_name = target_name,
        ), True, extra_aliases

    # Create the alias repositories which contains different select
    # statements  These select statements point to the different pip
    # whls that are based on a specific version of Python.
    items = {}
    for config_setting, prefix in config_settings.items():
        items.setdefault(prefix, []).append(config_setting)

    return {
        tuple(sorted(v)): "{prefix}{target_name}".format(
            prefix = prefix,
            target_name = target_name,
        )
        for prefix, v in sorted(items.items())
    }, _DEFAULT_CONFIG_SETTING in config_settings, extra_aliases

def _version_select(*, hub_name, target_name, all_versions, config_setting, filenames):
    alias = {}
    for filename, version in sorted(filenames.items(), key = lambda x: all_versions[x[1]]):
        filename_version = all_versions[version]
        if not alias:
            alias["//:is_{}_default".format(config_setting)] = "@{}_{}//:{}".format(
                hub_name,
                whl_repo_name(filename),
                target_name,
            )

        alias.update({
            "//:is_{}_{}".format(config_setting, config_setting_value): "@{}_{}//:{}".format(
                hub_name,
                whl_repo_name(filename),
                target_name,
            )
            for config_setting_value, version in all_versions.items()
            if filename_version <= version
        })

    alias["no_match_error"] = "Could not match, the target supports versions {}".format(all_versions.keys())
    return alias

def _get_dist_config_setting_names(dists, default_version, whl_constraints_and_versions):
    config_settings = {}
    defaults = {}
    extras = {}

    # TODO @aignas 2024-04-30: naming
    flavor_to_constraints = {
        "": ("whl_osx_version", whl_constraints_and_versions.osx_versions),
        "many": ("whl_glibc_version", whl_constraints_and_versions.glibc_versions),
        "musl": ("whl_muslc_version", whl_constraints_and_versions.muslc_versions),
    }

    # sort the incoming dists for deterministic output
    for filename, target_platforms_ in sorted(dists):
        extra_aliases = {}
        target = filename
        if filename.endswith(".whl"):
            version_aliases = {}
            parsed = parse_whl_name(filename)
            if parsed.abi_tag in ["none", "abi3"]:
                abis = [parsed.abi_tag]
                if parsed.platform_tag == "any":
                    defaults[filename] = None

            elif parsed.abi_tag.startswith("cp3"):
                abis = ["cpxy"]
            else:
                fail("BUG: the `select_whls` has returned an incompatible wheel: {}".format(filename))

            if parsed.platform_tag == "any":
                platforms = ["any"]
            else:
                platforms = []
                for p in whl_target_platforms(parsed.platform_tag):
                    head = p.flavor + p.os
                    tail = p.cpu
                    if "universal2" in parsed.platform_tag:
                        tail = "{}_universal2".format(tail)

                    if not p.versions or p.os not in ["linux", "osx"]:
                        platforms.append("{}_{}".format(head, tail))
                        continue

                    # TODO @aignas 2024-04-29: use an alias label instead
                    platforms.append("{}_{}".format(head, tail))

                    for v in p.versions:
                        config_setting_name, all_versions = flavor_to_constraints[p.flavor]
                        version_aliases.setdefault("{}_{}".format(head, tail), {
                            "all_versions": all_versions,
                            "config_setting": config_setting_name,
                            "filenames": {},
                        })["filenames"][filename] = "{}.{}".format(*v)

            names = [
                "whl_{}_{}".format(abi, target_platform)
                for target_platform in platforms
                for abi in abis
            ]

            for abi in abis:
                for target_platform, versions in version_aliases.items():
                    extra_aliases["whl_{}_{}".format(abi, target_platform)] = versions

        else:
            names = ["sdist"]
            defaults[filename] = None

        for (version, plat) in target_platforms_:
            for match in names:
                if match and plat:
                    tail = "{}_{}".format(match, plat)
                else:
                    tail = plat or match

                is_python = "is_python_{}_{}".format(version, tail)
                if match in extra_aliases:
                    target = match.replace("whl_", ":whl_cp{}_".format(version.replace(".", "")))
                else:
                    target = filename

                config_settings[is_python] = target
                if match in extra_aliases:
                    key = target.replace(":", "")
                    value = extra_aliases[match]
                    filenames = value.pop("filenames")

                    # TODO @aignas 2024-05-20: dehackify
                    extras.setdefault(key, dict(filenames = {}, **value))["filenames"].update(filenames)

                if version == default_version:
                    is_ = "is_{}".format(tail)
                    config_settings[is_] = target

    # TODO @aignas 2024-04-25: what to do with defaults by python version
    defaults = sorted(
        defaults,
        key = lambda f: (
            "-none-any.whl" not in f,
            "-abi3-any.whl" not in f,
            f,
        ),
    )
    config_settings[""] = defaults[0]

    ret = {}
    for setting, filename in config_settings.items():
        ret.setdefault(filename, []).append(setting)

    return struct(
        config_settings = ret,
        aliases = extras,
    )
