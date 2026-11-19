"""Parse the `pip.override` tags into the patches for each hub."""

load("//python/private:normalize_name.bzl", "normalize_name")
load(":parse_whl_name.bzl", "parse_whl_name")

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

            name, _, version = attr.package.partition("@")
            whl_name = normalize_name(name)
            key = (attr.hub_name, whl_name, version)
            if key in seen_packages:
                _fail("Duplicate module overrides for package '{}'{}".format(
                    attr.package,
                    " in hub '{}'".format(attr.hub_name) if attr.hub_name else "",
                ))
                continue
            seen_packages[key] = None

            patches = packages.setdefault(attr.hub_name, {}).setdefault(whl_name, {})
            for patch in attr.patches:
                if patch in patches and patches[patch].patch_strip != attr.patch_strip:
                    _fail("The patch '{}' for package '{}' is used with different 'patch_strip' values".format(patch, attr.package))
                    continue
                patches.setdefault(patch, struct(
                    patch_strip = attr.patch_strip,
                    versions = [],
                )).versions.append(version or "*")

    return struct(
        files = files,
        packages = packages,
    )

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
                    _fail("The patch '{}' for package '{}' is used with different 'patch_strip' values".format(patch, whl_name))
                    continue

                whl_patches[patch] = struct(
                    patch_strip = existing.patch_strip,
                    whls = getattr(existing, "whls", []),
                    versions = getattr(existing, "versions", []) + args.versions,
                )

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
    for hub_name, packages in sorted(overrides.packages.items()):
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

    return errors
