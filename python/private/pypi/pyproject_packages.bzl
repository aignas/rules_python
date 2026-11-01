"""Utilities for selecting PyPI packages from pyproject.toml dependency groups."""

load("@toml.bzl", "toml")
load("//python/private:normalize_name.bzl", "normalize_name")
load("//python/private:pyproject_utils.bzl", "read_pyproject", "resolve_dependency_groups")
load(":pep508_requirement.bzl", "requirement")

def packages_from_dependency_groups(module_ctx, pyproject, dependency_groups, _fail = fail):
    """Query the package names selected by the given dependency groups.

    The dependency groups are resolved from the `[project] dependencies`,
    `[project.optional-dependencies]`, and `[dependency-groups]` tables of the
    given `pyproject.toml`.

    Args:
        module_ctx: {type}`module_ctx` module context.
        pyproject: {type}`Label | str` the pyproject.toml to read.
        dependency_groups: {type}`list[str]` the dependency group specifiers.
        _fail: {type}`callable` the failure function, mainly for testing.

    Returns:
        {type}`list[str]` the sorted, deduplicated, normalized package names.
    """
    pyproject = read_pyproject(module_ctx, pyproject)
    return dependency_group_selection(
        pyproject,
        dependency_groups,
        _fail = _fail,
    ).packages

def dependency_group_selection(pyproject, specs, _fail = fail):
    """Resolve dependency group specifiers to package names and testonly info.

    Supported specifiers are:

      * `"default"`: the project's `[project] dependencies`.
      * `"optional:<name>"`: a `[project.optional-dependencies]` entry.
      * `"group:<name>"`: a PEP 735 `[dependency-groups]` entry.
      * `"optional:*"`: all optional dependency groups.
      * `"group:*"`: all dependency groups.
      * `"*"`: the default dependencies plus all optional and all dependency
        groups.
      * `"transitive"`: include every package in the concrete hub, not just
        the packages selected by the groups.
      * `"<name>"`: a dependency group if one exists with that name, otherwise
        an optional dependency group.

    Any specifier may be suffixed with `;testonly` to mark its packages as
    testonly. The `*` and category wildcards use last-wins precedence: a later
    wildcard resets earlier specific overrides, and a later specific entry
    overrides the wildcard. `"transitive"` is a modifier and is not included
    by `"*"`.

    PEP 735 `include-group` entries are expanded without recursion and cycles
    are reported as errors.

    Args:
        pyproject: {type}`struct` returned by {obj}`read_pyproject`.
        specs: {type}`list[str]` the group specifiers to resolve.
        _fail: {type}`callable` the failure function, mainly for testing.

    Returns:
        {type}`struct` with the attributes:
          * `packages`: {type}`list[str]` sorted, normalized package names.
          * `testonly_packages`: {type}`list[str]` the subset of `packages`
            whose selected groups are all testonly.
          * `transitive`: {type}`bool` whether the `"transitive"` modifier was
            present.
          * `transitive_testonly`: {type}`bool` whether the last `"transitive"`
            modifier was `;testonly`.
    """
    optional_dependencies = {
        normalize_name(name): deps
        for name, deps in pyproject.optional_dependencies.items()
    }
    dependency_groups = {
        normalize_name(name): items
        for name, items in pyproject.dependency_groups.items()
    }

    global_testonly = False
    optional_default_testonly = None
    group_default_testonly = None
    specific_testonly = {}
    selected = {}
    transitive = False
    transitive_testonly = False

    for raw_spec in specs:
        parsed = _parse_spec(raw_spec, _fail)
        if not parsed:
            continue

        spec = parsed.base
        testonly = parsed.testonly

        if spec == "*":
            global_testonly = testonly
            optional_default_testonly = None
            group_default_testonly = None
            specific_testonly = {}
            selected["default"] = None
            for name in optional_dependencies:
                selected["optional:" + name] = None
            for name in dependency_groups:
                selected["group:" + name] = None
        elif spec == "optional:*":
            optional_default_testonly = testonly
            specific_testonly = {
                key: value
                for key, value in specific_testonly.items()
                if not key.startswith("optional:")
            }
            for name in optional_dependencies:
                selected["optional:" + name] = None
        elif spec == "group:*":
            group_default_testonly = testonly
            specific_testonly = {
                key: value
                for key, value in specific_testonly.items()
                if not key.startswith("group:")
            }
            for name in dependency_groups:
                selected["group:" + name] = None
        elif spec == "transitive":
            transitive = True
            transitive_testonly = testonly
        elif spec == "default":
            specific_testonly["default"] = testonly
            selected["default"] = None
        elif spec.startswith("optional:"):
            name = normalize_name(spec[len("optional:"):])
            if name not in optional_dependencies:
                _fail("Unknown optional dependency group '{}'. Available groups: {}".format(
                    name,
                    ", ".join(sorted(optional_dependencies)),
                ))
                continue
            specific_testonly["optional:" + name] = testonly
            selected["optional:" + name] = None
        elif spec.startswith("group:"):
            name = normalize_name(spec[len("group:"):])
            if name not in dependency_groups:
                _fail("Unknown dependency group '{}'. Available dependency groups: {}".format(
                    name,
                    ", ".join(sorted(dependency_groups)),
                ))
                continue
            specific_testonly["group:" + name] = testonly
            selected["group:" + name] = None
        else:
            name = normalize_name(spec)
            if name in dependency_groups:
                key = "group:" + name
            elif name in optional_dependencies:
                key = "optional:" + name
            else:
                _fail("Unknown dependency group '{}'. Available dependency groups: {}; optional dependency groups: {}".format(
                    name,
                    ", ".join(sorted(dependency_groups)),
                    ", ".join(sorted(optional_dependencies)),
                ))
                continue

            specific_testonly[key] = testonly
            selected[key] = None

    packages = {}
    for key in selected:
        testonly = _is_testonly(
            key,
            specific_testonly = specific_testonly,
            global_testonly = global_testonly,
            optional_default_testonly = optional_default_testonly,
            group_default_testonly = group_default_testonly,
        )
        for req in _requirements_for(
            key,
            pyproject = pyproject,
            optional_dependencies = optional_dependencies,
            _fail = _fail,
        ):
            name = requirement(req).name_
            if not name:
                continue
            if name not in packages:
                packages[name] = testonly
            elif not testonly:
                # A package reachable from both testonly and non-testonly
                # selectors stays non-testonly.
                packages[name] = False

    return struct(
        packages = sorted(packages),
        testonly_packages = sorted([
            name
            for name, testonly in packages.items()
            if testonly
        ]),
        transitive = transitive,
        transitive_testonly = transitive_testonly,
    )

def dependency_graph_from_uv_lock(module_ctx, uv_lock):
    """Read the package dependency graph from a uv.lock file.

    Args:
        module_ctx: {type}`module_ctx` module context.
        uv_lock: {type}`Label | str` the uv.lock file to read.

    Returns:
        {type}`dict[str, list[str]]` normalized package names mapped to their
        normalized direct dependencies.
    """
    data = toml.decode(module_ctx.read(module_ctx.path(uv_lock), watch = "yes"))
    graph = {}
    for pkg in data.get("package", []):
        name = normalize_name(pkg["name"])
        deps = graph.setdefault(name, {})

        dependencies = [pkg.get("dependencies") or []]
        for optional_deps in (pkg.get("optional-dependencies") or {}).values():
            dependencies.append(optional_deps)
        for dev_deps in (pkg.get("dev-dependencies") or {}).values():
            dependencies.append(dev_deps)

        for dep_list in dependencies:
            for dep in dep_list:
                dep_name = dep.get("name")
                if dep_name:
                    deps[normalize_name(dep_name)] = None

    return {
        name: sorted(deps)
        for name, deps in graph.items()
    }

def merge_dependency_graphs(graphs):
    """Merge multiple dependency graphs.

    Args:
        graphs: {type}`list[dict[str, list[str]]]` the graphs to merge.

    Returns:
        {type}`dict[str, list[str]]` the merged graph.
    """
    merged = {}
    for graph in graphs:
        for name, deps in graph.items():
            merged.setdefault(name, {}).update({
                dep: None
                for dep in deps
            })

    return {
        name: sorted(deps)
        for name, deps in merged.items()
    }

def testonly_packages_from_graph(packages, roots, testonly_roots, graph):
    """Find the packages reachable only from testonly roots.

    Args:
        packages: {type}`list[str]` the normalized packages to classify.
        roots: {type}`list[str]` the normalized directly selected packages.
        testonly_roots: {type}`list[str]` the normalized testonly roots.
        graph: {type}`dict[str, list[str]]` the normalized dependency graph.

    Returns:
        {type}`list[str]` the sorted packages that are reachable from a
        testonly root but not from any non-testonly root.
    """
    testonly_roots = {
        name: None
        for name in testonly_roots
    }
    non_testonly_roots = [
        name
        for name in roots
        if name not in testonly_roots
    ]

    reachable_from_testonly = _reachable(graph, sorted(testonly_roots))
    reachable_from_non_testonly = _reachable(graph, non_testonly_roots)

    return sorted([
        name
        for name in packages
        if name in reachable_from_testonly and name not in reachable_from_non_testonly
    ])

def _parse_spec(raw_spec, _fail):
    spec = raw_spec.strip()
    if ";" not in spec:
        return struct(base = spec, testonly = False)

    base, _, modifier = spec.partition(";")
    if modifier != "testonly":
        _fail("Invalid dependency group specifier '{}': the only supported modifier is 'testonly'".format(raw_spec))
        return None

    return struct(base = base.strip(), testonly = True)

def _is_testonly(
        key,
        *,
        specific_testonly,
        global_testonly,
        optional_default_testonly,
        group_default_testonly):
    if key in specific_testonly:
        return specific_testonly[key]
    if key.startswith("optional:") and optional_default_testonly != None:
        return optional_default_testonly
    if key.startswith("group:") and group_default_testonly != None:
        return group_default_testonly
    return global_testonly

def _requirements_for(key, *, pyproject, optional_dependencies, _fail):
    if key == "default":
        return pyproject.dependencies
    elif key.startswith("optional:"):
        return optional_dependencies[key[len("optional:"):]]
    else:
        return resolve_dependency_groups(pyproject, [key], _fail = _fail)

def _reachable(graph, roots):
    seen = {
        root: None
        for root in roots
    }
    stack = list(roots)

    edge_count = 0
    for deps in graph.values():
        edge_count += len(deps)

    # Each node is pushed at most once and each edge is visited at most once.
    for _ in range(len(graph) + edge_count + 1):
        if not stack:
            break

        node = stack.pop()
        for dep in graph.get(node, []):
            if dep not in seen:
                seen[dep] = None
                stack.append(dep)

    return seen
