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

"pip module extension for use with bzlmod"

load("@bazel_features//:features.bzl", "bazel_features")
load("@pythons_hub//:interpreters.bzl", "DEFAULT_PYTHON_VERSION", "INTERPRETER_LABELS")
load("@rules_python_internal//:rules_python_config.bzl", _rules_python_config = "config")
load(
    "//python/pip_install:pip_repository.bzl",
    "pip_repository_attrs",
    "use_isolated",
    "whl_library",
)
load("//python/pip_install:requirements_parser.bzl", parse_requirements = "parse")
load("//python/private:auth.bzl", "AUTH_ATTRS")
load("//python/private:normalize_name.bzl", "normalize_name")
load("//python/private:parse_whl_name.bzl", "parse_whl_name")
load("//python/private:pypi_index.bzl", "get_simpleapi_sources", "simpleapi_download")
load("//python/private:render_pkg_aliases.bzl", "whl_alias")
load("//python/private:text_util.bzl", "render")
load("//python/private:version_label.bzl", "version_label")
load("//python/private:whl_target_platforms.bzl", "select_whls")
load(":pip_repository.bzl", "pip_repository")

def _parse_version(version):
    major, _, version = version.partition(".")
    minor, _, version = version.partition(".")
    patch, _, version = version.partition(".")
    build, _, version = version.partition(".")

    return struct(
        # use semver vocabulary here
        major = major,
        minor = minor,
        patch = patch,  # this is called `micro` in the Python interpreter versioning scheme
        build = build,
    )

def _major_minor_version(version):
    version = _parse_version(version)
    return "{}.{}".format(version.major, version.minor)

def _whl_mods_impl(mctx):
    """Implementation of the pip.whl_mods tag class.

    This creates the JSON files used to modify the creation of different wheels.
"""
    whl_mods_dict = {}
    for mod in mctx.modules:
        for whl_mod_attr in mod.tags.whl_mods:
            if whl_mod_attr.hub_name not in whl_mods_dict.keys():
                whl_mods_dict[whl_mod_attr.hub_name] = {whl_mod_attr.whl_name: whl_mod_attr}
            elif whl_mod_attr.whl_name in whl_mods_dict[whl_mod_attr.hub_name].keys():
                # We cannot have the same wheel name in the same hub, as we
                # will create the same JSON file name.
                fail("""\
Found same whl_name '{}' in the same hub '{}', please use a different hub_name.""".format(
                    whl_mod_attr.whl_name,
                    whl_mod_attr.hub_name,
                ))
            else:
                whl_mods_dict[whl_mod_attr.hub_name][whl_mod_attr.whl_name] = whl_mod_attr

    for hub_name, whl_maps in whl_mods_dict.items():
        whl_mods = {}

        # create a struct that we can pass to the _whl_mods_repo rule
        # to create the different JSON files.
        for whl_name, mods in whl_maps.items():
            build_content = mods.additive_build_content
            if mods.additive_build_content_file != None and mods.additive_build_content != "":
                fail("""\
You cannot use both the additive_build_content and additive_build_content_file arguments at the same time.
""")
            elif mods.additive_build_content_file != None:
                build_content = mctx.read(mods.additive_build_content_file)

            whl_mods[whl_name] = json.encode(struct(
                additive_build_content = build_content,
                copy_files = mods.copy_files,
                copy_executables = mods.copy_executables,
                data = mods.data,
                data_exclude_glob = mods.data_exclude_glob,
                srcs_exclude_glob = mods.srcs_exclude_glob,
            ))

        _whl_mods_repo(
            name = hub_name,
            whl_mods = whl_mods,
        )

def _parse_requirements(ctx, pip_attr):
    """Get the requirements with platforms that the requirements apply to.

    Args:
        ctx: A context that has .read function that would read contents from a label.
        pip_attr: A struct that should have all of the attributes:
          * experimental_requirements_by_platform (label_keyed_string_dict)
          * requirements_darwin (label)
          * requirements_linux (label)
          * requirements_lock (label)
          * requirements_windows (label)
          * experimental_target_platforms (string_list)
          * extra_pip_args (string_list)

    Returns:
        A tuple where the first element a dict of dicts where the first key is
        the normalized distribution name (with underscores) and the second key
        is the requirement_line, then value and the keys are structs with the
        following attributes:
         * distribution: The non-normalized distribution name.
         * srcs: The Simple API downloadable source list.
         * requirement_line: The original requirement line.
         * target_platforms: The list of target platforms that this package is for.

        The second element is extra_pip_args value to be passed to `whl_library`.
    """
    files_by_platform = {
        file: p.split(",")
        for file, p in pip_attr.experimental_requirements_by_platform.items()
    }.items() or [
        # If the users need a greater span of the platforms, they should consider
        # using the 'experimental_requirements_by_platform' attribute.
        (pip_attr.requirements_windows, pip_attr.experimental_target_platforms or ("windows_x86_64",)),
        (pip_attr.requirements_darwin, pip_attr.experimental_target_platforms or (
            "osx_x86_64",
            "osx_aarch64",
        )),
        (pip_attr.requirements_linux, pip_attr.experimental_target_platforms or (
            "linux_x86_64",
            "linux_aarch64",
            "linux_ppc",
            "linux_s390x",
        )),
        (pip_attr.requirements_lock, None),
    ]

    # NOTE @aignas 2024-04-08: default_platforms will be added to only in the legacy case
    default_platforms = []

    options = None
    requirements = {}
    for file, plats in files_by_platform:
        if not file and plats:
            for p in plats:
                if "host" in p:
                    fail("The host platform is not allowed")

                if "*" in p:
                    fail("Wildcards are not allowed in platform")

                if p in default_platforms:
                    continue

                default_platforms.append(p)
            continue

        contents = ctx.read(file)

        parse_result = parse_requirements(contents)

        # Ensure that we have consistent options across the lock files.
        if options == None:
            options = parse_result.options
        elif "".join(parse_result.options) != "".join(options):
            # buildifier: disable=print
            fail("WARNING: The pip args for each lock file must be the same, will use '{}'".format(options))

        # Replicate a surprising behavior that WORKSPACE builds allowed:
        # Defining a repo with the same name multiple times, but only the last
        # definition is respected.
        # The requirement lines might have duplicate names because lines for extras
        # are returned as just the base package name. e.g., `foo[bar]` results
        # in an entry like `("foo", "foo[bar] == 1.0 ...")`.
        requirements_dict = {
            normalize_name(entry[0]): entry
            # The WORKSPACE pip_parse sorted entries, so mimic that ordering.
            for entry in sorted(parse_result.requirements)
        }.values()

        plats = default_platforms if plats == None else plats
        for p in plats:
            requirements[p] = requirements_dict

    requirements_by_platform = {}
    for target_platform, reqs_ in requirements.items():
        for distribution, requirement_line in reqs_:
            for_whl = requirements_by_platform.setdefault(
                normalize_name(distribution),
                {},
            )

            for_req = for_whl.setdefault(
                requirement_line,
                struct(
                    distribution = distribution,
                    srcs = get_simpleapi_sources(requirement_line),
                    requirement_line = requirement_line,
                    target_platforms = [],
                ),
            )
            for_req.target_platforms.append(target_platform)

    return requirements_by_platform, pip_attr.extra_pip_args + options

def _get_dists(*, whl_name, requirements, want_pys, want_abis, index_urls):
    dists = {}

    if not index_urls:
        return dists

    for key, req in requirements.items():
        sdist = None
        for sha256 in req.srcs.shas:
            # For now if the artifact is marked as yanked we just ignore it.
            #
            # See https://packaging.python.org/en/latest/specifications/simple-repository-api/#adding-yank-support-to-the-simple-api

            maybe_whl = index_urls[whl_name].whls.get(sha256)
            if maybe_whl and not maybe_whl.yanked:
                dists.setdefault(key, []).append(maybe_whl)
                continue

            maybe_sdist = index_urls[whl_name].sdists.get(sha256)
            if maybe_sdist and not maybe_sdist.yanked:
                sdist = maybe_sdist
                continue

            print("WARNING: Could not find a whl or an sdist with sha256={}".format(sha256))  # buildifier: disable=print

        # Filter out whls that are not compatible with the target abis and add the sdist
        dists[key] = select_whls(
            whls = dists[key],
            want_pys = want_pys,
            want_abis = want_abis,
            want_platforms = req.target_platforms,
        )
        if sdist:
            dists[key].append(sdist)

    return dists

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

def _get_registrations(*, dists, reqs, extra_pip_args):
    """Convert the sdists and whls into select statements and whl_library registrations.

    Args:
        dists: The whl and sdist sources. There can be many of them, different for
            different platforms.
        reqs: The requirements for each platform.
        extra_pip_args: Extra pip args that are needed when building wheels from sdist.
    """
    registrations = {}  # repo_name -> args
    found_many = len(reqs) != 1

    dists_ = dists
    for key, dists in dists_.items():
        req = reqs[key]
        for dist in dists:
            whl_library_args = {
                "experimental_target_platforms": req.target_platforms,
                "filename": dist.filename,
                "requirement": req.srcs.requirement,
                "sha256": dist.sha256,
                "urls": [dist.url],
            }

            if not dist.filename.endswith(".whl") and extra_pip_args:
                # TODO @aignas 2024-04-06: If the resultant whl from the sdist is
                # platform specific, we would get into trouble. I think we should
                # ensure that we set `target_compatible_with` for the py_library if
                # that is the case.

                # Add the args back for when we are building a wheel
                whl_library_args["extra_pip_args"] = extra_pip_args

            repo_name = _get_repo_name(dist.filename)
            if repo_name in registrations:
                fail("attempting to register '(name={name}, {args})' whilst '(name={name}, {have}) already exists".format(
                    name = repo_name,
                    args = whl_library_args,
                    have = registrations[repo_name],
                ))
            registrations[repo_name] = whl_library_args

            if found_many and (dist.filename.endswith("-any.whl") or not dist.filename.endswith(".whl")):
                whl_library_args["alias_target_platforms"] = req.target_platforms

    return registrations

def _create_whl_repos(module_ctx, pip_attr, whl_map, whl_overrides, group_map, simpleapi_cache, whl_registrations):
    python_interpreter_target = pip_attr.python_interpreter_target

    # if we do not have the python_interpreter set in the attributes
    # we programmatically find it.
    hub_name = pip_attr.hub_name
    if python_interpreter_target == None and not pip_attr.python_interpreter:
        python_name = "python_{}_host".format(
            version_label(pip_attr.python_version, sep = "_"),
        )
        if python_name not in INTERPRETER_LABELS:
            fail((
                "Unable to find interpreter for pip hub '{hub_name}' for " +
                "python_version={version}: Make sure a corresponding " +
                '`python.toolchain(python_version="{version}")` call exists'
            ).format(
                hub_name = hub_name,
                version = pip_attr.python_version,
            ))
        python_interpreter_target = INTERPRETER_LABELS[python_name]

    pip_name = "{}_{}".format(
        hub_name,
        version_label(pip_attr.python_version),
    )
    major_minor = _major_minor_version(pip_attr.python_version)

    whl_modifications = {}
    if pip_attr.whl_modifications != None:
        for mod, whl_name in pip_attr.whl_modifications.items():
            whl_modifications[whl_name] = mod

    if pip_attr.experimental_requirement_cycles:
        requirement_cycles = {
            name: [normalize_name(whl_name) for whl_name in whls]
            for name, whls in pip_attr.experimental_requirement_cycles.items()
        }

        whl_group_mapping = {
            whl_name: group_name
            for group_name, group_whls in requirement_cycles.items()
            for whl_name in group_whls
        }

        # TODO @aignas 2024-04-05: how do we support different requirement
        # cycles for different abis/oses? For now we will need the users to
        # assume the same groups across all versions/platforms until we start
        # using an alternative cycle resolution strategy.
        group_map[hub_name] = pip_attr.experimental_requirement_cycles
    else:
        whl_group_mapping = {}
        requirement_cycles = {}

    # Create a new wheel library for each of the different whls

    # Parse the requirements file directly in starlark to get the information
    # needed for the whl_libary declarations below.

    requirements_with_target_platforms, extra_pip_args = _parse_requirements(module_ctx, pip_attr)

    index_urls = {}
    if pip_attr.experimental_index_url:
        if pip_attr.download_only:
            fail("Currently unsupported to use `download_only` and `experimental_index_url`")

        index_urls = simpleapi_download(
            module_ctx,
            attr = struct(
                index_url = pip_attr.experimental_index_url,
                extra_index_urls = pip_attr.experimental_extra_index_urls or [],
                index_url_overrides = pip_attr.experimental_index_url_overrides or {},
                sources = list({
                    line.distribution: None
                    for req in requirements_with_target_platforms.values()
                    for line in req.values()
                }),
                envsubst = pip_attr.envsubst,
                # Auth related info
                netrc = pip_attr.netrc,
                auth_patterns = pip_attr.auth_patterns,
            ),
            cache = simpleapi_cache,
            parallel_download = pip_attr.experimental_parallel_download,
        )

    for whl_name, reqs in requirements_with_target_platforms.items():
        # We are not using the "sanitized name" because the user
        # would need to guess what name we modified the whl name
        # to.
        annotation = whl_modifications.get(whl_name)
        whl_name = normalize_name(whl_name)

        group_name = whl_group_mapping.get(whl_name)
        group_deps = requirement_cycles.get(group_name, [])

        # Construct args separately so that the lock file can be smaller and does not include unused
        # attrs.
        whl_library_args = dict(
            repo = pip_name,
            dep_template = "@{}//{{name}}:{{target}}".format(hub_name),
        )
        maybe_args = dict(
            # The following values are safe to omit if they have false like values
            annotation = annotation,
            download_only = pip_attr.download_only,
            enable_implicit_namespace_pkgs = pip_attr.enable_implicit_namespace_pkgs,
            environment = pip_attr.environment,
            envsubst = pip_attr.envsubst,
            extra_pip_args = extra_pip_args,
            group_deps = group_deps,
            group_name = group_name,
            pip_data_exclude = pip_attr.pip_data_exclude,
            python_interpreter = pip_attr.python_interpreter,
            python_interpreter_target = python_interpreter_target,
            whl_patches = {
                p: json.encode(args)
                for p, args in whl_overrides.get(whl_name, {}).items()
            },
        )
        whl_library_args.update({k: v for k, v in maybe_args.items() if v})
        maybe_args_with_default = dict(
            # The following values have defaults next to them
            isolated = (use_isolated(module_ctx, pip_attr), True),
            quiet = (pip_attr.quiet, True),
            timeout = (pip_attr.timeout, 600),
        )
        whl_library_args.update({
            k: v
            for k, (v, default) in maybe_args_with_default.items()
            if v == default
        })

        dists = []
        if index_urls:
            dists = _get_dists(
                whl_name = whl_name,
                requirements = reqs,
                want_pys = [
                    "py3",
                    "cp" + major_minor.replace(".", ""),
                ],
                want_abis = [
                    "none",
                    "abi3",
                    "cp" + major_minor.replace(".", ""),
                    # Older python versions have wheels for the `*m` ABI.
                    "cp" + major_minor.replace(".", "") + "m",
                ],
                index_urls = index_urls,
            )

        if dists:
            # pip is not used to download wheels and the python `whl_library` helpers are only extracting things
            whl_library_args.pop("extra_pip_args", None)

            # This is no-op because pip is not used to download the wheel.
            whl_library_args.pop("download_only", None)

            # No need for this because we use dep_template
            whl_library_args.pop("repo")

            if pip_attr.netrc:
                whl_library_args["netrc"] = pip_attr.netrc
            if pip_attr.auth_patterns:
                whl_library_args["auth_patterns"] = pip_attr.auth_patterns

            registrations = _get_registrations(
                dists = dists,
                reqs = reqs,
                extra_pip_args = extra_pip_args,
            )
            for suffix, args in registrations.items():
                repo_name = "{}_{}".format(hub_name, suffix)
                whl_map.setdefault(whl_name, []).append(
                    whl_alias(
                        repo = hub_name,
                        version = major_minor,
                        filename = args["filename"],
                        target_platforms = args.pop("alias_target_platforms", None),
                    ),
                )

                args["experimental_target_platforms"] = [
                    "cp{}_{}".format(major_minor.replace(".", ""), p)
                    for p in (args["experimental_target_platforms"] or [])
                ]
                all_whl_library_args = dict(sorted(whl_library_args.items() + args.items()))
                if repo_name in whl_registrations:
                    _have = dict(sorted(whl_registrations[repo_name].items()))
                    _args = dict(sorted(all_whl_library_args.items()))
                    _have_str = render.dict(_have)
                    _args_str = render.dict(_args)

                    # This field is going to be extended later
                    _have.pop("experimental_target_platforms")
                    _args.pop("experimental_target_platforms")

                    # We will just use the first interpreter we find. We don't
                    # choose the default because it might change with the
                    # --@rules_python//python/config_settings:python_version=3.Y
                    # setting and using the first one in the hub list at least gives
                    # us determinism and a stable lock file.
                    _have.pop("python_interpreter_target")
                    _args.pop("python_interpreter_target")
                    _have_str_cmp = render.dict(_have)
                    _args_str_cmp = render.dict(_args)

                    if _have_str_cmp != _args_str_cmp:
                        fail("attempting to register {name} whilst a different registration with different args already exists:\nhave: {have}\n new: {args}".format(
                            name = repo_name,
                            args = _args_str,
                            have = _have_str,
                        ))
                    else:
                        whl_registrations[repo_name]["experimental_target_platforms"].extend(args["experimental_target_platforms"])
                else:
                    whl_registrations[repo_name] = all_whl_library_args

            continue
        else:
            os_name = module_ctx.os.name.lower()
            if os_name.startswith("win"):
                host_platform_os = "windows"
            elif os_name.startswith("mac"):
                host_platform_os = "osx"
            elif os_name.startswith("linux"):
                host_platform_os = "linux"
            else:
                fail("unsupported host platform: {}".format(os_name))

            requirement_line = [
                req.requirement_line
                for req in reqs.values()
                if len([p for p in req.target_platforms if p.startswith(host_platform_os)]) > 0
            ][0]

            if index_urls:
                print("WARNING: falling back to pip for installing the right file for {}".format(requirement_line))  # buildifier: disable=print

            repo_name = "{}_{}".format(pip_name, whl_name)
            whl_library_args["requirement"] = requirement_line
            whl_library(
                name = repo_name,
                **dict(sorted(whl_library_args.items()))
            )
            whl_map.setdefault(whl_name, []).append(
                whl_alias(
                    repo = repo_name,
                    version = major_minor,
                ),
            )

def _pip_impl(module_ctx):
    """Implementation of a class tag that creates the pip hub and corresponding pip spoke whl repositories.

    This implementation iterates through all of the `pip.parse` calls and creates
    different pip hub repositories based on the "hub_name".  Each of the
    pip calls create spoke repos that uses a specific Python interpreter.

    In a MODULES.bazel file we have:

    pip.parse(
        hub_name = "pip",
        python_version = 3.9,
        requirements_lock = "//:requirements_lock_3_9.txt",
        requirements_windows = "//:requirements_windows_3_9.txt",
    )
    pip.parse(
        hub_name = "pip",
        python_version = 3.10,
        requirements_lock = "//:requirements_lock_3_10.txt",
        requirements_windows = "//:requirements_windows_3_10.txt",
    )

    For instance, we have a hub with the name of "pip".
    A repository named the following is created. It is actually called last when
    all of the pip spokes are collected.

    - @@rules_python~override~pip~pip

    As shown in the example code above we have the following.
    Two different pip.parse statements exist in MODULE.bazel provide the hub_name "pip".
    These definitions create two different pip spoke repositories that are
    related to the hub "pip".
    One spoke uses Python 3.9 and the other uses Python 3.10. This code automatically
    determines the Python version and the interpreter.
    Both of these pip spokes contain requirements files that includes websocket
    and its dependencies.

    We also need repositories for the wheels that the different pip spokes contain.
    For each Python version a different wheel repository is created. In our example
    each pip spoke had a requirements file that contained websockets. We
    then create two different wheel repositories that are named the following.

    - @@rules_python~override~pip~pip_39_websockets
    - @@rules_python~override~pip~pip_310_websockets

    And if the wheel has any other dependencies subsequent wheels are created in the same fashion.

    The hub repository has aliases for `pkg`, `data`, etc, which have a select that resolves to
    a spoke repository depending on the Python version.

    Also we may have more than one hub as defined in a MODULES.bazel file.  So we could have multiple
    hubs pointing to various different pip spokes.

    Some other business rules notes. A hub can only have one spoke per Python version.  We cannot
    have a hub named "pip" that has two spokes that use the Python 3.9 interpreter.  Second
    we cannot have the same hub name used in sub-modules.  The hub name has to be globally
    unique.

    This implementation also handles the creation of whl_modification JSON files that are used
    during the creation of wheel libraries. These JSON files used via the annotations argument
    when calling wheel_installer.py.

    Args:
        module_ctx: module contents
    """

    # Build all of the wheel modifications if the tag class is called.
    _whl_mods_impl(module_ctx)

    _overriden_whl_set = {}
    whl_overrides = {}

    for module in module_ctx.modules:
        for attr in module.tags.override:
            if not module.is_root:
                fail("overrides are only supported in root modules")

            if not attr.file.endswith(".whl"):
                fail("Only whl overrides are supported at this time")

            whl_name = normalize_name(parse_whl_name(attr.file).distribution)

            if attr.file in _overriden_whl_set:
                fail("Duplicate module overrides for '{}'".format(attr.file))
            _overriden_whl_set[attr.file] = None

            for patch in attr.patches:
                if whl_name not in whl_overrides:
                    whl_overrides[whl_name] = {}

                if patch not in whl_overrides[whl_name]:
                    whl_overrides[whl_name][patch] = struct(
                        patch_strip = attr.patch_strip,
                        whls = [],
                    )

                whl_overrides[whl_name][patch].whls.append(attr.file)

    # Used to track all the different pip hubs and the spoke pip Python
    # versions.
    pip_hub_map = {}

    # Keeps track of all the hub's whl repos across the different versions.
    # dict[hub, dict[whl, dict[version, str pip]]]
    # Where hub, whl, and pip are the repo names
    hub_whl_map = {}
    hub_group_map = {}

    simpleapi_cache = {}
    whl_registrations = {}

    # TODO @aignas 2024-04-20: allow only a single declaration of the repo if
    # we use the experimental index URL

    for mod in module_ctx.modules:
        for pip_attr in mod.tags.parse:
            hub_name = pip_attr.hub_name
            if hub_name not in pip_hub_map:
                pip_hub_map[pip_attr.hub_name] = struct(
                    module_name = mod.name,
                    python_versions = [pip_attr.python_version],
                    index_url = pip_attr.experimental_index_url,
                )
            elif pip_hub_map[hub_name].module_name != mod.name:
                # We cannot have two hubs with the same name in different
                # modules.
                fail((
                    "Duplicate cross-module pip hub named '{hub}': pip hub " +
                    "names must be unique across modules. First defined " +
                    "by module '{first_module}', second attempted by " +
                    "module '{second_module}'"
                ).format(
                    hub = hub_name,
                    first_module = pip_hub_map[hub_name].module_name,
                    second_module = mod.name,
                ))

            elif pip_attr.python_version and pip_attr.python_version in pip_hub_map[hub_name].python_versions:
                fail((
                    "Duplicate pip python version '{version}' for hub " +
                    "'{hub}' in module '{module}': the Python versions " +
                    "used for a hub must be unique"
                ).format(
                    hub = hub_name,
                    module = mod.name,
                    version = pip_attr.python_version,
                ))
            else:
                pip_hub_map[pip_attr.hub_name].python_versions.append(pip_attr.python_version)

            _create_whl_repos(
                module_ctx,
                pip_attr,
                hub_whl_map.setdefault(hub_name, {}),
                whl_overrides,
                hub_group_map,
                simpleapi_cache,
                whl_registrations,
            )

    for repo, args in whl_registrations.items():
        whl_library(
            name = repo,
            # We sort so that the lock-file remains the same no matter
            # the order of how the args are manipulated in the code
            # going before.
            **dict(sorted(args.items()))
        )

    for hub_name, whl_map in hub_whl_map.items():
        pip_repository(
            name = hub_name,
            repo_name = hub_name,
            whl_map = {
                key: [json.encode(v) for v in value]
                for key, value in whl_map.items()
            },
            default_version = _major_minor_version(DEFAULT_PYTHON_VERSION),
            groups = hub_group_map.get(hub_name),
        )

def _pip_parse_ext_attrs():
    attrs = dict({
        "experimental_extra_index_urls": attr.string_list(
            doc = """\
The extra index URLs to use for downloading wheels using bazel downloader.
Each value is going to be subject to `envsubst` substitutions if necessary.

The indexes must support Simple API as described here:
https://packaging.python.org/en/latest/specifications/simple-repository-api/

This is equivalent to `--extra-index-urls` `pip` option.
""",
            default = [],
        ),
        "experimental_index_url": attr.string(
            doc = """\
The index URL to use for downloading wheels using bazel downloader. This value is going
to be subject to `envsubst` substitutions if necessary.

The indexes must support Simple API as described here:
https://packaging.python.org/en/latest/specifications/simple-repository-api/

In the future this could be defaulted to `https://pypi.org` when this feature becomes
stable.

This is equivalent to `--index-url` `pip` option.
""",
        ),
        "experimental_index_url_overrides": attr.string_dict(
            doc = """\
The index URL overrides for each package to use for downloading wheels using
bazel downloader. This value is going to be subject to `envsubst` substitutions
if necessary.

The key is the package name (will be normalized before usage) and the value is the
index URL.

This design pattern has been chosen in order to be fully deterministic about which
packages come from which source. We want to avoid issues similar to what happened in
https://pytorch.org/blog/compromised-nightly-dependency/.

The indexes must support Simple API as described here:
https://packaging.python.org/en/latest/specifications/simple-repository-api/
""",
        ),
        "experimental_parallel_download": attr.bool(
            doc = """\
This feature is available for bazel 7.1 and above, which allows us to fetch the PyPI
simple API indexes in parallel. This is currently set to False by default because
there are some known issues with the API.
""",
            default = False,
        ),
        "experimental_requirements_by_platform": attr.label_keyed_string_dict(
            doc = """\
The requirements files and the comma delimited list of target platforms.
""",
        ),
        "hub_name": attr.string(
            mandatory = True,
            doc = """
The name of the repo pip dependencies will be accessible from.

This name must be unique between modules; unless your module is guaranteed to
always be the root module, it's highly recommended to include your module name
in the hub name. Repo mapping, `use_repo(..., pip="my_modules_pip_deps")`, can
be used for shorter local names within your module.

Within a module, the same `hub_name` can be specified to group different Python
versions of pip dependencies under one repository name. This allows using a
Python version-agnostic name when referring to pip dependencies; the
correct version will be automatically selected.

Typically, a module will only have a single hub of pip dependencies, but this
is not required. Each hub is a separate resolution of pip dependencies. This
means if different programs need different versions of some library, separate
hubs can be created, and each program can use its respective hub's targets.
Targets from different hubs should not be used together.
""",
        ),
        "python_version": attr.string(
            mandatory = True,
            doc = """
The Python version the dependencies are targetting, in Major.Minor format
(e.g., "3.11"). Patch level granularity (e.g. "3.11.1") is not supported.
If not specified, then the default Python version (as set by the root module or
rules_python) will be used.

If an interpreter isn't explicitly provided (using `python_interpreter` or
`python_interpreter_target`), then the version specified here must have
a corresponding `python.toolchain()` configured.
""",
        ),
        "whl_modifications": attr.label_keyed_string_dict(
            mandatory = False,
            doc = """\
A dict of labels to wheel names that is typically generated by the whl_modifications.
The labels are JSON config files describing the modifications.
""",
        ),
    }, **pip_repository_attrs)
    attrs.update(AUTH_ATTRS)

    # Like the pip_repository rule, we end up setting this manually so
    # don't allow users to override it.
    attrs.pop("repo_prefix")

    return attrs

def _whl_mod_attrs():
    attrs = {
        "additive_build_content": attr.string(
            doc = "(str, optional): Raw text to add to the generated `BUILD` file of a package.",
        ),
        "additive_build_content_file": attr.label(
            doc = """\
(label, optional): path to a BUILD file to add to the generated
`BUILD` file of a package. You cannot use both additive_build_content and additive_build_content_file
arguments at the same time.""",
        ),
        "copy_executables": attr.string_dict(
            doc = """\
(dict, optional): A mapping of `src` and `out` files for
[@bazel_skylib//rules:copy_file.bzl][cf]. Targets generated here will also be flagged as
executable.""",
        ),
        "copy_files": attr.string_dict(
            doc = """\
(dict, optional): A mapping of `src` and `out` files for
[@bazel_skylib//rules:copy_file.bzl][cf]""",
        ),
        "data": attr.string_list(
            doc = """\
(list, optional): A list of labels to add as `data` dependencies to
the generated `py_library` target.""",
        ),
        "data_exclude_glob": attr.string_list(
            doc = """\
(list, optional): A list of exclude glob patterns to add as `data` to
the generated `py_library` target.""",
        ),
        "hub_name": attr.string(
            doc = """\
Name of the whl modification, hub we use this name to set the modifications for
pip.parse. If you have different pip hubs you can use a different name,
otherwise it is best practice to just use one.

You cannot have the same `hub_name` in different modules.  You can reuse the same
name in the same module for different wheels that you put in the same hub, but you
cannot have a child module that uses the same `hub_name`.
""",
            mandatory = True,
        ),
        "srcs_exclude_glob": attr.string_list(
            doc = """\
(list, optional): A list of labels to add as `srcs` to the generated
`py_library` target.""",
        ),
        "whl_name": attr.string(
            doc = "The whl name that the modifications are used for.",
            mandatory = True,
        ),
    }
    return attrs

# NOTE: the naming of 'override' is taken from the bzlmod native
# 'archive_override', 'git_override' bzlmod functions.
_override_tag = tag_class(
    attrs = {
        "file": attr.string(
            doc = """\
The Python distribution file name which needs to be patched. This will be
applied to all repositories that setup this distribution via the pip.parse tag
class.""",
            mandatory = True,
        ),
        "patch_strip": attr.int(
            default = 0,
            doc = """\
The number of leading path segments to be stripped from the file name in the
patches.""",
        ),
        "patches": attr.label_list(
            doc = """\
A list of patches to apply to the repository *after* 'whl_library' is extracted
and BUILD.bazel file is generated.""",
            mandatory = True,
        ),
    },
    doc = """\
Apply any overrides (e.g. patches) to a given Python distribution defined by
other tags in this extension.""",
)

def _extension_extra_args():
    args = {}

    if bazel_features.external_deps.module_extension_has_os_arch_dependent:
        args = args | {
            "arch_dependent": not _rules_python_config.enable_bzlmod_lockfile,
            "os_dependent": not _rules_python_config.enable_bzlmod_lockfile,
        }

    return args

pip = module_extension(
    doc = """\
This extension is used to make dependencies from pip available.

pip.parse:
To use, call `pip.parse()` and specify `hub_name` and your requirements file.
Dependencies will be downloaded and made available in a repo named after the
`hub_name` argument.

Each `pip.parse()` call configures a particular Python version. Multiple calls
can be made to configure different Python versions, and will be grouped by
the `hub_name` argument. This allows the same logical name, e.g. `@pip//numpy`
to automatically resolve to different, Python version-specific, libraries.

pip.whl_mods:
This tag class is used to help create JSON files to describe modifications to
the BUILD files for wheels.
""",
    implementation = _pip_impl,
    tag_classes = {
        "override": _override_tag,
        "parse": tag_class(
            attrs = _pip_parse_ext_attrs(),
            doc = """\
This tag class is used to create a pip hub and all of the spokes that are part of that hub.
This tag class reuses most of the pip attributes that are found in
@rules_python//python/pip_install:pip_repository.bzl.
The exception is it does not use the arg 'repo_prefix'.  We set the repository
prefix for the user and the alias arg is always True in bzlmod.
""",
        ),
        "whl_mods": tag_class(
            attrs = _whl_mod_attrs(),
            doc = """\
This tag class is used to create JSON file that are used when calling wheel_builder.py.  These
JSON files contain instructions on how to modify a wheel's project.  Each of the attributes
create different modifications based on the type of attribute. Previously to bzlmod these
JSON files where referred to as annotations, and were renamed to whl_modifications in this
extension.
""",
        ),
    },
    **_extension_extra_args()
)

def _whl_mods_repo_impl(rctx):
    rctx.file("BUILD.bazel", "")
    for whl_name, mods in rctx.attr.whl_mods.items():
        rctx.file("{}.json".format(whl_name), mods)

_whl_mods_repo = repository_rule(
    doc = """\
This rule creates json files based on the whl_mods attribute.
""",
    implementation = _whl_mods_repo_impl,
    attrs = {
        "whl_mods": attr.string_dict(
            mandatory = True,
            doc = "JSON endcoded string that is provided to wheel_builder.py",
        ),
    },
)
