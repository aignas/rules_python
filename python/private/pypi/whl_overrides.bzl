"""Parse the `pip.override` tags into the patches for each hub."""

load("//python/private:normalize_name.bzl", "normalize_name")
load(":parse_whl_name.bzl", "parse_whl_name")
load(":pep508_requirement.bzl", "requirement")

def parse_whl_overrides(modules, *, _fail = fail):
    """Collect the `pip.override` tags of the root module.

    Args:
        modules: {type}`list[module]` the `module_ctx.modules`.
        _fail: {type}`callable` the function to call on errors, for tests.

    Returns:
        {type}`struct` with `files` - the overrides by the wheel file name, and
        `packages` - the overrides by the package name, keyed by the hub name
        (an empty string for all hubs).
    """
    files = {}
    packages = {}
    settings = {}
    build_modes = {}
    replacements = {}
    sdist_builders = {}
    seen_files = {}
    seen_packages = {}
    for module in modules:
        for attr in module.tags.override:
            if not module.is_root:
                # Overrides are only supported in root modules. Silently
                # ignore the override:
                continue

            if bool(attr.file) == bool(attr.package):
                _fail("pip.override needs exactly one of 'file' or 'package', got: file = '{}', package = '{}'".format(attr.file, attr.package))
                continue

            if attr.file:
                if attr.ignore_dependencies or attr.extra_dependencies or attr.tags or attr.build_mode:
                    _fail("pip.override(file = '{}') only supports 'patches', use 'package' for the other settings".format(attr.file))
                    continue

                if not attr.patches:
                    _fail("pip.override(file = '{}') needs 'patches'".format(attr.file))
                    continue

                if attr.hub_name:
                    _fail("pip.override(file = '{}') applies to all hubs and does not support 'hub_name'".format(attr.file))
                    continue

                if not attr.file.endswith(".whl"):
                    _fail("Only whl overrides are supported at this time")
                    continue

                whl_name = normalize_name(parse_whl_name(attr.file).distribution)

                if attr.file in seen_files:
                    _fail("Duplicate module overrides for '{}'".format(attr.file))
                    continue
                seen_files[attr.file] = None

                for patch in attr.patches:
                    patches = files.setdefault(whl_name, {})
                    if patch not in patches:
                        patches[patch] = struct(
                            patch_strip = attr.patch_strip,
                            whls = [],
                        )

                    patches[patch].whls.append(attr.file)
                continue

            name, sep, version = attr.package.partition("@")
            if (sep and not version) or not name or [c for c in "=<>!~ ;[".elems() if c in attr.package] or (name == "*" and version):
                _fail("pip.override(package = '{}') needs to be a package name or '<name>@<version>'".format(attr.package))
                continue
            whl_name = normalize_name(name)
            key = (attr.hub_name, whl_name, version)
            if key in seen_packages:
                _fail("Duplicate module overrides for package '{}'{}".format(
                    attr.package,
                    " in hub '{}'".format(attr.hub_name) if attr.hub_name else "",
                ))
                continue
            seen_packages[key] = None

            if attr.replace_with:
                if version or name == "*" or attr.patches or attr.build_mode or attr.ignore_dependencies:
                    _fail("pip.override(package = '{}', replace_with = ...) needs a single package without a version and cannot have 'patches', 'build_mode' or 'ignore_dependencies'".format(attr.package))
                    continue
                replacements.setdefault(attr.hub_name, {})[whl_name] = struct(
                    replace_with = str(attr.replace_with),
                    replace_with_whl = str(attr.replace_with_whl) if attr.replace_with_whl else None,
                    replace_with_dist_info = str(attr.replace_with_dist_info) if attr.replace_with_dist_info else None,
                )
            elif attr.replace_with_whl or attr.replace_with_dist_info:
                _fail("pip.override(package = '{}') needs 'replace_with' to set 'replace_with_whl' or 'replace_with_dist_info'".format(attr.package))
                continue

            if attr.experimental_sdist_builder or attr.experimental_sdist_builder_symbol:
                if not (attr.experimental_sdist_builder and attr.experimental_sdist_builder_symbol) or version or attr.replace_with:
                    _fail("pip.override(package = '{}') needs both 'experimental_sdist_builder' and 'experimental_sdist_builder_symbol', no version and no 'replace_with'".format(attr.package))
                    continue
                sdist_builders.setdefault(attr.hub_name, {})[whl_name] = struct(
                    bzl = str(attr.experimental_sdist_builder),
                    symbol = attr.experimental_sdist_builder_symbol,
                )

            if name == "*" and (attr.patches or attr.ignore_dependencies or attr.extra_dependencies or attr.tags):
                _fail("pip.override(package = '*') only supports 'build_mode' and the sdist builder")
                continue

            if attr.build_mode:
                if version:
                    _fail("pip.override(package = '{}') cannot set 'build_mode' for a single version".format(attr.package))
                    continue
                build_modes.setdefault(attr.hub_name, {})[whl_name] = attr.build_mode

            if attr.ignore_dependencies or attr.extra_dependencies or attr.tags:
                if version:
                    _fail("pip.override(package = '{}') cannot set 'ignore_dependencies', 'extra_dependencies' or 'tags' for a single version".format(attr.package))
                    continue

                bad = [
                    dep
                    for dep in attr.ignore_dependencies
                    if requirement(dep).name_ != normalize_name(dep) or normalize_name(dep) == whl_name
                ]
                if bad:
                    _fail("pip.override(package = '{}').ignore_dependencies needs the names of other packages, got: {}".format(attr.package, bad))
                    continue

                settings.setdefault(attr.hub_name, {})[whl_name] = struct(
                    ignore_dependencies = attr.ignore_dependencies,
                    extra_dependencies = attr.extra_dependencies,
                    extra_tags = attr.tags,
                )
            elif not attr.patches and not attr.build_mode and not attr.replace_with and not attr.experimental_sdist_builder:
                _fail("pip.override(package = '{}') does not set anything".format(attr.package))
                continue

            if name == "*":
                continue

            patches = packages.setdefault(attr.hub_name, {}).setdefault(whl_name, {})
            for patch in attr.patches:
                if patch in patches and patches[patch].patch_strip != attr.patch_strip:
                    _fail("The patch '{}' for package '{}' is used with different 'patch_strip' values, use a copy of the patch file".format(patch, attr.package))
                    continue
                patches.setdefault(patch, struct(
                    patch_strip = attr.patch_strip,
                    versions = [],
                )).versions.append(version or "*")

    return struct(
        files = files,
        packages = packages,
        settings = settings,
        build_modes = build_modes,
        replacements = replacements,
        sdist_builders = sdist_builders,
    )

def sdist_builder_for_hub(overrides, hub_name):
    """Get the sdist builders of the packages in a hub.

    A package uses the first of: the builder of the package for the hub, of
    `*` for the hub, of the package for all hubs and of `*` for all hubs.

    Args:
        overrides: {type}`struct` the result of {func}`parse_whl_overrides`.
        hub_name: {type}`str` the name of the hub.

    Returns:
        {type}`callable` that returns the builder (a struct with the `bzl` label
        and the `symbol`) of a normalized package name or `None`.
    """
    hub = overrides.sdist_builders.get(hub_name, {})
    all_hubs = overrides.sdist_builders.get("", {})
    return lambda name: hub.get(name) or hub.get("*") or all_hubs.get(name) or all_hubs.get("*")

def replacements_for_hub(overrides, hub_name):
    """Get the packages of a hub that are replaced by user targets.

    Args:
        overrides: {type}`struct` the result of {func}`parse_whl_overrides`.
        hub_name: {type}`str` the name of the hub.

    Returns:
        {type}`dict[str, struct]` the replacement of each package name.
    """
    return overrides.replacements.get("", {}) | overrides.replacements.get(hub_name, {})

def build_mode_for_hub(overrides, hub_name):
    """Get the build modes of the packages in a hub.

    A package uses the first of: the build mode of the package for the hub, of
    `*` for the hub, of the package for all hubs and of `*` for all hubs.

    Args:
        overrides: {type}`struct` the result of {func}`parse_whl_overrides`.
        hub_name: {type}`str` the name of the hub.

    Returns:
        {type}`callable` that returns the build mode of a normalized package
        name or an empty string.
    """
    hub = overrides.build_modes.get(hub_name, {})
    all_hubs = overrides.build_modes.get("", {})
    return lambda name: hub.get(name) or hub.get("*") or all_hubs.get(name) or all_hubs.get("*") or ""

def package_settings_for_hub(overrides, hub_name):
    """Get the settings of the packages in a hub.

    The settings for the hub are added to the settings for all hubs.

    Args:
        overrides: {type}`struct` the result of {func}`parse_whl_overrides`.
        hub_name: {type}`str` the name of the hub.

    Returns:
        {type}`dict[str, dict]` the `whl_library` args for each package name.
    """
    all_hubs = overrides.settings.get("", {})
    this_hub = overrides.settings.get(hub_name, {})
    ret = {}
    for whl_name in all_hubs.keys() + this_hub.keys():
        if whl_name in ret:
            continue
        ret[whl_name] = {}
        for field in ["ignore_dependencies", "extra_dependencies", "extra_tags"]:
            values = getattr(all_hubs.get(whl_name), field, []) + getattr(this_hub.get(whl_name), field, [])
            ret[whl_name][field] = {v: None for v in values}.keys()
    return ret

def whl_overrides_for_hub(overrides, hub_name, *, _fail = fail):
    """Get the patches of the packages in a hub.

    Args:
        overrides: {type}`struct` the result of {func}`parse_whl_overrides`.
        hub_name: {type}`str` the name of the hub.
        _fail: {type}`callable` the function to call on errors, for tests.

    Returns:
        {type}`dict[str, dict[Label, struct]]` the patches for each package
        name with the `patch_strip` and the wheel file names (`whls`) or the
        versions (`versions`, `*` for all) that they apply to.
    """
    ret = {}
    for whl_name, patches in overrides.files.items():
        ret[whl_name] = dict(patches)

    for key in ["", hub_name]:
        for whl_name, patches in overrides.packages.get(key, {}).items():
            whl_patches = ret.setdefault(whl_name, {})
            for patch, args in patches.items():
                existing = whl_patches.get(patch)
                if not existing:
                    whl_patches[patch] = args
                    continue

                if existing.patch_strip != args.patch_strip:
                    _fail("The patch '{}' for package '{}' is used with different 'patch_strip' values, use a copy of the patch file".format(patch, whl_name))
                    continue

                merged = {
                    "patch_strip": existing.patch_strip,
                    "versions": getattr(existing, "versions", []) + args.versions,
                }
                if getattr(existing, "whls", None):
                    merged["whls"] = existing.whls
                whl_patches[patch] = struct(**merged)

    return ret

def unmatched_whl_overrides(overrides, hub_packages):
    """Find the package overrides that do not match any package.

    Args:
        overrides: {type}`struct` the result of {func}`parse_whl_overrides`.
        hub_packages: {type}`dict[str, list[str]]` the normalized package names of
            each hub.

    Returns:
        {type}`list[str]` the error messages, empty if all overrides match.
    """
    errors = []
    for hub_name, packages in sorted(overrides.packages.items() + [
        (hub_name, modes)
        for hub_name, modes in overrides.build_modes.items()
        if hub_name not in overrides.packages
    ]):
        packages = [p for p in packages if p != "*"]
        if hub_name and hub_name not in hub_packages:
            errors.append("pip.override(hub_name = '{}') refers to a hub that does not exist".format(hub_name))
            continue

        hubs = [hub_name] if hub_name else hub_packages.keys()
        for whl_name in sorted(packages):
            if not [h for h in hubs if whl_name in hub_packages[h]]:
                errors.append("pip.override(package = '{}') does not match any package{}".format(
                    whl_name,
                    " in hub '{}'".format(hub_name) if hub_name else "",
                ))

    for hub_name, packages in sorted(overrides.settings.items()):
        hubs = [hub_name] if hub_name else hub_packages.keys()
        for whl_name, setting in sorted(packages.items()):
            for field, values in [
                ("ignore_dependencies", setting.ignore_dependencies),
                ("extra_dependencies", setting.extra_dependencies),
            ]:
                for value in values:
                    dep = requirement(value).name_
                    for h in hubs:
                        if h in hub_packages and whl_name in hub_packages[h] and dep not in hub_packages[h]:
                            errors.append("pip.override(package = '{}').{} refers to '{}', which is not in hub '{}'".format(
                                whl_name,
                                field,
                                dep,
                                h,
                            ))

    return errors
