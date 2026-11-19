(pypi) The hub repositories now have a `:sdist` target for the packages that
have an sdist in the `uv.lock` or `pylock.toml`, e.g. `@pypi//foo:sdist`, which
is downloaded only when it is used (bzlmod only).
