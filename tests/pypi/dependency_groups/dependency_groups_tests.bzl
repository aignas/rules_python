"""dependency_groups tests"""

load("@rules_testing//lib:test_suite.bzl", "test_suite")
load("//python/private/pypi:dependency_groups.bzl", "select_dependency_groups", "uv_lock_graph", "with_dependencies")  # buildifier: disable=bzl-visibility

_tests = []

_PYPROJECT = struct(
    name = "my-project",
    dependencies = ["main-pkg>=1.0"],
    optional_dependencies = {
        "Docs": ["docs-pkg"],
        "all": ["My_Project[docs, grpc]"],
        "grpc": ["grpc-pkg"],
    },
    dependency_groups = {
        "dev": ["dev-pkg", "shared-pkg", {"include-group": "Test"}],
        "test": ["test_pkg", "shared-pkg"],
    },
)

def _select(specs, pyproject = _PYPROJECT):
    failures = []
    got = select_dependency_groups(pyproject, specs, _fail = failures.append)
    return got, failures

def _test_select(env):
    for specs, want in [
        (["default"], ["main_pkg"]),
        (["optional:docs"], ["docs_pkg"]),
        (["group:test"], ["shared_pkg", "test_pkg"]),
        (["dev"], ["dev_pkg", "shared_pkg", "test_pkg"]),
        (["grpc"], ["grpc_pkg"]),
        (["all"], ["docs_pkg", "grpc_pkg"]),
        (["optional:*"], ["docs_pkg", "grpc_pkg"]),
        (["group:*"], ["dev_pkg", "shared_pkg", "test_pkg"]),
        (["*"], ["dev_pkg", "docs_pkg", "grpc_pkg", "main_pkg", "shared_pkg", "test_pkg"]),
    ]:
        got, failures = _select(specs)
        env.expect.that_collection(failures).contains_exactly([])
        env.expect.that_collection(sorted(got.packages)).contains_exactly(want).in_order()
        env.expect.that_bool(got.transitive).equals(False)

    got, _ = _select(["default", "transitive"])
    env.expect.that_dict(got.packages).contains_exactly({"main_pkg": False})
    env.expect.that_bool(got.transitive).equals(True)

_tests.append(_test_select)

def _test_select_testonly(env):
    for specs, want in [
        # shared-pkg is also in the non-testonly dev group
        (["group:dev", "group:test;testonly"], {"dev_pkg": False, "shared_pkg": False, "test_pkg": False}),
        (["default", "group:test;testonly"], {"main_pkg": False, "shared_pkg": True, "test_pkg": True}),
        # the last specifier wins
        (["*;testonly", "group:*"], {"dev_pkg": False, "docs_pkg": True, "grpc_pkg": True, "main_pkg": True, "shared_pkg": False, "test_pkg": False}),
        (["group:test;testonly", "*"], {"dev_pkg": False, "docs_pkg": False, "grpc_pkg": False, "main_pkg": False, "shared_pkg": False, "test_pkg": False}),
    ]:
        got, failures = _select(specs)
        env.expect.that_collection(failures).contains_exactly([])
        env.expect.that_dict(got.packages).contains_exactly(want)

_tests.append(_test_select_testonly)

def _test_select_errors(env):
    for specs, want in [
        (["missing"], "Unknown dependency group 'missing'. Available groups: default, group:dev, group:test, optional:all, optional:docs, optional:grpc"),
        (["default;foo"], "Invalid dependency group specifier 'default;foo': the only supported modifier is 'testonly'"),
        (["transitive;testonly"], "The 'transitive' specifier does not support the 'testonly' modifier"),
    ]:
        _, failures = _select(specs)
        env.expect.that_collection(failures).contains_exactly([want])

    _, failures = _select(["default"], pyproject = struct(
        name = None,
        dependencies = [],
        optional_dependencies = {},
        dependency_groups = {
            "a": [{"include-group": "b"}],
            "b": [{"include-group": "a"}],
            "c": ["foo"],
        },
    ))
    env.expect.that_collection(failures).contains_exactly(["Cyclic dependency group includes: a, b"])

    _, failures = _select(["default"], pyproject = struct(
        name = None,
        dependencies = [],
        optional_dependencies = {},
        dependency_groups = {"a": [{"include-group": "b"}]},
    ))
    env.expect.that_collection(failures).contains_exactly(["Unknown dependency group 'b' included from 'a'"])

_tests.append(_test_select_errors)

def _test_uv_lock_graph(env):
    got = uv_lock_graph({"package": [
        {"dependencies": [{"name": "Bar"}], "name": "Foo"},
        {"name": "bar", "optional-dependencies": {"extra": [{"name": "baz"}]}},
        {"dev-dependencies": {"test": [{"name": "pytest"}]}, "name": "my-project"},
        {"dependencies": [{"name": "qux"}], "name": "foo"},
    ]})
    env.expect.that_dict(got).contains_exactly({
        "bar": {"baz": None},
        "foo": {"bar": None, "qux": None},
        "my_project": {"pytest": None},
    })

_tests.append(_test_uv_lock_graph)

_GRAPH = {
    "prod": {"prod_only": None, "shared": None},
    "test": {"shared": None, "test_only": None},
    "test_only": {"prod": None},
}

def _test_with_dependencies(env):
    # A testonly package that a non-testonly package depends on is not testonly.
    got = with_dependencies({"prod": True, "shared": True, "test": False}, _GRAPH, transitive = False)
    env.expect.that_dict(got).contains_exactly({"prod": False, "shared": False, "test": False})

    got = with_dependencies({"prod": False, "test": True}, _GRAPH, transitive = True)
    env.expect.that_dict(got).contains_exactly({
        "prod": False,
        "prod_only": False,
        "shared": False,
        "test": True,
        "test_only": True,
    })

    got = with_dependencies({"prod": False}, _GRAPH, transitive = True)
    env.expect.that_dict(got).contains_exactly({"prod": False, "prod_only": False, "shared": False})

_tests.append(_test_with_dependencies)

def dependency_groups_test_suite(name):
    """Create the test suite.

    Args:
        name: the name of the test suite
    """
    test_suite(name = name, basic_tests = _tests)
