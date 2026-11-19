"""Find the dependency cycles in the lock files to group the packages automatically."""

load("//python/private:normalize_name.bzl", "normalize_name")

def uv_lock_graph(uv_lock):
    """Get the dependency graph of a uv.lock file.

    The edges are the dependencies and the optional dependencies, because all
    of the extras are enabled; the development dependencies are not used.

    Args:
        uv_lock: {type}`dict` the decoded uv.lock contents.

    Returns:
        {type}`dict[str, list[str]]` the normalized dependency names of each
        normalized package name.
    """
    graph = {}
    for pkg in uv_lock.get("package", []):
        deps = list(pkg.get("dependencies", []))
        for group in pkg.get("optional-dependencies", {}).values():
            deps.extend(group)
        edges = graph.setdefault(normalize_name(pkg["name"]), [])
        for dep in deps:
            name = normalize_name(dep["name"])
            if name not in edges:
                edges.append(name)
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
        edges = graph.setdefault(normalize_name(pkg["name"]), [])
        for dep in pkg.get("dependencies", []):
            if "name" not in dep:
                continue
            name = normalize_name(dep["name"])
            if name not in edges:
                edges.append(name)
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
            merged = graph.setdefault(name, [])
            for dep in edges:
                if dep not in merged:
                    merged.append(dep)

    ret = {name: list(members) for name, members in requirement_cycles.items()}
    group_by_member = {
        normalize_name(member.partition("[")[0]): name
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
            ret["auto_" + component[0]] = component
            continue

        # The first user group takes in the cycle, the members of the other
        # overlapping user groups are moved there too.
        target = user_groups[0]
        for other in user_groups[1:]:
            ret[target].extend(ret.pop(other))
        for m in component:
            if group_by_member.get(m) == None:
                ret[target].append(m)
        for m in ret[target]:
            group_by_member[normalize_name(m.partition("[")[0])] = target

    return ret
