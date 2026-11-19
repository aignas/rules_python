""

load("@rules_testing//lib:test_suite.bzl", "test_suite")
load("//python/private/pypi:whl_overrides.bzl", "build_mode_for_hub", "package_settings_for_hub", "parse_whl_overrides", "replacements_for_hub", "unmatched_whl_overrides", "whl_overrides_for_hub")  # buildifier: disable=bzl-visibility

_tests = []

def _override(
        *,
        file = "",
        package = "",
        hub_name = "",
        patches = [],
        patch_strip = 0,
        ignore_dependencies = [],
        extra_dependencies = [],
        tags = [],
        build_mode = "",
        replace_with = None,
        replace_with_whl = None,
        replace_with_dist_info = None):
    return struct(
        build_mode = build_mode,
        replace_with = replace_with,
        replace_with_dist_info = replace_with_dist_info,
        replace_with_whl = replace_with_whl,
        extra_dependencies = extra_dependencies,
        file = file,
        hub_name = hub_name,
        ignore_dependencies = ignore_dependencies,
        package = package,
        patch_strip = patch_strip,
        patches = patches,
        tags = tags,
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
            "//:all.patch": {"patch_strip": 0, "versions": ["*", "2.0"]},
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
        ([_override(file = "foo-1.0-py3-none-any.whl", hub_name = "pypi", patches = ["//:a.patch"])], "does not support 'hub_name'"),
        ([_override(file = "foo-1.0.tar.gz", patches = ["//:a.patch"])], "Only whl overrides are supported"),
        ([_override(file = "foo-1.0-py3-none-any.whl")], "needs 'patches'"),
        ([_override(file = "foo-1.0-py3-none-any.whl", patches = ["//:a.patch"], tags = ["a"])], "only supports 'patches'"),
        ([_override(package = "foo")], "does not set anything"),
        ([_override(package = "foo", ignore_dependencies = ["bar[x]"])], "ignore_dependencies needs the names of other packages, got: [\"bar[x]\"]"),
        ([_override(package = "foo", ignore_dependencies = ["Foo"])], "ignore_dependencies needs the names of other packages, got: [\"Foo\"]"),
        ([_override(package = "foo@1.0", tags = ["a"])], "cannot set 'ignore_dependencies', 'extra_dependencies' or 'tags' for a single version"),
        ([_override(package = "foo@", patches = ["//:a.patch"])], "needs to be a package name or '<name>@<version>'"),
        ([_override(package = "foo==1.0", patches = ["//:a.patch"])], "needs to be a package name or '<name>@<version>'"),
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
        "The patch '//:a.patch' for package 'foo' is used with different 'patch_strip' values, use a copy of the patch file",
    ])

_tests.append(_test_errors)

def _test_package_settings(env):
    got, failures = _parse(_mod(
        _override(package = "foo", ignore_dependencies = ["Bar"], tags = ["all"]),
        _override(package = "foo", hub_name = "pypi", extra_dependencies = ["baz[x]; sys_platform == 'linux'"]),
        _override(package = "qux", hub_name = "other", ignore_dependencies = ["missing"]),
    ))
    env.expect.that_collection(failures).contains_exactly([])

    # The hub settings replace the settings for all hubs field by field
    env.expect.that_dict(package_settings_for_hub(got, "pypi")).contains_exactly({
        "foo": {
            "extra_dependencies": ["baz[x]; sys_platform == 'linux'"],
            "extra_tags": ["all"],
            "ignore_dependencies": ["Bar"],
        },
    })
    env.expect.that_dict(package_settings_for_hub(got, "other")).contains_exactly({
        "foo": {
            "extra_dependencies": [],
            "extra_tags": ["all"],
            "ignore_dependencies": ["Bar"],
        },
        "qux": {
            "extra_dependencies": [],
            "extra_tags": [],
            "ignore_dependencies": ["missing"],
        },
    })

    env.expect.that_collection(unmatched_whl_overrides(got, {
        "other": ["foo", "bar", "qux"],
        "pypi": ["foo", "bar"],
    })).contains_exactly([
        "pip.override(package = 'foo').extra_dependencies refers to 'baz', which is not in hub 'pypi'",
        "pip.override(package = 'qux').ignore_dependencies refers to 'missing', which is not in hub 'other'",
    ])

_tests.append(_test_package_settings)

def _test_build_modes(env):
    got, failures = _parse(_mod(
        _override(package = "*", build_mode = "never"),
        _override(package = "foo", build_mode = "always"),
        _override(package = "bar", hub_name = "pypi", build_mode = "auto"),
        _override(package = "*", hub_name = "third", build_mode = "auto"),
    ))
    env.expect.that_collection(failures).contains_exactly([])

    # The hub settings take precedence over the settings for all hubs
    for hub, want in {
        "other": {"bar": "never", "baz": "never", "foo": "always"},
        "pypi": {"bar": "auto", "baz": "never", "foo": "always"},
        "third": {"bar": "auto", "baz": "auto", "foo": "auto"},
    }.items():
        build_mode = build_mode_for_hub(got, hub)
        env.expect.where(hub = hub).that_dict({
            name: build_mode(name)
            for name in want
        }).contains_exactly(want)
    env.expect.that_collection(unmatched_whl_overrides(got, {
        "pypi": ["foo"],
    })).contains_exactly([
        "pip.override(package = 'bar') does not match any package in hub 'pypi'",
        "pip.override(hub_name = 'third') refers to a hub that does not exist",
    ])

    for overrides, want in [
        ([_override(package = "*", patches = ["//:a.patch"])], "pip.override(package = '*') only supports 'build_mode'"),
        ([_override(package = "*@1.0", build_mode = "never")], "needs to be a package name or '<name>@<version>'"),
        ([_override(package = "foo@1.0", build_mode = "never")], "cannot set 'build_mode' for a single version"),
        ([_override(file = "foo-1.0-py3-none-any.whl", patches = ["//:a.patch"], build_mode = "never")], "only supports 'patches'"),
    ]:
        _, failures = _parse(_mod(*overrides))
        env.expect.where(overrides = overrides).that_int(len(failures)).equals(1)
        env.expect.that_str(failures[0]).contains(want)

_tests.append(_test_build_modes)

def _test_replacements(env):
    got, failures = _parse(_mod(
        _override(package = "foo", replace_with = Label("//:foo"), replace_with_whl = Label("//:foo.whl"), extra_dependencies = ["bar"]),
        _override(package = "baz", hub_name = "pypi", replace_with = Label("//:baz")),
    ))
    env.expect.that_collection(failures).contains_exactly([])
    env.expect.that_dict(replacements_for_hub(got, "pypi")).contains_exactly({
        "baz": struct(replace_with = str(Label("//:baz")), replace_with_dist_info = None, replace_with_whl = None),
        "foo": struct(replace_with = str(Label("//:foo")), replace_with_dist_info = None, replace_with_whl = str(Label("//:foo.whl"))),
    })
    env.expect.that_dict(package_settings_for_hub(got, "pypi")).contains_exactly({
        "foo": {"extra_dependencies": ["bar"], "extra_tags": [], "ignore_dependencies": []},
    })

    for overrides, want in [
        ([_override(package = "foo@1.0", replace_with = Label("//:foo"))], "needs a single package without a version"),
        ([_override(package = "foo", replace_with = Label("//:foo"), patches = ["//:a.patch"])], "cannot have 'patches' or 'build_mode'"),
        ([_override(package = "foo", replace_with_whl = Label("//:foo.whl"))], "needs 'replace_with' to set 'replace_with_whl' or 'replace_with_dist_info'"),
    ]:
        _, failures = _parse(_mod(*overrides))
        env.expect.where(overrides = overrides).that_int(len(failures)).equals(1)
        env.expect.that_str(failures[0]).contains(want)

_tests.append(_test_replacements)

def whl_overrides_test_suite(name):
    """Create the test suite.

    Args:
        name: the name of the test suite
    """
    test_suite(name = name, basic_tests = _tests)
