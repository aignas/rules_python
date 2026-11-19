""

load("@rules_testing//lib:test_suite.bzl", "test_suite")
load("//python/private/pypi:lock_model.bzl", "lock_dist", "lock_entry", "lock_requirements")  # buildifier: disable=bzl-visibility

_tests = []

_PLATFORMS = {
    "linux_x86_64": struct(
        env = {"implementation_name": "cpython", "python_full_version": "3.13.0"},
        whl_abi_tags = ["cp313", "abi3"],
        whl_platform_tags = ["manylinux_*_x86_64"],
    ),
    "osx_aarch64": struct(
        env = {"implementation_name": "cpython", "python_full_version": "3.13.0"},
        whl_abi_tags = ["cp313", "abi3"],
        whl_platform_tags = ["macosx_*_arm64"],
    ),
}

def _requirements(entries):
    return lock_requirements(
        entries,
        all_platforms = sorted(_PLATFORMS),
        platforms = _PLATFORMS,
        logger = None,
    )

def _test_direct_requirement(env):
    got = _requirements([
        lock_entry(
            name = "foo",
            version = "1.0",
            target_platforms = ["linux_x86_64", "osx_aarch64"],
            extras = ["bar"],
            direct_requirement = "git+https://example.org/foo@abc",
        ),
        lock_entry(
            name = "baz",
            version = "2.0",
            target_platforms = ["linux_x86_64"],
            # A URL without a file name is still pinned to the version
            sdist = lock_dist(filename = "", url = "https://example.org/baz/", digest = ""),
        ),
    ])

    env.expect.that_collection([
        (r.name, r.is_exposed, [(s.requirement_line, s.target_platforms, s.url) for s in r.srcs])
        for r in got
    ]).contains_exactly([
        ("baz", False, [("baz==2.0", ["linux_x86_64"], "https://example.org/baz/")]),
        ("foo", True, [("foo[bar] @ git+https://example.org/foo@abc", ["linux_x86_64", "osx_aarch64"], "")]),
    ])

_tests.append(_test_direct_requirement)

def lock_model_test_suite(name):
    """Create the test suite.

    Args:
        name: the name of the test suite
    """
    test_suite(name = name, basic_tests = _tests)
