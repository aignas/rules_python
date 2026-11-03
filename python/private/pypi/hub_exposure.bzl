"""Compute the packages exposed by the hubs and venvs from `pip.configure`."""

load("@toml.bzl", "toml")
load("//python/private:pyproject_utils.bzl", "read_pyproject")
load(":dependency_groups.bzl", "select_dependency_groups", "uv_lock_graph", "with_dependencies")

def hub_exposure(module_ctx, *, hubs, default_pyproject = None, _fail = fail):
    """Compute the packages exposed by each hub and venv.

    A hub with a `pyproject.toml` exposes the packages listed in it. The
    `pip.configure` tags can override that or create venvs, which are
    filtered views of a hub.

    Args:
        module_ctx: {type}`module_ctx` the module context.
        hubs: {type}`dict[str, struct]` the hubs by name. Each struct has:
            * `module_name`: {type}`str` the module that created the hub.
            * `pyproject`: {type}`Label | None` from `pip.parse`.
            * `uv_locks`: {type}`list[Label]` from `pip.parse`.
            * `packages`: {type}`list[str]` the normalized names of all
              packages in the hub.
            * `exposed_packages`: {type}`list[str]` the packages to expose
              when there is no `pyproject.toml`.
        default_pyproject: {type}`Label | None` from `pip.default`, only used
            for the hubs of the root module.
        _fail: {type}`callable` the failure function, mainly for testing.

    Returns:
        {type}`dict[str, struct] | None` the hubs and venvs that have a custom
        exposure, mapped to a struct with:
          * `hub`: {type}`str` the hub providing the packages.
          * `packages`: {type}`dict[str, bool]` the exposed packages mapped
            to whether they are testonly.

        Hubs without a custom exposure are not included. Returns `None` on
        failure.
    """
    graphs = {}

    def select(hub, pyproject, specs):
        info = hubs[hub]
        if not pyproject:
            # TODO: Remove this fallback once pyproject.toml is mandatory.
            return {name: False for name in info.exposed_packages}

        selection = select_dependency_groups(read_pyproject(module_ctx, pyproject), specs, _fail = _fail)
        if info.uv_locks:
            if hub not in graphs:
                graphs[hub] = _merged_graph(module_ctx, info.uv_locks)
            packages = with_dependencies(selection.packages, graphs[hub], transitive = selection.transitive)
        elif selection.transitive:
            # Without a lock file the dependencies are unknown, so fall back to
            # the packages that would be exposed without a pyproject.toml.
            packages = {name: False for name in info.exposed_packages} | selection.packages
        else:
            packages = selection.packages

        return {
            name: testonly
            for name, testonly in packages.items()
            if name in info.packages
        }

    # The root module wins over the owner of the hub when both configure the
    # hub in place. Other modules can only create new venvs.
    root_configured = {
        tag.hub_name: None
        for mod in module_ctx.modules
        if mod.is_root
        for tag in mod.tags.configure
        if tag.venv in ("", tag.hub_name)
    }

    root_module = [mod.name for mod in module_ctx.modules if mod.is_root][:1]

    configured = {}
    for mod in module_ctx.modules:
        for tag in mod.tags.configure:
            hub = tag.hub_name
            venv = tag.venv or hub
            if hub not in hubs:
                _fail("pip.configure() refers to unknown hub '{}'. Available hubs: {}".format(
                    hub,
                    ", ".join(sorted(hubs)),
                ))
                return None
            if venv == hub and not mod.is_root and (mod.name != hubs[hub].module_name or hub in root_configured):
                continue
            if venv != hub and venv in hubs:
                _fail("pip.configure() venv '{}' conflicts with the existing hub of the same name".format(venv))
                return None
            if venv == hub and [d for d in tag.dependency_groups if d.endswith(";testonly")]:
                # The wheel repositories depend on the aliases of the hub, so
                # those must not be testonly.
                _fail("pip.configure() can only use ';testonly' when creating a venv, set 'venv' to a name different from the hub '{}'".format(hub))
                return None
            if venv == "pypi" and venv not in hubs:
                _fail("pip.configure() venv 'pypi' conflicts with the automatically generated unified hub")
                return None
            if venv in configured and configured[venv].hub != hub:
                _fail("pip.configure() venv '{}' is used with both hub '{}' and hub '{}'".format(
                    venv,
                    configured[venv].hub,
                    hub,
                ))
                return None

            packages = select(
                hub,
                tag.pyproject_toml or
                hubs[hub].pyproject or
                (default_pyproject if [hubs[hub].module_name] == root_module else None),
                tag.dependency_groups,
            )
            if venv in configured:
                # A package is testonly only if all tags agree.
                previous = configured[venv].packages
                packages = {
                    name: previous.get(name, True) and packages.get(name, True)
                    for name in previous | packages
                }
            configured[venv] = struct(hub = hub, packages = packages)

    for hub, info in hubs.items():
        if hub not in configured and info.pyproject:
            configured[hub] = struct(hub = hub, packages = select(hub, info.pyproject, ["*"]))

    return configured

def _merged_graph(module_ctx, uv_locks):
    graph = {}
    for uv_lock in uv_locks:
        lock = toml.decode(module_ctx.read(module_ctx.path(uv_lock), watch = "yes"))
        for name, deps in uv_lock_graph(lock).items():
            graph.setdefault(name, {}).update(deps)
    return graph
