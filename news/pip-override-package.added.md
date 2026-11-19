(pypi) The {obj}`pip.override` tag class now accepts a
{attr}`pip.override.package` (optionally with a `@version`) instead of a wheel
{attr}`pip.override.file` to patch all of the wheels of a package, including
the wheels built from an sdist, and a {attr}`pip.override.hub_name` to limit it
to one hub (bzlmod only).
