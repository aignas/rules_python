"""Translate the pylock.toml (PEP 751) files into the lock model, see `lock_model.bzl`."""

load("//python/private:normalize_name.bzl", "normalize_name")
load("//python/private:version.bzl", pep440 = "version")
load(":hash.bzl", "hash")
load(":lock_model.bzl", "lock_dist", "lock_entry")
load(":pep508_evaluate.bzl", "evaluate")
load(":uv_lock.bzl", "local_wheels_by_name")

def pylock_entries(pylock, *, all_platforms, platforms, local_wheels = [], logger, _fail = fail):
    """Translate the pylock.toml contents into the lock model.

    All of the extras, the default groups and the dependency groups that the
    lock file lists are selected. A package is used on the platforms where its
    `marker` is true; the dependency graph is not used, as the standard
    requires. The `vcs` sources and the `archive` sources that are not wheels
    are built by pip from their URL, the `archive` wheels are used like the
    other wheels and the `directory` sources are the local projects, which are
    ignored.

    Args:
        pylock: {type}`dict` The decoded pylock.toml contents.
        all_platforms: {type}`list[str]` The list of all platform names.
        platforms: {type}`dict[str, struct]` A dict of platform name to platform info
            (containing `.env` with PEP 508 marker environment).
        local_wheels: {type}`list[Label]` the local wheels to use instead of
            the locked wheels of the same package version.
        logger: {type}`struct` A logger for diagnostic messages.
        _fail: {type}`callable` the function to call on errors, for tests.

    Returns:
        {type}`struct` with `entries` - the {func}`lock_entry` values and
        `platforms` - the platforms that match the lock file.
    """
    lock_version = pylock.get("lock-version", "")
    if not lock_version.startswith("1."):
        return _fail("Only the pylock.toml 'lock-version' 1.x is supported, got: '{}'".format(lock_version))
    if lock_version != "1.0":
        logger.warn(lambda: "The pylock.toml 'lock-version' {} is newer than the supported 1.0".format(lock_version))

    envs = {}
    for p in all_platforms:
        env = dict(platforms[p].env)
        env.setdefault("extra", "")
        env["extras"] = pylock.get("extras", [])
        env["dependency_groups"] = pylock.get("default-groups", []) + pylock.get("dependency-groups", [])

        requires_python = pylock.get("requires-python")
        if requires_python and not _requires_python(requires_python, env):
            return _fail("The pylock.toml 'requires-python = \"{}\"' does not match the Python version {} of the '{}' platform".format(
                requires_python,
                env.get("python_full_version"),
                p,
            ))

        environments = pylock.get("environments", [])
        if environments and not [m for m in environments if evaluate(m, env = env)]:
            logger.warn(lambda: "The pylock.toml 'environments' do not match the '{}' platform, ignoring it".format(p))
            continue

        envs[p] = env

    local_by_name = local_wheels_by_name(local_wheels)
    used_local_wheels = {}

    entries = []
    for pkg in pylock.get("packages", []):
        name = pkg["name"]
        version = pkg.get("version", "")
        if "directory" in pkg:
            # A local project, e.g. the project that the lock file is for.
            logger.debug(lambda: "Ignoring the pylock.toml package '{}' from the directory '{}'".format(
                name,
                pkg["directory"].get("path"),
            ))
            continue

        direct_requirement = ""
        archive = None
        if "vcs" in pkg:
            direct_requirement = _vcs_requirement(name, pkg["vcs"], _fail = _fail)
            if not direct_requirement:
                return None
        elif "archive" in pkg:
            archive = pkg["archive"]
            if "url" not in archive:
                return _fail("The pylock.toml package '{}' has an 'archive' without a 'url', which is not supported".format(name))
            if not _dist(archive).filename.endswith(".whl"):
                # Let pip build the archive from its URL with the hash, so
                # that it verifies the download and does not use a wheel
                # from the index instead.
                direct_requirement = _archive_requirement(archive)
                archive = None
        if not version and not direct_requirement:
            return _fail("The pylock.toml package '{}' has no 'version'".format(name))

        target_platforms = [
            p
            for p, env in envs.items()
            if not pkg.get("marker") or evaluate(pkg["marker"], env = env)
        ]
        for p in target_platforms:
            if pkg.get("requires-python") and not _requires_python(pkg["requires-python"], envs[p]):
                return _fail("The pylock.toml package '{}' has 'requires-python = \"{}\"', which does not match the Python version {} of the '{}' platform".format(
                    name,
                    pkg["requires-python"],
                    envs[p].get("python_full_version"),
                    p,
                ))

        local = []
        if version and normalize_name(name) in local_by_name:
            locked_version = pep440.parse(version)
            local = [
                whl
                for v, whl in local_by_name[normalize_name(name)]
                if v and locked_version and pep440.is_eq(v, locked_version)
            ]
            for whl in local:
                used_local_wheels[whl.file] = None

        sdist = pkg.get("sdist")
        wheels = pkg.get("wheels", [])
        if archive:
            wheels = wheels + [archive]
        if [d for d in wheels + ([sdist] if sdist else []) if "url" not in d]:
            logger.warn(lambda: "The pylock.toml package '{}' has files without a 'url', which are ignored, use the 'local_wheels' instead".format(name))
        entries.append(lock_entry(
            name = name,
            version = version,
            target_platforms = target_platforms,
            index_url = "{}/{}".format(pkg["index"].rstrip("/"), normalize_name(name).replace("_", "-")) if pkg.get("index") else "",
            wheels = [_dist(wheel) for wheel in wheels if "url" in wheel],
            local_wheels = local,
            sdist = _dist(sdist) if sdist and "url" in sdist else None,
            direct_requirement = direct_requirement,
        ))

    for whls in local_by_name.values():
        for _, whl in whls:
            if whl.file not in used_local_wheels:
                _fail("The local wheel '{}' does not match the version of any package in the lock file".format(whl.file))

    return struct(
        entries = entries,
        platforms = sorted(envs),
    )

def _vcs_requirement(name, vcs, *, _fail):
    """Turn a `vcs` source into a pip direct reference."""
    if vcs.get("type") not in ["git", "hg", "svn", "bzr"] or not vcs.get("url") or not vcs.get("commit-id"):
        return _fail("The pylock.toml package '{}' needs a 'vcs' source of the 'git', 'hg', 'svn' or 'bzr' type with a 'url' (not a 'path') and a 'commit-id'".format(name))

    url = vcs["url"]
    if not url.startswith(vcs["type"] + "+"):
        url = "{}+{}".format(vcs["type"], url)
    requirement = "{}@{}".format(url, vcs["commit-id"])
    if vcs.get("subdirectory"):
        requirement += "#subdirectory={}".format(vcs["subdirectory"])
    return requirement

def _archive_requirement(archive):
    """Turn an `archive` source into a pip direct reference with its hash."""
    fragments = [
        "{}={}".format(algo, hex_digest)
        for algo, hex_digest in sorted(archive.get("hashes", {}).items())
    ][:1]
    if archive.get("subdirectory"):
        fragments.append("subdirectory={}".format(archive["subdirectory"]))
    if not fragments:
        return archive["url"]
    return "{}#{}".format(archive["url"], "&".join(fragments))

def _requires_python(specifiers, env):
    """Evaluate a `requires-python` specifier set, e.g. `>=3.9,<4`."""
    return evaluate(
        " and ".join([
            "python_full_version {}".format(_quote_version(s.strip()))
            for s in specifiers.split(",")
            if s.strip()
        ]),
        env = env,
    )

def _quote_version(specifier):
    """Turn `>=3.9` into `>= "3.9"`."""
    for i, c in enumerate(specifier.elems()):
        if c not in "<>=!~ ":
            return "{} \"{}\"".format(specifier[:i].strip(), specifier[i:].strip())
    return specifier

def _dist(dist):
    url = dist["url"]
    path, _, _ = url.partition("#")
    path, _, _ = path.partition("?")
    _, _, filename = path.rpartition("/")
    return lock_dist(
        filename = dist.get("name") or filename.replace("%2B", "+").replace("%2b", "+"),
        url = url,
        digest = hash.preferred_digest([
            hash.digest(algo, hex_digest)
            for algo, hex_digest in dist.get("hashes", {}).items()
        ]),
    )
