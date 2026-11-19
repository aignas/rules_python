"""A lock file format independent model of the locked packages.

The lock file parsers (e.g. `uv_lock.bzl`) translate the lock file into a list
of {func}`lock_entry` values and {func}`lock_requirements` selects the
distribution for each target platform and returns the same structs as
`parse_requirements`.
"""

load("//python/private:normalize_name.bzl", "normalize_name")
load(":select_whl.bzl", "select_whl")

def lock_dist(*, filename, url, digest):
    """A distribution file (a wheel or an sdist) of a locked package.

    Args:
        filename: {type}`str` the file name.
        url: {type}`str` the URL to download the file from.
        digest: {type}`str` the `<algo>:<digest>` of the file or an empty
            string if it is unknown.

    Returns:
        {type}`struct` the distribution.
    """
    return struct(
        filename = filename,
        url = url,
        digest = digest,
    )

def lock_entry(
        *,
        name,
        version,
        target_platforms,
        index_url = "",
        extras = [],
        wheels = [],
        sdist = None,
        direct_requirement = ""):
    """A single locked package.

    Args:
        name: {type}`str` the distribution name as written in the lock file.
        version: {type}`str` the locked version.
        target_platforms: {type}`list[str]` the target platforms that need
            this package.
        index_url: {type}`str` the index URL of the package.
        extras: {type}`list[str]` the extras to install.
        wheels: {type}`list[struct]` the {func}`lock_dist` wheels.
        sdist: {type}`struct | None` the {func}`lock_dist` sdist.
        direct_requirement: {type}`str` a direct reference that `pip` builds
            the package from (e.g. `git+https://...@<commit>`), used when
            there are no files to download.

    Returns:
        {type}`struct` the lock entry.
    """
    return struct(
        name = name,
        version = version,
        target_platforms = target_platforms,
        index_url = index_url,
        extras = extras,
        wheels = wheels,
        sdist = sdist,
        direct_requirement = direct_requirement,
    )

def lock_requirements(entries, *, all_platforms, platforms, logger, extra_pip_args = None):
    """Select the distributions of the locked packages for each platform.

    Args:
        entries: {type}`list[struct]` the {func}`lock_entry` values.
        all_platforms: {type}`list[str]` The list of all platform names.
        platforms: {type}`dict[str, struct]` A dict of platform name to
            platform info (containing `.env` with PEP 508 marker environment).
        logger: {type}`struct` A logger for diagnostic messages.
        extra_pip_args: {type}`list[str] | None` Extra pip arguments to pass
            through.

    Returns:
        {type}`list[struct]` The same format as `parse_requirements`.
    """
    packages = {}
    for entry in entries:
        name = entry.name
        version = entry.version
        norm_name = normalize_name(name)
        info = packages.setdefault(norm_name, {
            "resolved_srcs": [],
            "versions": {},
        })
        info["versions"][version] = None
        info["index_url"] = entry.index_url

        extra_str = "[{}]".format(",".join(entry.extras)) if entry.extras else ""
        pinned = "{name}{extras}=={version}".format(
            name = name,
            extras = extra_str,
            version = version,
        )

        plat_to_src = {}
        for p in entry.target_platforms:
            platform = platforms.get(p)
            if not platform:
                continue

            best_wheel = None
            if entry.wheels:
                best_wheel = select_whl(
                    whls = entry.wheels,
                    python_version = platform.env.get("python_full_version", "3"),
                    whl_platform_tags = platform.whl_platform_tags,
                    whl_abi_tags = platform.whl_abi_tags,
                    implementation_name = platform.env.get("implementation_name", "cpython"),
                    limit = 1,
                    logger = logger,
                )

            if best_wheel:
                plat_to_src[p] = struct(dist = best_wheel, requirement_line = pinned)
            elif entry.sdist:
                plat_to_src[p] = struct(dist = entry.sdist, requirement_line = pinned)
            elif entry.direct_requirement:
                # A direct reference is not a downloadable artifact. Leave
                # `url` and `filename` empty, the same as a `foo @ git+...`
                # line from a requirements file, so that `pip` builds it from
                # the requirement line instead of the Bazel downloader trying
                # to fetch the URL.
                plat_to_src[p] = struct(
                    dist = lock_dist(filename = "", url = "", digest = ""),
                    requirement_line = "{name}{extras} @ {requirement}".format(
                        name = name,
                        extras = extra_str,
                        requirement = entry.direct_requirement,
                    ),
                )

        # Group platforms by resolved source
        src_to_plats = {}
        for p, src in plat_to_src.items():
            key = src.requirement_line + src.dist.filename + src.dist.digest
            src_to_plats.setdefault(key, struct(src = src, plats = [])).plats.append(p)

        for val in src_to_plats.values():
            src = val.src.dist
            requirement_line = val.src.requirement_line
            info["resolved_srcs"].append(struct(
                distribution = name,
                extra_pip_args = extra_pip_args or [],
                requirement_line = requirement_line,
                target_platforms = sorted(val.plats),
                filename = src.filename,
                digest = src.digest,
                url = src.url,
                yanked = None,
            ))

    ret = []
    for norm_name, info in sorted(packages.items()):
        versions = sorted(info["versions"].keys())
        resolved_platforms = {}
        for src in info["resolved_srcs"]:
            for p in src.target_platforms:
                resolved_platforms[p] = None
        ret.append(struct(
            name = norm_name,
            # Only expose packages that resolved on all configured platforms.
            # Workspace/root members (e.g. `source = { virtual = "." }` or
            # editable installs) resolve to no wheel/sdist, and
            # platform-specific packages only resolve on a subset of platforms;
            # exposing either in `all_requirements` / `all_whl_requirements`
            # would break builds on platforms where the package has no matching
            # wheel/sdist. This mirrors the requirements file path.
            is_exposed = bool(all_platforms) and (
                len(resolved_platforms) == len(all_platforms)
            ),
            is_multiple_versions = len(versions) > 1,
            index_url = info["index_url"],
            srcs = info["resolved_srcs"],
        ))

    return ret
