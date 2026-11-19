"""Translate the uv.lock files into the lock model, see `lock_model.bzl`."""

load("//python/private:normalize_name.bzl", "normalize_name")
load("//python/uv/private:uv_lock_to_requirements.bzl", "uv_lock_extras_map")  # buildifier: disable=bzl-visibility
load(":hash.bzl", "hash")
load(":lock_model.bzl", "lock_dist", "lock_entry")
load(":pep508_evaluate.bzl", "evaluate")

def _uv_lock_package_dependencies(pkg):
    """Collect regular, optional, and development dependency edges."""
    deps = list(pkg.get("dependencies", []))
    for table in ["optional-dependencies", "dev-dependencies"]:
        for group in pkg.get(table, {}).values():
            deps.extend(group)
    return deps

def _uv_lock_package_platforms(packages, all_platforms, platforms):
    """Find each lock entry's platforms by walking dependency edges from roots.

    Follow all optional dependencies because uv_lock_extras_map enables every
    recorded extra. Development dependency groups must also remain available.
    """
    by_name = {}
    roots = []
    dependencies = []
    for i, pkg in enumerate(packages):
        by_name.setdefault(normalize_name(pkg["name"]), []).append(i)
        dependencies.append(_uv_lock_package_dependencies(pkg))
        source = pkg.get("source", {})
        if "virtual" in source or "editable" in source:
            roots.append(i)

    result = [[] for _ in packages]
    for p in all_platforms:
        marker_env = platforms[p].env
        compatible = {
            i: None
            for i, pkg in enumerate(packages)
            if not pkg.get("resolution-markers") or evaluate(
                " or ".join(pkg["resolution-markers"]),
                env = marker_env,
                strict = False,
            ) != False
        }
        if not roots:
            # Exported/synthetic locks without workspace roots retain the
            # package-level resolution-marker behavior.
            for i in compatible:
                result[i].append(p)
            continue

        visited = {i: None for i in roots if i in compatible}
        queue = list(visited)

        # Mark packages when enqueuing so cycles and diamonds cannot exceed
        # the number of packages. Starlark has no while loops.
        for _ in range(len(packages)):
            if not queue:
                break
            i = queue.pop()
            result[i].append(p)
            for dep in dependencies[i]:
                # Unknown values (notably `extra`) may remain as expressions;
                # only a definitively false platform marker excludes an edge.
                marker = dep.get("marker", "")
                if marker and evaluate(marker, env = marker_env, strict = False) == False:
                    continue
                for target in by_name.get(normalize_name(dep["name"]), []):
                    if target not in compatible or target in visited:
                        continue

                    # Forked entries can share a name but differ in identity.
                    pkg = packages[target]
                    if "version" in dep and dep["version"] != pkg["version"]:
                        continue
                    if "source" in dep and dep["source"] != pkg.get("source", {}):
                        continue
                    visited[target] = None
                    queue.append(target)
    return result

def uv_lock_entries(uv_lock, *, all_platforms, platforms):
    """Translate the uv.lock contents into the lock model.

    Args:
        uv_lock: {type}`dict` The decoded uv.lock contents.
        all_platforms: {type}`list[str]` The list of all platform names.
        platforms: {type}`dict[str, struct]` A dict of platform name to platform info
            (containing `.env` with PEP 508 marker environment).

    Returns:
        {type}`list[struct]` the {func}`lock_entry` values.
    """
    if not platforms:
        fail("BUG: platforms must be configured")

    extras_map = uv_lock_extras_map(uv_lock)
    package_platforms = _uv_lock_package_platforms(uv_lock["package"], all_platforms, platforms)

    entries = []
    for i, pkg in enumerate(uv_lock["package"]):
        name = pkg["name"]
        source = pkg.get("source") or {}
        registry = (source.get("registry") or "").rstrip("/")
        if registry.startswith("http://") or registry.startswith("https://"):
            index_url = "{}/{}".format(registry, normalize_name(name).replace("_", "-"))
        else:
            index_url = ""

        sdist = pkg.get("sdist", None)
        entries.append(lock_entry(
            name = name,
            version = pkg["version"],
            target_platforms = package_platforms[i],
            index_url = index_url,
            extras = sorted(extras_map.get(name, [])),
            wheels = [_uv_lock_dist(wheel) for wheel in pkg.get("wheels", [])],
            sdist = _uv_lock_dist(sdist) if sdist else None,
            direct_requirement = _uv_lock_git_requirement(source["git"]) if source.get("git") else "",
        ))

    return entries

def _uv_lock_dist(dist):
    url = dist["url"]
    _, _, filename = url.rpartition("/")
    return lock_dist(
        filename = filename,
        url = url,
        digest = _parse_uv_lock_hash(dist.get("hash", "")),
    )

def _uv_lock_git_requirement(git_source):
    """Turn a uv.lock git source into a pip direct reference.

    uv records `<repo url>?<query>#<resolved commit>`, where the query carries
    `rev`, `tag` or `branch` and optionally `subdirectory`. pip expects
    `git+<repo url>@<commit>[#subdirectory=<dir>]`. Pinning to the resolved
    commit rather than the requested ref keeps the build reproducible.

    Args:
        git_source: {type}`str` the `source.git` value from uv.lock.

    Returns:
        {type}`str` the pip direct reference, without the `<name> @ ` prefix.
    """
    head, _, commit = git_source.partition("#")
    repo_url, _, query = head.partition("?")
    subdirectory = ""
    for param in query.split("&"):
        key, _, value = param.partition("=")
        if key == "subdirectory":
            # uv percent-encodes the value (`python%2Ffoo`), but pip reads the
            # `#subdirectory=` fragment as a literal path.
            subdirectory = _percent_decode(value)
    requirement = "git+{}@{}".format(repo_url, commit)
    if subdirectory:
        requirement += "#subdirectory={}".format(subdirectory)
    return requirement

# Printable ASCII, indexed by `code point - 0x20`, as Starlark has no `chr()`.
_PRINTABLE_ASCII = " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~"

def _percent_decode(value):
    """Decode `%XX` escapes of printable ASCII; leave any other escape as-is."""
    parts = value.split("%")
    out = [parts[0]]
    for part in parts[1:]:
        code = int(part[:2], 16) if len(part) >= 2 and _is_hex(part[:2]) else -1
        if code >= 0x20 and code <= 0x7e:
            out.append(_PRINTABLE_ASCII[code - 0x20] + part[2:])
        else:
            out.append("%" + part)
    return "".join(out)

def _is_hex(s):
    for c in s.elems():
        if c not in "0123456789abcdefABCDEF":
            return False
    return True

def _parse_uv_lock_hash(hash_str):
    """Parse a uv.lock `hash` value of the form `<algo>:<digest>`.

    The algorithm is not necessarily `sha256` because uv records the strongest
    digest that the index offers.
    """
    algo, _, hex_digest = hash_str.partition(":")
    return hash.digest(algo, hex_digest)
