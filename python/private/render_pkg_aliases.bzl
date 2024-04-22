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
load(":whl_target_platforms.bzl", "whl_target_platforms")

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
def whl_library_aliases(name, targets, default_version, config_settings = None, dists = None, **kwargs):
    if not dists and config_settings:
        fail("At least one of 'dists' and 'config_settings' is required")

    if dists:
        has_any = False
        config_settings = []
        has_default = False
        for filename, target_platforms in dists.items():
            has_default = False
            is_any = filename.endswith("py3-none-any.whl")
            has_any = has_any or is_any

            repo = "{}_{}".format(name, _get_repo_name(filename))
            for version, p in target_platforms:
                for plat_label in _get_dist_config_settings(
                    filename = filename,
                    major_minor = version,
                    target_platform = p,
                    is_default_version = version == default_version or (has_any and is_any),
                ).keys():
                    if plat_label == "":
                        if not has_default:
                            config_settings.append((repo, _DEFAULT_CONFIG_SETTING))
                            has_default = True
                    else:
                        config_settings.append((repo, "//:" + plat_label))

    if len(config_settings) == 1 and not config_settings[0].version:
        alias = config_settings[0]
        for target_name, name in targets.items():
            native.alias(
                name = name,
                actual = "@{repo}//:{name}".format(
                    repo = alias.repo,
                    name = target_name,
                ),
                **kwargs
            )
        return

    # Create the alias repositories which contains different select
    # statements  These select statements point to the different pip
    # whls that are based on a specific version of Python.
    items = {}
    no_match_error = "tmpl"
    for repo, config_setting in config_settings:
        if config_setting == _DEFAULT_CONFIG_SETTING:
            if no_match_error == "":
                continue
            no_match_error = ""
        items.setdefault(repo, []).append(config_setting)

    if no_match_error:
        # This is to avoid templating too much
        no_match_error = NO_MATCH_ERROR_MESSAGE_TEMPLATE.format(
            versions = "\n,    ".join([c[1] for c in config_settings]),
            # TODO @aignas 2024-04-22: use a proper thing
            rules_python = "@rules_python",
        )

    for target_name, name in targets.items():
        native.alias(
            name = name,
            actual = selects.with_or(
                {
                    tuple(v) if len(v) > 1 else v[0]: "@{repo}//:{name}".format(
                        repo = repo,
                        name = target_name,
                    )
                    for repo, v in sorted(items.items())
                },
                no_match_error = no_match_error,
            ),
            **kwargs
        )

def _render_whl_library_aliases(
        *,
        name,
        config_settings,
        targets,
        dists = None,
        default_version = None,
        visibility = None):
    lines = [
        "name = \"{}\"".format(name),
        "targets = {}".format(render.dict(targets)),
    ]
    if default_version:
        lines.append("default_version = {}".format(repr(default_version)))

    if config_settings:
        lines.append("config_settings = {}".format(render.list(config_settings)))
    elif dists:
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

def _render_common_aliases(*, hub_name, name, default_version, aliases, group_name = None):
    lines = [
        """load("@rules_python//python/private:render_pkg_aliases.bzl", "whl_library_aliases")""",
        """package(default_visibility = ["//visibility:public"])""",
        render.alias(
            name = name,
            actual = repr(":pkg"),
        ),
        _render_whl_library_aliases(
            name = hub_name,
            default_version = default_version,
            config_settings = [
                (alias.repo, alias.config_setting)
                for alias in aliases
                if not alias.filename
            ],
            dists = {
                alias.filename: alias.target_platforms
                for alias in aliases
                if alias.filename
            },
            targets = {
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

    hub_config_settings, _aliases = _get_aliases(
        aliases = aliases,
        default_version = default_version,
    )

    files = {
        "{}/BUILD.bazel".format(normalize_name(name)): _render_common_aliases(
            hub_name = hub_name,
            name = normalize_name(name),
            aliases = pkg_aliases,
            default_version = default_version,
            group_name = whl_group_mapping.get(normalize_name(name)),
        ).strip()
        for name, pkg_aliases in _aliases.items()
    }
    if requirement_cycles:
        files["_groups/BUILD.bazel"] = generate_group_library_build_bazel("", requirement_cycles)
    if hub_config_settings:
        rules_python, _, _ = str(Label("//:unused")).partition("//")
        loads = [
            """load("{}//python/config_settings:config_settings.bzl", "is_python_config_setting")""".format(rules_python),
            """load("{}//python/private:dist_config_settings.bzl", "dist_config_settings")""".format(rules_python),
        ]
        files["BUILD.bazel"] = "\n\n".join(
            [
                "\n".join(sorted(loads)),
                """\
dist_config_settings(
    name = "dist_config_settings",
    visibility = ["//visibility:public"],
)""",
            ] + list(hub_config_settings.values()),
        )

    return files

def _get_aliases(*, aliases, default_version):
    _aliases = {}
    hub_config_settings = {}
    for whl_name, pkg_aliases in aliases.items():
        _alias_target_platforms = {}
        _aliases[whl_name] = []
        for alias in pkg_aliases:
            if not alias.filename and not alias.version:
                _aliases[whl_name].append(whl_alias(repo = alias.repo))
                continue
            elif not alias.filename and alias.version:
                plat_label = "is_python_{}".fromat(alias.version)
                hub_config_settings[plat_label] = render.alias(
                    name = plat_label,
                    actual = repr(str(Label("//python/config_settings:is_python_" + alias.version))),
                    visibility = ["//:__subpackages__"],
                )
                _aliases[whl_name].append(whl_alias(
                    repo = alias.repo,
                    version = alias.version,
                    _config_setting = "//:" + plat_label,
                ))
                if default_version == alias.version:
                    _aliases[whl_name].append(whl_alias(
                        repo = alias.repo,
                        version = alias.version,
                        _config_setting = _DEFAULT_CONFIG_SETTING,
                    ))
                continue

            _target_plats = _alias_target_platforms.setdefault(alias.filename, [])
            if alias.target_platforms:
                _target_plats.extend([(alias.version, p) for p in alias.target_platforms])
            else:
                _target_plats.append((alias.version, None))

        has_any = False
        for filename, target_platforms in _alias_target_platforms.items():
            has_default = False
            is_any = filename.endswith("py3-none-any.whl")
            has_any = has_any or is_any
            if len(_alias_target_platforms) == 1 and is_any and has_any:
                _aliases[whl_name].append(
                    whl_alias(
                        version = "",
                        filename = filename,
                    ),
                )
                continue
            elif has_any and is_any and not has_default:
                _aliases[whl_name].append(
                    whl_alias(
                        version = "",
                        _config_setting = _DEFAULT_CONFIG_SETTING,
                        filename = filename,
                    ),
                )

            _aliases[whl_name].append(
                whl_alias(
                    filename = filename,
                    target_platforms = target_platforms,
                ),
            )
            for version, p in target_platforms:
                for plat_label, config_setting in _get_dist_config_settings(
                    filename = filename,
                    major_minor = version,
                    target_platform = p,
                    is_default_version = version == default_version or (has_any and is_any),
                ).items():
                    if config_setting:
                        hub_config_settings[plat_label] = config_setting

    return hub_config_settings, _aliases

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

def _get_dist_config_settings(filename, major_minor, target_platform, is_default_version):
    target_platforms = [target_platform] if target_platform else []
    parsed = parse_whl_name(filename) if filename.endswith(".whl") else None
    if parsed and not target_platforms and not parsed.platform_tag == "any":
        target_platforms = whl_target_platforms(parsed.platform_tag)
    elif target_platforms:
        target_platforms_ = []
        for plat in target_platforms:
            os, _, cpu = plat.partition("_")
            target_platforms_.append(struct(
                os = os,
                cpu = cpu,
                target_platform = plat,
            ))
        target_platforms = target_platforms_
    elif not target_platforms:
        target_platforms = [None]

    hub_config_settings = {}
    for plat in target_platforms:
        flavor = ""
        flag_values = {
            "//:prefer_any": "auto",
            "//:use_sdist": "auto",
        }
        if not plat and not parsed:
            flag_values = {}
        elif not plat and parsed:
            flag_values = {
                "//:use_sdist": "auto",
            }
            flavor = "any"
        elif not parsed:
            flavor = "sdist"
            flag_values = {
                "//:prefer_any": "auto",
            }  # Reset the flag values
        elif parsed.platform_tag == "any":
            flavor = "any"
            flag_values = {
                "//:use_sdist": "auto",
            }
        elif "musl" in parsed.platform_tag:
            flavor = "musl"
            flag_values["//:whl_linux_libc"] = flavor
        elif "linux" in parsed.platform_tag:
            flavor = "glibc"
            flag_values["//:whl_linux_libc"] = flavor
        elif "universal2" in parsed.platform_tag:
            flavor = "multiarch"
            flag_values["//:whl_osx"] = flavor

        if flavor and plat:
            plat_label = "is_{}_{}".format(plat.target_platform, flavor)
        elif flavor:
            plat_label = "is_{}".format(flavor)
        elif plat:
            plat_label = "is_{}".format(plat.target_platform)
        else:
            plat_label = "is"

        if plat:
            constraint_values = [
                "@platforms//os:" + plat.os,
                "@platforms//cpu:" + plat.cpu,
            ]
        else:
            constraint_values = []

        if is_default_version and (not parsed or plat_label == "is"):
            # NOTE @aignas 2024-04-08: if we have many sdists, the last one
            # will win for the default case that would cover the completely unknown
            # platform, the user could use the new 'experimental_requirements_by_platform'
            # to avoid this case.
            hub_config_settings[""] = ""
        elif is_default_version:
            hub_config_settings[plat_label] = render.config_setting(
                name = plat_label,
                flag_values = flag_values,
                constraint_values = constraint_values,
                visibility = ["//:__subpackages__"],
            )

        plat_label = "is_python_{}_{}".format(
            major_minor,
            plat_label[len("is"):],
        )
        hub_config_settings[plat_label] = render.is_python_config_setting(
            name = plat_label,
            python_version = major_minor,
            flag_values = flag_values,
            constraint_values = constraint_values,
            visibility = ["//:__subpackages__"],
        )

    return hub_config_settings

def whl_alias(*, repo = None, version = None, filename = None, target_platforms = None, _config_setting = None):
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
        _config_setting: TODO

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
    if _config_setting:
        attrs["config_setting"] = _config_setting

    return struct(**attrs)
