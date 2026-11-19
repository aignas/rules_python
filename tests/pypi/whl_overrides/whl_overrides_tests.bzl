""

load("@rules_testing//lib:test_suite.bzl", "test_suite")
load("//python/private/pypi:whl_overrides.bzl", "parse_whl_overrides", "unmatched_whl_overrides", "whl_overrides_for_hub")  # buildifier: disable=bzl-visibility

_tests = []

def _override(*, file = "", package = "", hub_name = "", patches = [], patch_strip = 0):
    return struct(
        file = file,
        hub_name = hub_name,
        package = package,
        patch_strip = patch_strip,
        patches = patches,
    )

def _mod(*overrides, is_root = True):
    return struct(
        is_root = is_root,
        tags = struct(override = list(overrides)),
    )

def _parse(*modules):
    failures = []
    got = parse_whl_overrides(list(modules), _fail = failures.append)
    return got, failures

def _encode(overrides):
    """Make the result comparable."""
    return {
        whl: {patch: json.decode(json.encode(args)) for patch, args in patches.items()}
        for whl, patches in overrides.items()
    }

def _test_file_and_package(env):
    got, failures = _parse(
        _mod(
            _override(file = "foo-1.0-py3-none-any.whl", patches = ["//:file.patch"], patch_strip = 1),
            _override(package = "Foo", patches = ["//:all.patch"]),
            _override(package = "foo@2.0", hub_name = "pypi", patches = ["//:all.patch", "//:v2.patch"]),
            _override(package = "bar", hub_name = "other", patches = ["//:bar.patch"]),
        ),
        # Overrides from other modules are ignored
        _mod(_override(package = "baz", patches = ["//:baz.patch"]), is_root = False),
    )
    env.expect.that_collection(failures).contains_exactly([])

    env.expect.that_dict(_encode(whl_overrides_for_hub(got, "pypi"))).contains_exactly({
        "foo": {
            "//:all.patch": {"patch_strip": 0, "versions": ["*", "2.0"], "whls": []},
            "//:file.patch": {"patch_strip": 1, "whls": ["foo-1.0-py3-none-any.whl"]},
            "//:v2.patch": {"patch_strip": 0, "versions": ["2.0"]},
        },
    })
    env.expect.that_dict(_encode(whl_overrides_for_hub(got, "other"))).contains_exactly({
        "bar": {
            "//:bar.patch": {"patch_strip": 0, "versions": ["*"]},
        },
        "foo": {
            "//:all.patch": {"patch_strip": 0, "versions": ["*"]},
            "//:file.patch": {"patch_strip": 1, "whls": ["foo-1.0-py3-none-any.whl"]},
        },
    })

    env.expect.that_collection(unmatched_whl_overrides(got, {
        "other": ["bar"],
        "pypi": ["foo"],
    })).contains_exactly([])
    env.expect.that_collection(unmatched_whl_overrides(got, {
        "other": ["foo"],
    })).contains_exactly([
        "pip.override(package = 'bar') does not match any package in hub 'other'",
        "pip.override(hub_name = 'pypi') refers to a hub that does not exist",
    ])

_tests.append(_test_file_and_package)

def _test_errors(env):
    for overrides, want in [
        ([_override(patches = ["//:a.patch"])], "pip.override needs exactly one of 'file' or 'package'"),
        ([_override(file = "foo-1.0-py3-none-any.whl", package = "foo")], "pip.override needs exactly one of 'file' or 'package'"),
        ([_override(file = "foo-1.0-py3-none-any.whl", hub_name = "pypi")], "does not support 'hub_name'"),
        ([_override(file = "foo-1.0.tar.gz")], "Only whl overrides are supported"),
        (
            [_override(package = "foo", patches = ["//:a.patch"]), _override(package = "foo", patches = ["//:b.patch"])],
            "Duplicate module overrides for package 'foo'",
        ),
        (
            [
                _override(package = "foo", patches = ["//:a.patch"]),
                _override(package = "foo@1.0", patches = ["//:a.patch"], patch_strip = 1),
            ],
            "The patch '//:a.patch' for package 'foo@1.0' is used with different 'patch_strip' values",
        ),
    ]:
        _, failures = _parse(_mod(*overrides))
        env.expect.where(overrides = overrides).that_int(len(failures)).equals(1)
        env.expect.that_str(failures[0]).contains(want)

    # The strip level of the same patch for a file and a package must match
    got, failures = _parse(_mod(
        _override(file = "foo-1.0-py3-none-any.whl", patches = ["//:a.patch"], patch_strip = 1),
        _override(package = "foo", patches = ["//:a.patch"]),
    ))
    env.expect.that_collection(failures).contains_exactly([])
    whl_overrides_for_hub(got, "pypi", _fail = failures.append)
    env.expect.that_collection(failures).contains_exactly([
        "The patch '//:a.patch' for package 'foo' is used with different 'patch_strip' values",
    ])

_tests.append(_test_errors)

def whl_overrides_test_suite(name):
    """Create the test suite.

    Args:
        name: the name of the test suite
    """
    test_suite(name = name, basic_tests = _tests)
