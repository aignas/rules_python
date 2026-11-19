""

load("@rules_testing//lib:test_suite.bzl", "test_suite")
load("//python/private/pypi:cycles.bzl", "automatic_requirement_cycles", "pylock_graph", "strongly_connected_components", "uv_lock_graph")  # buildifier: disable=bzl-visibility

_tests = []

def _test_scc(env):
    env.expect.that_collection(strongly_connected_components({
        "a": ["b"],
        "b": ["c", "missing"],
        "c": ["a"],
        "d": ["d"],  # a self loop is not a group
        "e": ["f"],
        "f": ["g"],
        "g": ["f", "e"],
        "h": ["a"],
    })).contains_exactly([
        ["a", "b", "c"],
        ["e", "f", "g"],
    ])

    # A long chain does not need recursion
    chain = {"n{}".format(i): ["n{}".format(i + 1)] for i in range(500)}
    chain["n500"] = ["n0"]
    got = strongly_connected_components(chain)
    env.expect.that_int(len(got)).equals(1)
    env.expect.that_int(len(got[0])).equals(501)

_tests.append(_test_scc)

def _test_graphs(env):
    env.expect.that_dict(uv_lock_graph({"package": [
        # The workspace members are not in the hub
        {"dependencies": [{"name": "sphinx"}], "name": "my-project", "source": {"virtual": "."}},
        {
            "dependencies": [{"name": "sphinxcontrib-serializinghtml"}, {"name": "my-project"}],
            # The development dependencies are not used
            "dev-dependencies": {"dev": [{"name": "bar"}]},
            "name": "Sphinx",
            "optional-dependencies": {"Docs": [{"extra": ["bar"], "name": "Foo"}]},
        },
        {"dependencies": [{"name": "sphinx"}], "name": "sphinxcontrib-serializinghtml"},
    ]})).contains_exactly({
        "sphinx": ["sphinxcontrib_serializinghtml"],
        "sphinx[docs]": ["sphinx", "foo", "foo[bar]"],
        "sphinxcontrib_serializinghtml": ["sphinx"],
    })
    env.expect.that_dict(pylock_graph({"packages": [
        {"dependencies": [{"name": "b"}, {"url": "https://example.org/x.whl"}], "name": "a"},
        {"name": "b"},
        {"directory": {"path": "."}, "name": "my-project"},
    ]})).contains_exactly({
        "a": ["b"],
        "b": [],
    })

_tests.append(_test_graphs)

def _test_automatic_requirement_cycles(env):
    graphs = [
        {"a": ["b"], "b": ["a"], "x": ["y"], "y": []},
        # The graphs of the other lock files are merged
        {"p": ["q"], "q": ["p", "r"], "r": ["q"], "x": ["y"], "y": ["x"]},
    ]

    env.expect.that_dict(automatic_requirement_cycles(graphs)).contains_exactly({
        "auto_a": ["a", "b"],
        "auto_p": ["p", "q", "r"],
        "auto_x": ["x", "y"],
    })

    # The user groups take in the overlapping cycles. The members are matched
    # exactly, so `p` is not the same as `p[extra]`.
    env.expect.that_dict(automatic_requirement_cycles(graphs, {
        "mine": ["P[extra]", "z"],
        "other": ["r"],
        "third": ["q"],
    })).contains_exactly({
        "auto_a": ["a", "b"],
        "auto_x": ["x", "y"],
        "mine": ["p[extra]", "z"],
        "other": ["r", "q", "p"],
    })

    # A cycle through an extra groups the extra
    env.expect.that_dict(automatic_requirement_cycles([
        {"a": [], "a[x]": ["a", "b"], "b": ["a[x]"]},
    ])).contains_exactly({
        "auto_a_x": ["a[x]", "b"],
    })

_tests.append(_test_automatic_requirement_cycles)

def cycles_test_suite(name):
    """Create the test suite.

    Args:
        name: the name of the test suite
    """
    test_suite(name = name, basic_tests = _tests)
