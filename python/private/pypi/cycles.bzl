"""Find the dependency cycles in the lock files to group the packages automatically."""

load("//python/private:normalize_name.bzl", "normalize_name")
load(":labels.bzl", "group_member")

def _add_edge(graph, node, dep):
    edges = graph.setdefault(node, [])
    if dep not in edges:
        edges.append(dep)

def _dep_nodes(dep):
    """The nodes of a dependency entry, e.g. `foo` and `foo[bar]`."""
    name = normalize_name(dep["name"])
    extras = dep.get("extra", [])
    if type(extras) == type(""):
        extras = [extras]
    return [name] + [group_member("{}[{}]".format(name, e)) for e in extras]

def uv_lock_graph(uv_lock):
    """Get the dependency graph of a uv.lock file.

    The nodes are the packages, e.g. `foo`, and their extras, e.g. `foo[bar]`,
    like the targets of the hub. An extra depends on its package and on its
    optional dependencies. The development dependencies and the workspace
    members (the `virtual` and `editable` sources), which are not in the hub,
    are not used.

    Args:
        uv_lock: {type}`dict` the decoded uv.lock contents.

    Returns:
        {type}`dict[str, list[str]]` the dependencies of each node.
    """
    roots = {
        normalize_name(pkg["name"]): None
        for pkg in uv_lock.get("package", [])
        if "virtual" in pkg.get("source", {}) or "editable" in pkg.get("source", {})
    }
    graph = {}
    for pkg in uv_lock.get("package", []):
        name = normalize_name(pkg["name"])
        if name in roots:
            continue
        graph.setdefault(name, [])
        for dep in pkg.get("dependencies", []):
            if normalize_name(dep["name"]) in roots:
                continue
            for node in _dep_nodes(dep):
                _add_edge(graph, name, node)
        for extra, deps in pkg.get("optional-dependencies", {}).items():
            node = group_member("{}[{}]".format(name, extra))
            _add_edge(graph, node, name)
            for dep in deps:
                if normalize_name(dep["name"]) in roots:
                    continue
                for dep_node in _dep_nodes(dep):
                    _add_edge(graph, node, dep_node)
    return graph

def pylock_graph(pylock):
    """Get the dependency graph of a pylock.toml file, if it records one.

    Args:
        pylock: {type}`dict` the decoded pylock.toml contents.

    Returns:
        {type}`dict[str, list[str]]` the normalized dependency names of each
        normalized package name.
    """
    graph = {}
    for pkg in pylock.get("packages", []):
        if "directory" in pkg:
            continue
        name = normalize_name(pkg["name"])
        graph.setdefault(name, [])
        for dep in pkg.get("dependencies", []):
            if "name" not in dep:
                continue
            _add_edge(graph, name, normalize_name(dep["name"]))
    return graph

def strongly_connected_components(graph):
    """Find the strongly connected components with Tarjan's algorithm.

    The algorithm is iterative, because Starlark does not support recursion.

    Args:
        graph: {type}`dict[str, list[str]]` the edges of each node.

    Returns:
        {type}`list[list[str]]` the sorted components with more than one node,
        sorted by their first node.
    """
    index = {}
    low = {}
    on_stack = {}
    stack = []
    components = []
    counter = 0

    # Each node is visited at most once and each edge is followed at most
    # once, so this is enough iterations.
    max_steps = 1
    for edges in graph.values():
        max_steps += 2 * (1 + len(edges))

    for root in sorted(graph):
        if root in index:
            continue

        # The work stack has (node, next edge index) items.
        work = [(root, 0)]
        index[root] = counter
        low[root] = counter
        counter += 1
        stack.append(root)
        on_stack[root] = True

        for _ in range(max_steps):
            if not work:
                break
            node, i = work[-1]
            edges = graph.get(node, [])
            if i < len(edges):
                work[-1] = (node, i + 1)
                dep = edges[i]
                if dep not in graph:
                    continue
                if dep not in index:
                    index[dep] = counter
                    low[dep] = counter
                    counter += 1
                    stack.append(dep)
                    on_stack[dep] = True
                    work.append((dep, 0))
                elif on_stack.get(dep):
                    low[node] = min(low[node], index[dep])
                continue

            work.pop()
            if work:
                parent = work[-1][0]
                low[parent] = min(low[parent], low[node])

            if low[node] == index[node]:
                component = []
                for _ in range(len(stack)):
                    member = stack.pop()
                    on_stack[member] = False
                    component.append(member)
                    if member == node:
                        break
                if len(component) > 1:
                    components.append(sorted(component))

        if work:
            fail("BUG: the strongly connected components were not found in {} steps".format(max_steps))

    return sorted(components)

def automatic_requirement_cycles(graphs, requirement_cycles = {}):
    """Group the packages that form dependency cycles.

    Args:
        graphs: {type}`list[dict[str, list[str]]]` the dependency graphs, e.g.
            one for each lock file of a hub, which are merged.
        requirement_cycles: {type}`dict[str, list[str]]` the groups that the
            user defined, which take in the automatic groups that they
            overlap with.

    Returns:
        {type}`dict[str, list[str]]` the groups, the user groups and the
        `auto_<first member>` groups.
    """
    graph = {}
    for g in graphs:
        for name, edges in g.items():
            graph.setdefault(name, [])
            for dep in edges:
                _add_edge(graph, name, dep)

    ret = {
        name: [group_member(m) for m in members]
        for name, members in requirement_cycles.items()
    }
    group_by_member = {
        member: name
        for name, members in ret.items()
        for member in members
    }
    for component in strongly_connected_components(graph):
        user_groups = sorted({
            group_by_member[m]: None
            for m in component
            if m in group_by_member
        })
        if not user_groups:
            name = "auto_" + component[0].replace("[", "_").replace("]", "")
            if name in ret:
                fail("The automatic group '{}' clashes with a group in 'experimental_requirement_cycles'".format(name))
            ret[name] = component
            continue

        # A cycle needs to be in a single group, so the first user group takes
        # in the cycle and the other user groups that it overlaps with.
        target = ret[user_groups[0]]
        for other in user_groups[1:]:
            target.extend([m for m in ret.pop(other) if m not in target])
        for m in component:
            if m not in target:
                target.append(m)
        for m in target:
            group_by_member[m] = user_groups[0]

    return ret
