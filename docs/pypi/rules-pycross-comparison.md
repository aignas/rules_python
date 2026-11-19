:::{default-domain} bzl
:::

(rules-pycross-comparison)=
# Migrating from rules_pycross

[rules_pycross] and `rules_python` both turn a Python lock file into Bazel
targets. This page maps the concepts, APIs and features of rules_pycross 2.x
onto `rules_python`, so that you can migrate a project or use both side by
side.

The status words used in the tables are:

* **have**: `rules_python` has an equivalent today.
* **partial**: there is an equivalent with documented differences.
* **planned**: there is no equivalent yet, but one is being worked on.
* **gap**: there is no equivalent and none is planned yet.
* **out of scope**: the feature belongs to a different rule or project, e.g.
  rules that install a wheel in a build action.

[rules_pycross]: https://github.com/jvolkman/rules_pycross

## Concepts

| rules_pycross | rules_python | Notes |
|---|---|---|
| `uv`/`pdm`/`poetry`/`pylock` extensions | {obj}`pip.parse` | `pip.parse` reads `requirements.txt`, `uv.lock` and `pylock.toml` files. |
| `workspace` tag (one lock file) | one {obj}`pip.parse` per hub and Python version | The same `uv_lock` can be passed to several `pip.parse` calls. |
| `repo` tag (a set of packages) | a hub repository (`hub_name`) | A workspace with N repos becomes N hubs. |
| `repo(dependency_groups = ...)` | {obj}`pip.configure` | Requires {gh-pr}`4395`. The groups are read from `pyproject.toml`, not from the lock file. |
| `package` tag (per-package settings) | {obj}`pip.override`, {obj}`pip.whl_mods` | See [the package settings](#rules-pycross-package-attrs). |
| shared `<ws>__pkgs` repository | one repository per hub, Python version and file | The downloads are shared through the Bazel repository cache; sharing the extracted repositories is planned ({gh-pr}`3856`). |
| `pycross.configure_toolchains` | {obj}`python.toolchain`, {obj}`pip.default` | See [the platforms](#rules-pycross-platforms). |
| sdist build backends | `pip wheel` in the repository rule | See [building from source](#rules-pycross-build-from-source). |

## A worked example

This is an abridged `examples/bzlmod/MODULE.bazel` file from rules_pycross:

```starlark
pycross = use_extension("@rules_pycross//pycross/extensions:pycross.bzl", "pycross")
pycross.configure_toolchains(
    platforms = [
        "aarch64-apple-darwin",
        "aarch64-unknown-linux-gnu",
        "x86_64-unknown-linux-gnu",
        "x86_64-unknown-linux-musl",
    ],
    python_versions = ["3.14.2"],
)

uv = use_extension("@rules_pycross//pycross/extensions:uv.bzl", "uv")
uv.workspace(name = "uv_deps", lock_file = "//:uv.lock")
uv.repo(dependency_groups = ["default"], workspace = "uv_deps")
uv.package(name = "ipython", build_mode = "always", workspace = "uv_deps")
uv.package(name = "amqp-mock", install_exclude_globs = ["tests/**"], workspace = "uv_deps")
uv.package(name = "matplotlib", post_install_patches = ["//:matplotlib.patch"], workspace = "uv_deps")
use_repo(uv, "uv_deps")
```

The `rules_python` equivalent is below.

```starlark
python = use_extension("@rules_python//python/extensions:python.bzl", "python")
python.toolchain(is_default = True, python_version = "3.14.2")

pip = use_extension("@rules_python//python/extensions:pip.bzl", "pip")
pip.parse(
    hub_name = "uv_deps",
    pyproject_toml = "//:pyproject.toml",
    python_version = "3.14.2",
    uv_lock = "//:uv.lock",
    target_platforms = [
        "osx_aarch64",
        "linux_aarch64",
        "linux_x86_64",
        "linux_x86_64_musl",
    ],
    whl_modifications = {"@uv_deps_mods//:amqp_mock.json": "amqp_mock"},
)
pip.configure(hub_name = "uv_deps", dependency_groups = ["default"])

# build ipython from the sdist (with pip on the host)
pip.override(hub_name = "uv_deps", package = "ipython", build_mode = "always")

pip.whl_mods(
    hub_name = "uv_deps_mods",
    whl_name = "amqp_mock",
    srcs_exclude_glob = ["site-packages/tests/**"],
    data_exclude_glob = ["site-packages/tests/**"],
)

pip.override(
    hub_name = "uv_deps",
    package = "matplotlib",
    patches = ["//:matplotlib.patch"],
    patch_strip = 1,
)
use_repo(pip, "uv_deps", "uv_deps_mods")
```

The `BUILD.bazel` files keep using `@uv_deps//ipython`,
`@uv_deps//amqp_mock` and `@uv_deps//matplotlib`.

(rules-pycross-package-attrs)=
## Package settings

| `package` attribute | rules_python | Status |
|---|---|---|
| `build_mode` | {attr}`pip.override.build_mode` | have; the sdists are built with `pip` on the host |
| `build_target` | {attr}`pip.override.replace_with` with a target that installs the wheel, e.g. `pycross_wheel_library` | have |
| `build_backend`, `extra_build_tools`, `build_tools_repo`, `site_hooks`, `pre_build_patches` | the macro of {attr}`pip.override.experimental_sdist_builder` can implement them, e.g. with rules_pycross | have: extension point |
| `ignore_dependencies` | {attr}`pip.override.ignore_dependencies` | have |
| `extra_dependencies` | {attr}`pip.override.extra_dependencies`, which also accepts markers | have |
| `install_exclude_globs` | {attr}`pip.whl_mods.srcs_exclude_glob`, {attr}`pip.whl_mods.data_exclude_glob`, {attr}`pip.parse.pip_data_exclude` | have; the globs start with `site-packages/` |
| `post_install_patches` | {attr}`pip.override.package` with {attr}`pip.override.patches` | have; the wheel is patched before it is extracted |
| `site_paths`, `bin_paths`, `data_paths`, `include_paths` | a fixed `site-packages`, `bin`, `data`, `include` layout | not needed |
| `wheel_library_tags` | {attr}`pip.override.tags` | have |
| `precompile` | the {flag}`--precompile` flag for all packages | partial |

:::{note}
`rules_python` applies patches with `patch_strip = 0` by default and does not
strip the `a/` and `b/` prefixes of `git diff` patches. Use `patch_strip = 1`
for such patches.
:::

(rules-pycross-platforms)=
## Platforms and flags

`rules_python` selects the wheels for each platform when the module extension
runs. rules_pycross selects them in the analysis phase.

| rules_pycross platform | rules_python platform |
|---|---|
| `x86_64-unknown-linux-gnu` | `linux_x86_64` |
| `aarch64-unknown-linux-gnu` | `linux_aarch64` |
| `x86_64-unknown-linux-musl` | `linux_x86_64_musl` |
| `aarch64-apple-darwin` | `osx_aarch64` |
| `x86_64-apple-darwin` | `osx_x86_64` |
| `x86_64-pc-windows-msvc` | `windows_x86_64` |

Pass the platforms to {attr}`pip.parse.target_platforms`, or use `["*"]` for
all of them. You can define more platforms with {obj}`pip.default`.

| rules_pycross setting | rules_python |
|---|---|
| `configure_toolchains(python_versions)` | {obj}`python.toolchain` and {attr}`pip.parse.python_version` |
| `glibc_version`, `musl_version`, `macos_version` | {attr}`pip.default.whl_platform_tags` of a `platform`, e.g. `pip.default(platform = "linux_x86_64", whl_platform_tags = ["manylinux_*_x86_64"])`; the wheels are picked when the extension runs |
| `py_linux_libc` | the same flag, {flag}`--py_linux_libc` |
| `pep508_*` flags | {attr}`pip.default.env` when the extension runs, the {flag}`--pip_env_marker_config` flag in the build |
| `unavailable_package_mode` | {attr}`pip.parse.unavailable_package_mode` (`error` or `incompatible`) |

## Labels

| rules_pycross | rules_python |
|---|---|
| `@repo//pkg` | `@hub//pkg` |
| `@repo//pkg:[]`, `@repo//pkg:[extra]` | the same, requires {gh-pr}`4490` |
| `@repo//pkg:wheel` | `@hub//pkg:whl` |
| `@repo//pkg:sdist` | `@hub//pkg:sdist`, with a `uv.lock` or a `pylock.toml` |
| `@repo//pkg:dist_info` | `@hub//pkg:dist_info` |
| `@repo//pkg:data` | `@hub//pkg:data` |
| `@repo//:requirements.bzl` | `@hub//:requirements.bzl` |
| `@repo//:modules_mapping` | the Gazelle `modules_mapping` rule, which needs the wheels |

(rules-pycross-build-from-source)=
## Building from source

* If a package has a wheel for your platforms, `rules_python` uses it.
* If it only has an sdist, `rules_python` builds it with `pip wheel` on the
  host when the repository is fetched. The build is not hermetic, the build
  dependencies come from the index and not from the lock file, and the wheel
  is built for the host platform. Use {attr}`pip.override.build_mode` to
  forbid this (`never`) or to always build a package from its sdist
  (`always`) and {attr}`pip.parse.download_only` to forbid it for a hub.
* Replace a package with your own target, like `build_target` in
  rules_pycross, with {attr}`pip.override.replace_with`.
* {attr}`pip.override.experimental_sdist_builder` lets another ruleset, such as
  rules_pycross, build the sdists in build actions.

## Differences in behaviour

* `rules_python` creates a repository for every package in the lock file; the
  repositories are fetched only when used. {obj}`pip.configure` limits which
  packages the hub exposes, not which repositories exist.
* Packages that are not available on every target platform are left out of
  `all_requirements`. rules_pycross includes them for the platforms where they
  are available.
* Dependency cycles are grouped automatically with
  {attr}`pip.parse.experimental_automatic_requirement_cycles` or listed in
  {attr}`pip.parse.experimental_requirement_cycles`; a whole cycle is one
  group, without the marker-gated dependencies of rules_pycross.
* `rules_python` does not install wheels in build actions; it extracts them
  in repository rules.

## Using both side by side

The two rulesets create separate repositories, so they can be used in one
module. Do not depend on the same distribution from both in one binary.

## Appendix: feature matrix

| rules_pycross feature | rules_python | Status |
|---|---|---|
| `uv.lock` | {attr}`pip.parse.uv_lock` | have |
| uv workspace members, `projects`, `default-groups`, `extra_project_files` | the uv workspace members are used as the roots; {obj}`pip.configure` reads one `pyproject.toml` | partial |
| `pylock.toml` | {attr}`pip.parse.pylock` | have |
| `pdm.lock`, `poetry.lock` | export them to `pylock.toml` (`pdm export -f pylock`, `poetry-plugin-export` 1.10+) for {attr}`pip.parse.pylock` | have |
| dependency groups, `transitive` | {obj}`pip.configure`, requires {gh-pr}`4395` | have |
| `;testonly` | none, see {gh-pr}`4428` | planned |
| extras targets | requires {gh-pr}`4490` and {gh-pr}`4523` | have |
| `ignore_dependencies`, `extra_dependencies`, `wheel_library_tags` | {obj}`pip.override` | have |
| per-package `precompile` | global flags | partial |
| `post_install_patches` | {attr}`pip.override.package` | have |
| `install_exclude_globs` | {obj}`pip.whl_mods`, {attr}`pip.parse.pip_data_exclude` | have |
| `build_mode` | {attr}`pip.override.build_mode` | have |
| `build_target` | {attr}`pip.override.replace_with` | have |
| `:sdist` target | `@hub//pkg:sdist` (lock files only) | have |
| sdist builds in build actions, build backends, cross-compilation | {attr}`pip.override.experimental_sdist_builder` | have: extension point |
| Rust builds (`maturin`, `setuptools-rust`) | none | gap |
| `pre_build_patches` | the sdist builder macro | have: extension point |
| `local_wheels` | {attr}`pip.parse.local_wheels` with a {attr}`pip.parse.uv_lock` | have |
| Simple API for files without URLs, `netrc` | {attr}`pip.default.index_url`, {attr}`pip.default.netrc`, {attr}`pip.default.auth_patterns` | have |
| one file with two hashes | files are looked up by the lock file hash | have |
| glibc, musl and macOS version flags | {obj}`pip.default` platforms | partial |
| `unavailable_package_mode` | {attr}`pip.parse.unavailable_package_mode`; no `fail_at_execution` | partial |
| automatic dependency cycles | {attr}`pip.parse.experimental_automatic_requirement_cycles` | have |
| uv `conflicts` | an error; use a separate hub for each conflicting group | gap |
| per-repo transitions | none; the {flag}`--venv` flag selects a hub for the unified `@pypi` hub | gap |
| `modules_mapping` without wheels | Gazelle `modules_mapping` | partial |
| git sources | `pip` at fetch time, needs `git` on the host | have |
| `pycross_wheel_library`, `pycross_wheel_zipimport_library`, `pycross_wheel_transform`, `pycross_repaired_wheel` | wheels are extracted in repository rules | out of scope |
| `pycross_wheel_cc_import`, `pycross_wheel_headers` | see [the headers how-to](../howto/pypi-headers) | have |
| `dist_info`, entry points, `venvs_site_packages`, namespace packages, free-threading | the same | have |
| reproducible repositories | the wheel repositories; not the sdist builds | partial |
