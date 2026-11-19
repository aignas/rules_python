(pypi) The {attr}`pip.parse.pylock` attribute reads a `pylock.toml` (PEP 751)
lock file, e.g. exported by `uv`, `pdm` or `pip lock`, instead of the
requirements files (bzlmod only). The packages from `vcs`, `archive` and
`directory` sources are not supported yet
([#2787](https://github.com/bazel-contrib/rules_python/issues/2787)).
