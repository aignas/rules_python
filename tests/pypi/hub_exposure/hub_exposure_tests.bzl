"""hub_exposure tests"""

load("@rules_testing//lib:test_suite.bzl", "test_suite")
load("//python/private/pypi:hub_exposure.bzl", "hub_exposure")  # buildifier: disable=bzl-visibility
load("//tests/support/mocks:mocks.bzl", "mocks")

_tests = []

_PYPROJECT = """\
[project]
dependencies = ["simple"]

[dependency-groups]
dev = ["other-pkg"]
test = ["simple", "not-in-hub"]
"""

_UV_LOCK = """\
[[package]]
name = "simple"
dependencies = [{name = "transitive-pkg"}]

[[package]]
name = "other-pkg"
dependencies = [{name = "simple"}]
"""

def _hub(*, module_name = "root", pyproject = None, uv_locks = []):
    return struct(
        module_name = module_name,
        pyproject = pyproject,
        uv_locks = uv_locks,
        packages = ["other_pkg", "simple", "transitive_pkg"],
        exposed_packages = ["other_pkg", "simple"],
    )

def _configure(hub_name = "hub", venv = "", dependency_groups = ["*"], pyproject_toml = None):
    return mocks.tag(
        hub_name = hub_name,
        venv = venv,
        dependency_groups = dependency_groups,
        pyproject_toml = pyproject_toml,
    )

def _module(name = "root", is_root = True, configure = []):
    return mocks.module(name = name, is_root = is_root, configure = configure)

def _exposure(*modules, hubs = None, default_pyproject = None):
    failures = []
    got = hub_exposure(
        mocks.mctx(
            modules = list(modules),
            mock_files = {
                "other.toml": "[project]\ndependencies = [\"other-pkg\"]\n",
                "pyproject.toml": _PYPROJECT,
                "python_only.toml": "[project]\nrequires-python = \"==3.11.1\"\n",
                "uv.lock": _UV_LOCK,
            },
        ),
        hubs = hubs or {"hub": _hub()},
        default_pyproject = default_pyproject,
        _fail = failures.append,
    )
    if got == None:
        return failures
    return {
        name: (info.hub, info.packages)
        for name, info in got.items()
    }

def _test_default_exposure(env):
    # Without a pyproject.toml the hub is left alone.
    env.expect.that_dict(_exposure(_module())).contains_exactly({})

    # pip.default(pyproject_toml) does not change the hub by default.
    env.expect.that_dict(_exposure(_module(), default_pyproject = "pyproject.toml")).contains_exactly({})

    got = _exposure(_module(), hubs = {"hub": _hub(pyproject = "pyproject.toml")})
    env.expect.that_dict(got).contains_exactly({
        "hub": ("hub", {"other_pkg": False, "simple": False}),
    })

    # A pyproject.toml without dependencies does not filter the hub.
    got = _exposure(_module(), hubs = {"hub": _hub(pyproject = "python_only.toml")})
    env.expect.that_dict(got).contains_exactly({})

_tests.append(_test_default_exposure)

def _test_venvs(env):
    got = _exposure(
        _module(configure = [
            _configure(venv = "dev", dependency_groups = ["group:dev"]),
            _configure(venv = "test", dependency_groups = ["default", "test;testonly"]),
            _configure(venv = "union", dependency_groups = ["default"]),
            _configure(venv = "union", dependency_groups = ["dev;testonly"]),
        ]),
        hubs = {"hub": _hub(pyproject = "pyproject.toml")},
    )
    env.expect.that_dict(got).contains_exactly({
        "dev": ("hub", {"other_pkg": False}),
        "hub": ("hub", {"other_pkg": False, "simple": False}),
        "test": ("hub", {"simple": False}),
        "union": ("hub", {"other_pkg": True, "simple": False}),
    })

_tests.append(_test_venvs)

def _test_in_place(env):
    got = _exposure(
        _module(configure = [_configure(dependency_groups = ["dev"])]),
        hubs = {"hub": _hub(pyproject = "pyproject.toml")},
    )
    env.expect.that_dict(got).contains_exactly({
        "hub": ("hub", {"other_pkg": False}),
    })

    # The wheels depend on the aliases of the hub, so they can't be testonly.
    got = _exposure(
        _module(configure = [_configure(dependency_groups = ["dev;testonly"])]),
        hubs = {"hub": _hub(pyproject = "pyproject.toml")},
    )
    env.expect.that_collection(got).contains_exactly([
        "pip.configure() can only use ';testonly' when creating a venv, set 'venv' to a name different from the hub 'hub'",
    ])

_tests.append(_test_in_place)

def _test_in_place_ownership(env):
    hubs = {"hub": _hub(module_name = "owner", pyproject = "pyproject.toml")}

    # Only the owner or the root module can change the hub.
    got = _exposure(
        _module(),
        _module(name = "owner", is_root = False, configure = [_configure(dependency_groups = ["default"])]),
        _module(name = "other", is_root = False, configure = [_configure(dependency_groups = ["dev"])]),
        hubs = hubs,
    )
    env.expect.that_dict(got).contains_exactly({"hub": ("hub", {"simple": False})})

    # The root module wins over the owner.
    got = _exposure(
        _module(configure = [_configure(dependency_groups = ["dev"])]),
        _module(name = "owner", is_root = False, configure = [_configure(dependency_groups = ["default"])]),
        hubs = hubs,
    )
    env.expect.that_dict(got).contains_exactly({"hub": ("hub", {"other_pkg": False})})

_tests.append(_test_in_place_ownership)

def _test_pyproject_precedence(env):
    # pip.configure > pip.parse > pip.default
    got = _exposure(
        _module(configure = [
            _configure(venv = "from_tag", pyproject_toml = "other.toml", dependency_groups = ["default"]),
            _configure(venv = "from_default", dependency_groups = ["default"]),
        ]),
        default_pyproject = "other.toml",
    )
    env.expect.that_dict(got).contains_exactly({
        "from_default": ("hub", {"other_pkg": False}),
        "from_tag": ("hub", {"other_pkg": False}),
    })

    got = _exposure(
        _module(configure = [_configure(venv = "from_parse", dependency_groups = ["default"])]),
        hubs = {"hub": _hub(pyproject = "pyproject.toml")},
        default_pyproject = "other.toml",
    )
    env.expect.that_dict(got).contains_exactly({
        "from_parse": ("hub", {"simple": False}),
        "hub": ("hub", {"other_pkg": False, "simple": False}),
    })

    # pip.default(pyproject_toml) is not used for the hubs of other modules.
    got = _exposure(
        _module(),
        _module(name = "dep", is_root = False, configure = [_configure(venv = "venv", dependency_groups = ["default"])]),
        hubs = {"hub": _hub(module_name = "dep")},
        default_pyproject = "other.toml",
    )
    env.expect.that_dict(got).contains_exactly({
        "venv": ("hub", {"other_pkg": False, "simple": False}),
    })

_tests.append(_test_pyproject_precedence)

def _test_no_pyproject(env):
    got = _exposure(_module(configure = [_configure(venv = "venv", dependency_groups = ["dev"])]))
    env.expect.that_dict(got).contains_exactly({
        "venv": ("hub", {"other_pkg": False, "simple": False}),
    })

_tests.append(_test_no_pyproject)

def _test_transitive(env):
    configure = [
        _configure(venv = "dev", dependency_groups = ["dev", "transitive"]),
        _configure(venv = "test", dependency_groups = ["dev", "test;testonly", "transitive"]),
        _configure(venv = "direct", dependency_groups = ["test;testonly"]),
    ]

    # Without a lock file, fall back to the packages exposed without a
    # pyproject.toml.
    got = _exposure(
        _module(configure = configure),
        hubs = {"hub": _hub(pyproject = "pyproject.toml")},
    )
    env.expect.that_dict(got).contains_exactly({
        "dev": ("hub", {"other_pkg": False, "simple": False}),
        "direct": ("hub", {"simple": True}),
        "hub": ("hub", {"other_pkg": False, "simple": False}),
        "test": ("hub", {"other_pkg": False, "simple": True}),
    })

    # With a lock file, only the dependencies are added and testonly is
    # derived from the dependency graph.
    got = _exposure(
        _module(configure = configure),
        hubs = {"hub": _hub(pyproject = "pyproject.toml", uv_locks = ["uv.lock"])},
    )
    env.expect.that_dict(got).contains_exactly({
        "dev": ("hub", {"other_pkg": False, "simple": False, "transitive_pkg": False}),
        "direct": ("hub", {"simple": True}),
        "hub": ("hub", {"other_pkg": False, "simple": False}),
        "test": ("hub", {"other_pkg": False, "simple": False, "transitive_pkg": False}),
    })

_tests.append(_test_transitive)

def _test_errors(env):
    for configure, want in [
        (_configure(hub_name = "missing"), "pip.configure() refers to unknown hub 'missing'. Available hubs: hub, other"),
        (_configure(venv = "other"), "pip.configure() venv 'other' conflicts with the existing hub of the same name"),
        (_configure(venv = "pypi"), "pip.configure() venv 'pypi' conflicts with the automatically generated unified hub"),
    ]:
        got = _exposure(_module(configure = [configure]), hubs = {"hub": _hub(), "other": _hub()})
        env.expect.that_collection(got).contains_exactly([want])

    got = _exposure(
        _module(configure = [
            _configure(venv = "venv"),
            _configure(hub_name = "other", venv = "venv"),
        ]),
        hubs = {"hub": _hub(), "other": _hub()},
    )
    env.expect.that_collection(got).contains_exactly([
        "pip.configure() venv 'venv' is used with both hub 'hub' and hub 'other'",
    ])

_tests.append(_test_errors)

def hub_exposure_test_suite(name):
    """Create the test suite.

    Args:
        name: the name of the test suite
    """
    test_suite(name = name, basic_tests = _tests)
