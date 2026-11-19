"""Parse the uv.lock files into the requirements used by the hub_builder."""

load("//python/private:normalize_name.bzl", "normalize_name")
load("//python/uv/private:uv_lock_to_requirements.bzl", "uv_lock_extras_map")  # buildifier: disable=bzl-visibility
load(":hash.bzl", "hash")
load(":pep508_evaluate.bzl", "evaluate")
load(":select_whl.bzl", "select_whl")

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

def parse_uv_lock_json(uv_lock, all_platforms, logger, extra_pip_args = None, platforms = {}):
    """Parse uv.lock JSON and build the same return structs as parse_requirements.

    Args:
        uv_lock: {type}`dict` The decoded uv.lock contents.
        all_platforms: {type}`list[str]` The list of all platform names.
        logger: {type}`struct` A logger for diagnostic messages.
        extra_pip_args: {type}`list[str] | None` Extra pip arguments to pass through.
        platforms: {type}`dict[str, struct]` A dict of platform name to platform info
            (containing `.env` with PEP 508 marker environment).

    Returns:
        {type}`list[struct]` The same format as {func}`parse_requirements`.
    """
    extras_map = uv_lock_extras_map(uv_lock)

    uv_packages = {}

    if not platforms:
        fail("BUG: platforms must be configured")

    package_platforms = _uv_lock_package_platforms(uv_lock["package"], all_platforms, platforms)
    for i, pkg in enumerate(uv_lock["package"]):
        name = pkg["name"]
        version = pkg["version"]
        norm_name = normalize_name(name)
        entry = uv_packages.setdefault(norm_name, {
            "distribution": name,
            "resolved_srcs": [],
            "versions": {},
        })
        entry["versions"][version] = None
        source = pkg.get("source") or {}
        registry = (source.get("registry") or "").rstrip("/")
        if registry.startswith("http://") or registry.startswith("https://"):
            index_url = "{}/{}".format(registry, norm_name.replace("_", "-"))
        else:
            index_url = ""
        entry["index_url"] = index_url

        pkg_extras = sorted(extras_map.get(name, []))
        extra_str = "[{}]".format(",".join(pkg_extras)) if pkg_extras else ""

        pkg_platforms = package_platforms[i]

        # Prepare candidates
        candidates = []
        for wheel in pkg.get("wheels", []):
            url = wheel["url"]
            _, _, filename = url.rpartition("/")
            candidates.append(struct(
                filename = filename,
                url = url,
                digest = _parse_uv_lock_hash(wheel.get("hash", "")),
                kind = "wheel",
            ))

        sdist_struct = None
        sdist = pkg.get("sdist", None)
        if sdist:
            url = sdist["url"]
            _, _, filename = url.rpartition("/")
            sdist_struct = struct(
                filename = filename,
                url = url,
                digest = _parse_uv_lock_hash(sdist.get("hash", "")),
                kind = "sdist",
            )

        git_struct = None
        if pkg.get("source", {}).get("git"):
            # A git source is not a downloadable artifact. Leave `url` and
            # `filename` empty, the same as a `foo @ git+...` line from a
            # requirements file, so that `pip` builds it from the requirement
            # line instead of the Bazel downloader trying to fetch the URL.
            git_struct = struct(
                filename = "",
                url = "",
                digest = "",
                kind = "git",
                requirement = _uv_lock_git_requirement(pkg["source"]["git"]),
            )

        plat_to_src = {}
        for p in pkg_platforms:
            platform = platforms.get(p)
            if not platform:
                continue

            best_wheel = None
            if candidates:
                best_wheel = select_whl(
                    whls = candidates,
                    python_version = platform.env.get("python_full_version", "3"),
                    whl_platform_tags = platform.whl_platform_tags,
                    whl_abi_tags = platform.whl_abi_tags,
                    implementation_name = platform.env.get("implementation_name", "cpython"),
                    limit = 1,
                    logger = logger,
                )

            if best_wheel:
                plat_to_src[p] = best_wheel
            elif sdist_struct:
                plat_to_src[p] = sdist_struct
            elif git_struct:
                plat_to_src[p] = git_struct

        # Group platforms by resolved source
        src_to_plats = {}
        for p, src in plat_to_src.items():
            key = src.filename + src.digest
            src_to_plats.setdefault(key, struct(src = src, plats = [])).plats.append(p)

        # Build resolved_srcs
        for key, val in src_to_plats.items():
            src = val.src
            plats = sorted(val.plats)
            if src.kind == "git":
                requirement_line = "{name}{extras} @ {requirement}".format(
                    name = name,
                    extras = extra_str,
                    requirement = src.requirement,
                )
            else:
                requirement_line = "{name}{extras}=={version}".format(
                    name = name,
                    extras = extra_str,
                    version = version,
                )
            entry["resolved_srcs"].append(struct(
                distribution = name,
                extra_pip_args = extra_pip_args or [],
                requirement_line = requirement_line,
                target_platforms = plats,
                filename = src.filename,
                digest = src.digest,
                url = src.url,
                yanked = None,
            ))

    ret = []
    for norm_name, info in sorted(uv_packages.items()):
        versions = sorted(info["versions"].keys())
        resolved_platforms = {}
        for src in info["resolved_srcs"]:
            for p in src.target_platforms:
                resolved_platforms[p] = None
        item = struct(
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
        )
        ret.append(item)

    logger.debug(lambda: "Parsed {} packages from uv.lock".format(len(ret)))
    return ret

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
