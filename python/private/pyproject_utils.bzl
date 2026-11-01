"""Utilities for reading values from pyproject.toml."""

load("@toml.bzl", "toml")
load(":normalize_name.bzl", "normalize_name")
load(":version.bzl", "version")

def read_pyproject(module_ctx, pyproject):
    """Read a pyproject.toml file and return the relevant fields.

    The file is parsed with a pure-Starlark TOML decoder; no Python
    interpreter is required. The raw `requires-python` value is returned
    as-is so that callers can decide how to interpret it. Dependency values
    are returned as written so that callers can parse requirement strings
    with the same logic they use for lock files.

    Args:
        module_ctx: the module extension context (needs `path` and `read`).
        pyproject: {type}`Label` pointing at the pyproject.toml file.

    Returns:
        {type}`struct` with the attributes:
          * `requires_python`: {type}`str | None` the raw `requires-python`
            value (e.g. `"==3.13.9"`), or `None` if it is not set.
          * `dependencies`: {type}`list[str]` the `[project] dependencies`.
          * `optional_dependencies`: {type}`dict[str, list[str]]` the
            `[project.optional-dependencies]` table.
          * `dependency_groups`: {type}`dict[str, list]` the PEP 735
            `[dependency-groups]` table. Items are either requirement strings
            or `{include-group = "<name>"}` tables.
    """
    data = toml.decode(module_ctx.read(module_ctx.path(pyproject), watch = "yes"))
    project = data.get("project", {})
    return struct(
        requires_python = project.get("requires-python"),
        dependencies = project.get("dependencies") or [],
        optional_dependencies = project.get("optional-dependencies") or {},
        dependency_groups = data.get("dependency-groups") or {},
    )

def resolve_dependency_groups(pyproject, groups, _fail = fail):
    """Resolve dependency group specifiers to a list of requirement strings.

    Supported specifiers are:
      * `"default"`: the project's `[project] dependencies`.
      * `"optional:<name>"`: a `[project.optional-dependencies]` entry.
      * `"group:<name>"`: a PEP 735 `[dependency-groups]` entry.
      * `"<name>"`: a dependency group if one exists with that name, otherwise
        an optional dependency group.

    PEP 735 `include-group` entries are expanded iteratively and cycles are
    reported as errors.

    Args:
        pyproject: {type}`struct` returned by {obj}`read_pyproject`.
        groups: {type}`list[str]` the group specifiers to resolve.
        _fail: {type}`callable` the failure function, mainly for testing.

    Returns:
        {type}`list[str]` the requirement strings from the selected groups.
    """
    optional_dependencies = {
        normalize_name(name): deps
        for name, deps in pyproject.optional_dependencies.items()
    }
    dependency_groups = {
        normalize_name(name): items
        for name, items in pyproject.dependency_groups.items()
    }

    result = []
    for spec in groups:
        if spec == "default":
            result.extend(pyproject.dependencies)
        elif spec.startswith("optional:"):
            name = normalize_name(spec[len("optional:"):])
            if name not in optional_dependencies:
                _fail("Unknown optional dependency group '{}'. Available groups: {}".format(
                    name,
                    ", ".join(sorted(optional_dependencies)),
                ))
                continue
            result.extend(optional_dependencies[name])
        elif spec.startswith("group:"):
            name = normalize_name(spec[len("group:"):])
            result.extend(_resolve_dependency_group(name, dependency_groups, _fail))
        else:
            name = normalize_name(spec)
            if name in dependency_groups:
                result.extend(_resolve_dependency_group(name, dependency_groups, _fail))
            elif name in optional_dependencies:
                result.extend(optional_dependencies[name])
            else:
                _fail("Unknown dependency group '{}'. Available dependency groups: {}; optional dependency groups: {}".format(
                    name,
                    ", ".join(sorted(dependency_groups)),
                    ", ".join(sorted(optional_dependencies)),
                ))
    return result

def _resolve_dependency_group(name, dependency_groups, _fail):
    if name not in dependency_groups:
        _fail("Unknown dependency group '{}'. Available dependency groups: {}".format(
            name,
            ", ".join(sorted(dependency_groups)),
        ))
        return []

    result = []

    # Each frame is [group_name, next_item_index, groups_on_path]. A group is
    # expanded at most once, so the number of steps is bounded by the total
    # number of items in all groups plus the number of groups.
    seen = {name: None}
    stack = [[name, 0, [name]]]
    max_steps = len(dependency_groups) + 1
    for items in dependency_groups.values():
        max_steps += len(items)
    for _ in range(max_steps):
        if not stack:
            break

        frame = stack[-1]
        items = dependency_groups[frame[0]]
        if frame[1] >= len(items):
            stack.pop()
            continue

        item = items[frame[1]]
        frame[1] += 1

        if type(item) == type(""):
            result.append(item)
        elif type(item) == type({}):
            include = item.get("include-group")
            if not include:
                _fail("Invalid item in dependency group '{}': expected an `include-group` table, got: {}".format(
                    frame[0],
                    item,
                ))
                continue

            include = normalize_name(include)
            if include not in dependency_groups:
                _fail("Unknown dependency group '{}' included from '{}'. Available dependency groups: {}".format(
                    include,
                    frame[0],
                    ", ".join(sorted(dependency_groups)),
                ))
                continue
            if include in frame[2]:
                _fail("Cyclic dependency group include: {} -> {}".format(
                    " -> ".join(frame[2]),
                    include,
                ))
                continue
            if include in seen:
                continue

            seen[include] = None
            stack.append([include, 0, frame[2] + [include]])
        else:
            _fail("Invalid item in dependency group '{}': {}".format(
                frame[0],
                item,
            ))

    return result

def version_from_requires_python(requires_python):
    """Derive a concrete Python version from a `requires-python` value.

    Currently only an exact `==X.Y.Z` specifier is supported. The value is
    validated and normalized via {obj}`//python/private:version.bzl` so that
    malformed input fails in a consistent way. Broader specifier support
    (e.g. `>=`, `X.Y`) can be layered on here in the future.

    Args:
        requires_python: {type}`str` the raw `requires-python` value.

    Returns:
        {type}`str` the normalized version string (e.g. `"3.13.9"`).
    """
    if not requires_python:
        fail("`requires-python` must be specified")

    if not requires_python.startswith("=="):
        fail("`requires-python` must pin an exact version with `==`, got: {}".format(requires_python))

    bare_version = requires_python[len("=="):].strip()

    # Parse strictly so malformed versions fail cleanly, then normalize.
    version.parse(bare_version, strict = True)
    return version.normalize(bare_version)
