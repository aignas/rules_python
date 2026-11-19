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

{attr}`pip.override.tags` adds tags to the targets of the package, e.g. to
avoid building it remotely.

```starlark
pip.override(
    package = "foo",
    hub_name = "my_deps",
    ignore_dependencies = ["bar"],
    extra_dependencies = ["baz[socks]; sys_platform == 'linux'"],
    tags = ["no-remote"],
)
```
