:::{default-domain} bzl
:::

# Patching wheels

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
