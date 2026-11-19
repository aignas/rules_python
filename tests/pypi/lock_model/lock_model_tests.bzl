""

load("@rules_testing//lib:test_suite.bzl", "test_suite")
load("//python/private:repo_utils.bzl", "repo_utils")  # buildifier: disable=bzl-visibility
load("//python/private/pypi:lock_model.bzl", "lock_dist", "lock_entry", "lock_requirements")  # buildifier: disable=bzl-visibility
load("//python/private/pypi:uv_lock.bzl", "uv_lock_entries")  # buildifier: disable=bzl-visibility

_tests = []

_PLATFORMS = {
    "linux_x86_64": struct(
        env = {"implementation_name": "cpython", "python_full_version": "3.13.0"},
        whl_abi_tags = ["cp313", "abi3", "none"],
        whl_platform_tags = ["manylinux_*_x86_64", "any"],
    ),
    "osx_aarch64": struct(
        env = {"implementation_name": "cpython", "python_full_version": "3.13.0"},
        whl_abi_tags = ["cp313", "abi3", "none"],
        whl_platform_tags = ["macosx_*_arm64", "any"],
    ),
}

def _requirements(entries):
    return lock_requirements(
        entries,
        all_platforms = sorted(_PLATFORMS),
        platforms = _PLATFORMS,
        logger = repo_utils.logger(struct(getenv = {}.get), "unit-test"),
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

def _test_local_wheels(env):
    failures = []
    got = uv_lock_entries(
        {"package": [
            {"name": "foo", "version": "1.0.0", "wheels": [{"url": "https://example.org/foo-1.0.0-py3-none-any.whl"}]},
            {"name": "bar", "version": "2.0"},
        ]},
        all_platforms = sorted(_PLATFORMS),
        platforms = _PLATFORMS,
        local_wheels = [
            Label("//:foo-1.0-py3-none-any.whl"),
            Label("//:bar-3.0-py3-none-any.whl"),
        ],
        _fail = failures.append,
    )

    env.expect.that_collection([(e.name, [w.file for w in e.local_wheels]) for e in got]).contains_exactly([
        ("foo", [str(Label("//:foo-1.0-py3-none-any.whl"))]),
        ("bar", []),
    ])
    env.expect.that_collection(failures).contains_exactly([
        "The local wheel '{}' does not match the version of any package in the lock file".format(Label("//:bar-3.0-py3-none-any.whl")),
    ])

    # The local wheel is preferred over the locked wheels
    reqs = _requirements(got)
    env.expect.that_collection([
        (s.filename, getattr(s, "whl_file", None))
        for r in reqs
        for s in r.srcs
    ]).contains_exactly([
        ("foo-1.0-py3-none-any.whl", str(Label("//:foo-1.0-py3-none-any.whl"))),
    ])

_tests.append(_test_local_wheels)

def _test_local_wheels_per_platform(env):
    failures = []
    entries = uv_lock_entries(
        {"package": [
            {"name": "foo", "version": "1.0", "wheels": [
                {"url": "https://example.org/foo-1.0-py3-none-any.whl"},
                # A `path` source has no URL and is ignored
                {"path": "dist/foo-1.0-cp313-cp313-manylinux_2_17_x86_64.whl"},
            ]},
        ]},
        all_platforms = sorted(_PLATFORMS),
        platforms = _PLATFORMS,
        # The label may be in a subdirectory of the package
        local_wheels = [Label("//:dist/foo-1.0-cp313-cp313-manylinux_2_17_x86_64.whl")],
        _fail = failures.append,
    )
    env.expect.that_collection(failures).contains_exactly([])

    # The local wheel is only used on the platforms that it supports
    env.expect.that_collection([
        (s.filename, s.target_platforms, getattr(s, "whl_file", None))
        for r in _requirements(entries)
        for s in r.srcs
    ]).contains_exactly([
        ("foo-1.0-cp313-cp313-manylinux_2_17_x86_64.whl", ["linux_x86_64"], str(Label("//:dist/foo-1.0-cp313-cp313-manylinux_2_17_x86_64.whl"))),
        ("foo-1.0-py3-none-any.whl", ["osx_aarch64"], None),
    ])

_tests.append(_test_local_wheels_per_platform)

def lock_model_test_suite(name):
    """Create the test suite.

    Args:
        name: the name of the test suite
    """
    test_suite(name = name, basic_tests = _tests)
