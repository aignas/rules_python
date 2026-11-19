(pypi) A lock file with more than one entry of a package for the same platform,
e.g. with the uv `[tool.uv] conflicts` setting, now fails with an error that
explains the cause and suggests a separate hub for each conflicting group.
