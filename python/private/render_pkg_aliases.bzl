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
    {config_settings}

As matched by the `@{rules_python}//python/config_settings:is_python_<version>`
configuration settings.

To determine the current configuration's Python version, run:
    `bazel config <config id>` (shown further below)
and look for
    {rules_python}//python/config_settings:python_version

If the value is missing, then the "default" Python version is being used,
which has a "null" version value and will not match version constraints.
"""

def _render_whl_library_alias(
        *,
        name,
        default_config_setting,
        aliases,
        target_name,
        **kwargs):
    """Render an alias for common targets."""
    if len(aliases) == 1 and not aliases[0].version:
        alias = aliases[0]
        return render.alias(
            name = name,
            actual = repr("@{repo}//:{name}".format(
                repo = alias.repo,
                name = target_name,
            )),
            **kwargs
        )

    # Create the alias repositories which contains different select
    # statements  These select statements point to the different pip
    # whls that are based on a specific version of Python.
    selects = {}
    no_match_error = "_NO_MATCH_ERROR"
    for alias in sorted(aliases, key = lambda x: x.version):
        # TODO @aignas 2024-04-05: decouple this so that we could point inside the
        # hub repo
        actual = "@{repo}//:{name}".format(repo = alias.repo, name = target_name)
        selects.setdefault(actual, []).append(alias.config_setting)
        if alias.config_setting == default_config_setting:
            no_match_error = None

    return render.alias(
        name = name,
        actual = render.select(
            {tuple(sorted(v, key = lambda x: ("is_python" not in x, x))): k for k, v in sorted(selects.items())},
            no_match_error = no_match_error,
            key_repr = lambda x: repr(x[0]) if len(x) == 1 else render.tuple(x),
            name = "selects.with_or",
        ),
        **kwargs
    )

def _render_common_aliases(*, name, aliases, default_config_setting = None, group_name = None):
    lines = [
        """load("@bazel_skylib//lib:selects.bzl", "selects")""",
        """package(default_visibility = ["//visibility:public"])""",
    ]

    config_settings = None
    if aliases:
        config_settings = sorted([v.config_setting for v in aliases if v.config_setting])

    if not config_settings or default_config_setting in config_settings:
        pass
    else:
        error_msg = NO_MATCH_ERROR_MESSAGE_TEMPLATE.format(
            config_settings = ", ".join(config_settings),
            rules_python = "rules_python",
        )

        lines.append("_NO_MATCH_ERROR = \"\"\"\\\n{error_msg}\"\"\"".format(
            error_msg = error_msg,
        ))

        # This is to simplify the code in _render_whl_library_alias and to ensure
        # that we don't pass a 'default_config_setting' that is not in 'config_settings'.
        default_config_setting = None

    lines.append(
        render.alias(
            name = name,
            actual = repr(":pkg"),
        ),
    )
    lines.extend(
        [
            _render_whl_library_alias(
                name = name,
                default_config_setting = default_config_setting,
                aliases = aliases,
                target_name = target_name,
                visibility = ["//_groups:__subpackages__"] if name.startswith("_") else None,
            )
            for target_name, name in {
                PY_LIBRARY_PUBLIC_LABEL: PY_LIBRARY_IMPL_LABEL if group_name else PY_LIBRARY_PUBLIC_LABEL,
                WHEEL_FILE_PUBLIC_LABEL: WHEEL_FILE_IMPL_LABEL if group_name else WHEEL_FILE_PUBLIC_LABEL,
                DATA_LABEL: DATA_LABEL,
                DIST_INFO_LABEL: DIST_INFO_LABEL,
            }.items()
        ],
    )
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

def render_pkg_aliases(*, aliases, default_config_setting = None, requirement_cycles = None):
    """Create alias declarations for each PyPI package.

    The aliases should be appended to the pip_repository BUILD.bazel file. These aliases
    allow users to use requirement() without needed a corresponding `use_repo()` for each dep
    when using bzlmod.

    Args:
        aliases: dict, the keys are normalized distribution names and values are the
            whl_alias instances.
        default_config_setting: the default version to be used for the aliases.
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

    _aliases = {}
    hub_config_settings = {}
    for whl_name, pkg_aliases in aliases.items():
        has_default = False
        _aliases[whl_name] = []
        for alias in pkg_aliases:
            if not alias.filename:
                _aliases[whl_name].append(alias)
                continue

            config_settings = []
            for plat_label, config_setting in _get_whl_config_settings(
                filename = alias.filename,
                major_minor = alias.version,
                target_platforms = [
                    struct(**p) for p in alias.target_platforms
                ],
                is_default_version = alias.is_default_version,
            ).items():
                if plat_label == "default":
                    if not has_default:
                        config_settings.append("//conditions:" + plat_label)
                        has_default = True
                else:
                    config_settings.append("//:" + plat_label)
                if config_setting:
                    hub_config_settings[plat_label] = config_setting

            print(config_settings)
            for config_setting in config_settings:
                _aliases[whl_name].append(
                    whl_alias(
                        repo = alias.repo,
                        config_setting = config_setting,
                    ),
                )

    files = {
        "{}/BUILD.bazel".format(normalize_name(name)): _render_common_aliases(
            name = normalize_name(name),
            aliases = pkg_aliases,
            default_config_setting = default_config_setting,
            group_name = whl_group_mapping.get(normalize_name(name)),
        ).strip()
        for name, pkg_aliases in aliases.items()
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
            ] + list(hub_config_settings.values())
        )

    return files

def whl_alias(*, repo, version = None, config_setting = None, extra_targets = None, filename = None, target_platforms = None, is_default_version = None):
    """The bzl_packages value used by by the render_pkg_aliases function.

    This contains the minimum amount of information required to generate correct
    aliases in a hub repository.

    Args:
        repo: str, the repo of where to find the things to be aliased.
        version: optional(str), the version of the python toolchain that this
            whl alias is for. If not set, then non-version aware aliases will be
            constructed. This is mainly used for better error messages when there
            is no match found during a select.
        config_setting: optional(Label or str), the config setting that we should use. Defaults
            to "@rules_python//python/config_settings:is_python_{version}".
        extra_targets: optional(list[str]), the extra targets that we need to create
            aliases for.
        filename: The filename of the dist that the aliases need to be created for.
        target_platforms: The target platforms that the dist is targetting.
        is_default_version: Whether this is a default python version.

    Returns:
        a struct with the validated and parsed values.
    """
    if not repo:
        fail("'repo' must be specified")

    if version:
        config_setting = config_setting or Label("//python/config_settings:is_python_" + version)
        config_setting = str(config_setting)

    return struct(
        repo = repo,
        version = version,
        config_setting = config_setting,
        extra_targets = extra_targets or [],
        filename = filename,
        target_platforms = target_platforms,
        is_default_version = is_default_version,
    )

def _get_whl_config_settings(filename, major_minor, target_platforms, is_default_version):
    parsed = parse_whl_name(filename) if filename.endswith(".whl") else None

    print(target_platforms)

    hub_config_settings = {}
    if parsed and not target_platforms:
        plat_label = "is_any"
        flag_values = {
            "//:use_sdist": "auto",
        }
        if is_default_version:
            hub_config_settings[plat_label] = render.config_setting(
                name = plat_label,
                flag_values = flag_values,
                visibility = ["//:__subpackages__"],
            )

        plat_label = "is_python_" + major_minor + plat_label[len("is"):]
        hub_config_settings[plat_label] = render.is_python_config_setting(
            name = plat_label,
            python_version = major_minor,
            flag_values = flag_values,
            visibility = ["//:__subpackages__"],
        )

        return hub_config_settings
    elif not parsed and not target_platforms:
        is_python = "is_python_{}".format(major_minor)
        hub_config_settings[is_python] = render.alias(
            name = is_python,
            actual = repr(str(Label("//python/config_settings:is_python_" + major_minor))),
            visibility = ["//:__subpackages__"],
        )
        if is_default_version:
            hub_config_settings["default"] = ""

        return hub_config_settings

    for plat in target_platforms:
        flavor = ""
        flag_values = {
            "//:use_sdist": "auto",
        }
        if not parsed:
            flavor = "sdist"
            flag_values = {}  # Reset the flag values
        elif "musl" in parsed.platform_tag:
            flavor = "musl"
            flag_values["//:whl_linux_libc"] = flavor
        elif "linux" in parsed.platform_tag:
            flavor = "glibc"
            flag_values["//:whl_linux_libc"] = flavor
        elif "universal2" in parsed.platform_tag:
            flavor = "multiarch"
            flag_values["//:whl_osx"] = flavor

        if not plat:
            plat_label = "is_any"
        elif flavor:
            plat_label = "is_{}_{}".format(plat.target_platform, flavor)
        else:
            plat_label = "is_{}".format(plat.target_platform)

        constraint_values = [
            "@platforms//os:" + plat.os,
            "@platforms//cpu:" + plat.cpu,
        ] if plat else []

        if is_default_version and not parsed:
            # NOTE @aignas 2024-04-08: if we have many sdists, the last one
            # will win for the default case that would cover the completely unknown
            # platform, the user could use the new 'experimental_requirements_by_platform'
            # to avoid this case.
            hub_config_settings["default"] = ""

        if is_default_version:
            hub_config_settings[plat_label] = render.config_setting(
                name = plat_label,
                flag_values = flag_values,
                constraint_values = constraint_values,
                visibility = ["//:__subpackages__"],
            )

        plat_label = "is_python_" + major_minor + plat_label[len("is"):]
        hub_config_settings[plat_label] = render.is_python_config_setting(
            name = plat_label,
            python_version = major_minor,
            flag_values = flag_values,
            constraint_values = constraint_values,
            visibility = ["//:__subpackages__"],
        )

    return hub_config_settings
