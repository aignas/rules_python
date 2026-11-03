"""Select PyPI packages using pyproject.toml dependency groups."""

load("//python/private:normalize_name.bzl", "normalize_name")
load(":pep508_requirement.bzl", "requirement")

def select_dependency_groups(pyproject, specs, _fail = fail):
    """Select the packages named by the given dependency group specifiers.

    Supported specifiers are:

      * `"default"`: the `[project] dependencies`.
      * `"optional:<name>"`: a `[project.optional-dependencies]` entry.
      * `"group:<name>"`: a PEP 735 `[dependency-groups]` entry.
      * `"optional:*"` and `"group:*"`: all entries of the table.
      * `"*"`: all of the above.
      * `"<name>"`: a dependency group, or an optional dependency group if
        there is no dependency group with that name.
      * `"transitive"`: also select the dependencies of the selected packages.

    Any specifier, except `"transitive"`, may be suffixed with `;testonly`.
    When a group is matched by multiple specifiers, the last one wins.

    Args:
        pyproject: {type}`struct` returned by `read_pyproject`.
        specs: {type}`list[str]` the specifiers.
        _fail: {type}`callable` the failure function, mainly for testing.

    Returns:
        {type}`struct` with the attributes:
          * `packages`: {type}`dict[str, bool]` normalized package names
            mapped to whether they are testonly. A package is testonly only
            if every group that selected it is testonly.
          * `transitive`: {type}`bool` whether `"transitive"` was given.
    """
    groups = {"default": pyproject.dependencies}
    for name, reqs in pyproject.optional_dependencies.items():
        groups["optional:" + normalize_name(name)] = reqs
    for name, reqs in _expand_dependency_groups(pyproject.dependency_groups, _fail).items():
        groups["group:" + name] = reqs

    selected = {}
    transitive = False
    for spec in specs:
        spec, _, modifier = spec.partition(";")
        if modifier and modifier != "testonly":
            _fail("Invalid dependency group specifier '{};{}': the only supported modifier is 'testonly'".format(spec, modifier))
            continue
        testonly = bool(modifier)

        if spec == "transitive":
            if testonly:
                _fail("The 'transitive' specifier does not support the 'testonly' modifier")
            transitive = True
            continue

        keys = _match(spec, groups)
        if not keys:
            _fail("Unknown dependency group '{}'. Available groups: {}".format(
                spec,
                ", ".join(sorted(groups)),
            ))
        for key in keys:
            selected[key] = testonly

    # A self reference like `my-project[test]` selects the optional
    # dependencies, but only one level deep.
    project = normalize_name(pyproject.name or "")
    packages = {}
    for key, testonly in selected.items():
        for req in groups[key]:
            req = requirement(req)
            names = [req.name_]
            if req.name_ == project:
                names = [
                    requirement(r).name_
                    for extra in req.extras
                    for r in groups.get("optional:" + extra, [])
                ]
            for name in names:
                if name:
                    packages[name] = packages.get(name, True) and testonly

    return struct(packages = packages, transitive = transitive)

def _match(spec, groups):
    if spec == "*":
        return groups.keys()
    if spec in ("optional:*", "group:*"):
        prefix = spec[:-1]
        return [key for key in groups if key.startswith(prefix)]

    kind, _, name = spec.rpartition(":")
    name = normalize_name(name)
    if kind:
        candidates = [kind + ":" + name]
    elif name == "default":
        candidates = ["default"]
    else:
        candidates = ["group:" + name, "optional:" + name]

    for key in candidates:
        if key in groups:
            return [key]
    return []

def _expand_dependency_groups(dependency_groups, _fail):
    """Expand the PEP 735 `include-group` entries.

    Args:
        dependency_groups: {type}`dict[str, list]` the `[dependency-groups]`
            table.
        _fail: {type}`callable` the failure function.

    Returns:
        {type}`dict[str, list[str]]` normalized group names mapped to their
        requirement strings.
    """
    groups = {
        normalize_name(name): items
        for name, items in dependency_groups.items()
    }

    # Each round expands at least one group unless there is a cycle.
    expanded = {}
    for _ in range(len(groups)):
        for name, items in groups.items():
            if name in expanded:
                continue

            reqs = []
            for item in items:
                if type(item) == type(""):
                    reqs.append(item)
                    continue

                include = normalize_name(item.get("include-group", ""))
                if include not in groups:
                    _fail("Unknown dependency group '{}' included from '{}'".format(include, name))
                    return {}
                if include not in expanded:
                    reqs = None
                    break
                reqs.extend(expanded[include])

            if reqs != None:
                expanded[name] = reqs

    if len(expanded) != len(groups):
        _fail("Cyclic dependency group includes: {}".format(
            ", ".join(sorted([name for name in groups if name not in expanded])),
        ))
    return expanded

def uv_lock_graph(uv_lock):
    """Build the dependency graph from a decoded uv.lock file.

    The extras of every package are included, so the graph may contain more
    edges than strictly necessary.

    Args:
        uv_lock: {type}`dict` the decoded uv.lock file.

    Returns:
        {type}`dict[str, dict[str, None]]` normalized package names mapped to
        their normalized dependencies.
    """
    graph = {}
    for pkg in uv_lock.get("package", []):
        deps = graph.setdefault(normalize_name(pkg["name"]), {})
        dep_lists = [pkg.get("dependencies", [])]
        dep_lists.extend(pkg.get("optional-dependencies", {}).values())
        dep_lists.extend(pkg.get("dev-dependencies", {}).values())
        for dep_list in dep_lists:
            for dep in dep_list:
                deps[normalize_name(dep["name"])] = None
    return graph

def with_dependencies(packages, graph, *, transitive):
    """Use the dependency graph to adjust the selected packages.

    A selected package that a non-testonly package depends on can't be
    testonly, otherwise the non-testonly package would not build. When
    `transitive` is set, the dependencies of the selected packages are added
    and they are testonly if only testonly packages depend on them.

    Args:
        packages: {type}`dict[str, bool]` the selected packages mapped to
            whether they are testonly.
        graph: {type}`dict[str, dict[str, None]]` the dependency graph.
        transitive: {type}`bool` whether to add the dependencies.

    Returns:
        {type}`dict[str, bool]` the packages mapped to whether they are
        testonly.
    """
    non_testonly = _reachable(graph, [name for name, testonly in packages.items() if not testonly])
    candidates = _reachable(graph, packages.keys()) if transitive else packages
    return {
        name: name not in non_testonly
        for name in candidates
    }

def _reachable(graph, roots):
    seen = {root: None for root in roots}
    stack = list(seen)

    # Every node is pushed onto the stack at most once.
    max_nodes = len(seen) + len(graph)
    for deps in graph.values():
        max_nodes += len(deps)
    for _ in range(max_nodes):
        if not stack:
            break
        for dep in graph.get(stack.pop(), {}):
            if dep not in seen:
                seen[dep] = None
                stack.append(dep)
    return seen
