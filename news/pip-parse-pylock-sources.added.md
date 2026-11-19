(pypi) The {attr}`pip.parse.pylock` attribute now supports the `vcs` and
`archive` sources of the `pylock.toml` packages, which are built by `pip`, and
ignores the `directory` sources, the local projects (bzlmod only).
