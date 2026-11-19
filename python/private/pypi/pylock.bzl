"""Translate the pylock.toml (PEP 751) files into the lock model, see `lock_model.bzl`."""

load("//python/private:normalize_name.bzl", "normalize_name")
load("//python/private:version.bzl", pep440 = "version")
load(":hash.bzl", "hash")
load(":lock_model.bzl", "lock_dist", "lock_entry")
load(":pep508_evaluate.bzl", "evaluate")
load(":uv_lock.bzl", "local_wheels_by_name")

def pylock_entries(pylock, *, all_platforms, platforms, local_wheels = [], logger, _fail = fail):
    """Translate the pylock.toml contents into the lock model.

    All of the extras and the dependency groups that the lock file lists are
    selected. A package is used on the platforms where its `marker` and its
    `requires-python` are true; the dependency graph is not used, as the
    standard requires.

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
        {type}`list[struct]` the {func}`lock_entry` values.
    """
    lock_version = pylock.get("lock-version", "")
    if not lock_version.startswith("1."):
        return _fail("Only the pylock.toml 'lock-version' 1.x is supported, got: '{}'".format(lock_version))

    envs = {}
    for p in all_platforms:
        env = dict(platforms[p].env)
        env["extras"] = pylock.get("extras", [])
        env["dependency_groups"] = pylock.get("dependency-groups", [])

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
        for key in ["vcs", "archive", "directory"]:
            if key in pkg:
                return _fail("The pylock.toml package '{}' has a '{}' source, which is not supported".format(name, key))

        target_platforms = [
            p
            for p, env in envs.items()
            if (not pkg.get("marker") or evaluate(pkg["marker"], env = env)) and
               (not pkg.get("requires-python") or _requires_python(pkg["requires-python"], env))
        ]

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
        entries.append(lock_entry(
            name = name,
            version = version,
            target_platforms = target_platforms,
            index_url = "{}/{}".format(pkg["index"].rstrip("/"), normalize_name(name).replace("_", "-")) if pkg.get("index") else "",
            wheels = [_dist(wheel) for wheel in pkg.get("wheels", []) if "url" in wheel],
            local_wheels = local,
            sdist = _dist(sdist) if sdist and "url" in sdist else None,
        ))

    for whls in local_by_name.values():
        for _, whl in whls:
            if whl.file not in used_local_wheels:
                _fail("The local wheel '{}' does not match the version of any package in the lock file".format(whl.file))

    return entries

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
    _, _, filename = url.rpartition("/")
    return lock_dist(
        filename = dist.get("name") or filename,
        url = url,
        digest = hash.preferred_digest([
            hash.digest(algo, hex_digest)
            for algo, hex_digest in dist.get("hashes", {}).items()
        ]),
    )
