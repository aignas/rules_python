:::{default-domain} bzl
:::

(pypi-override)=
# Per-package overrides

The {obj}`pip.override` tag class changes how the packages of a hub are set up.

## Patching wheels

Sometimes the wheels have to be patched to:
* Workaround the lack of a standard `site-packages` layout ({gh-issue}`2156`).
* Include certain PRs of your choice on top of wheels and avoid building from sdist.

You can patch the wheels by using the {attr}`pip.override.patches` attribute.

To patch a wheel file, use {attr}`pip.override.file`:

```starlark
pip.override(
    file = "requests-2.25.1-py2.py3-none-any.whl",
    patch_strip = 1,
    patches = ["//patches:requests.patch"],
)
```

To patch all of the wheels of a package, e.g. the wheels for each platform or
the wheels that are built from an sdist, use {attr}`pip.override.package`. It
can be limited to a version (`foo@1.2.3`) and to a hub
({attr}`pip.override.hub_name`):

```starlark
pip.override(
    package = "matplotlib",
    hub_name = "my_deps",
    patch_strip = 1,
    patches = ["//patches:matplotlib.patch"],
)
```

:::{note}
The patches are applied with `patch_strip = 0` by default, so use
`patch_strip = 1` for patches created with `git diff`.
:::

## Changing the dependencies and tags

The dependencies of a package come from the `Requires-Dist` lines of its
`METADATA`. They can be changed with {attr}`pip.override.ignore_dependencies`,
e.g. to drop an optional dependency that is listed as a required one, and
{attr}`pip.override.extra_dependencies`, e.g. to add a missing dependency. The
extra dependencies are PEP 508 requirements, so they can have extras and
markers. Both need to refer to packages in the same hub.

{attr}`pip.override.tags` adds tags to the generated `py_library` targets of
the package.

```starlark
pip.override(
    package = "foo",
    hub_name = "my_deps",
    ignore_dependencies = ["bar"],
    extra_dependencies = ["baz[socks]; sys_platform == 'linux'"],
    tags = ["no-remote"],
)
```

## Building from sdists

By default a package uses a wheel for the platform if there is one and
otherwise builds the wheel from its sdist. {attr}`pip.override.build_mode`
changes that for a package, or for all of them with `package = "*"`:

| `build_mode` | wheel available | only an sdist |
|---|---|---|
| `auto` (default) | use the wheel | build the wheel from the sdist |
| `always` | build the wheel from the sdist | build the wheel from the sdist |
| `never` | use the wheel | the package is not available on the platform |

```starlark
pip.override(package = "*", build_mode = "never")
pip.override(package = "ipython", build_mode = "always")
```

A package uses the first build mode that is set for: the package in its hub,
`*` in its hub, the package in all hubs and `*` in all hubs.
{attr}`pip.parse.download_only` is the same as `never` for all of the packages
of a hub and it cannot be combined with `always`.

`never` drops a package that has no wheel on a platform and prints a warning
when the wheels are downloaded with the Bazel downloader. When `pip` downloads
the packages, e.g. without an index, it fails to download such a package.

:::{note}
The wheels are built with `pip` on the host when the repositories are fetched,
so the build is not hermetic and the built wheel is for the host platform.
:::

## Replacing a package

{attr}`pip.override.replace_with` replaces a package in the hub with your own
target on all of the platforms, e.g. a `py_library` with the sources of the
package or a library that installs a wheel that is built from source by
another ruleset. The hub targets, e.g. `@pypi//foo` and the extras targets,
keep working and the package is not downloaded. The `Requires-Dist` of the
package are not used, so add the dependencies on the other packages of the hub
with {attr}`pip.override.extra_dependencies`. The requested extras, e.g.
`@pypi//foo:[bar]`, are the package itself, and `@pypi//foo:whl` and
`@pypi//foo:dist_info` are empty unless {attr}`pip.override.replace_with_whl`
and {attr}`pip.override.replace_with_dist_info` are set. The targets need to be
visible to the hub repositories, e.g. `visibility = ["//visibility:public"]`:

```starlark
pip.override(
    package = "foo",
    replace_with = "//third_party/foo",
    replace_with_whl = "//third_party/foo:wheel",
    extra_dependencies = ["bar"],
)
```

For example, with rules_pycross the wheel of a package can be built from its
sdist with a build backend and installed with `pycross_wheel_library`, which
is then used as {attr}`pip.override.replace_with`.
