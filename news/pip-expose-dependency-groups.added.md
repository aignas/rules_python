(pypi) Added the {obj}`pip.expose` tag to create a venv repository from a
concrete hub using `pyproject.toml` dependency groups, including wildcard,
transitive, and testonly selectors. By default it exposes every package listed
in `pyproject.toml` without transitive packages; when no `pyproject.toml` is
configured it exposes all hub packages.
