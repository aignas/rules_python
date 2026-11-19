(pypi) A lock file with more than one version of a package for the same
platform, e.g. with the uv `[tool.uv] conflicts` setting, now fails with an
error that explains the cause instead of only naming the conflicting
repositories.
