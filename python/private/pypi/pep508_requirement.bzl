"""This module is for parsing PEP508 requires-dist and requirements lines.
"""

load("@pypackaging.bzl", "pypackaging")

def requirement(spec):
    """Parse a PEP508 requirement line

    Args:
        spec: {type}`str` requirement line that will be parsed. The options
            of a `requirements.txt` line, e.g. `--hash`, are ignored.

    Returns:
        A struct with the information.
    """

    # The options are not a part of PEP 508.
    spec, _, _ = spec.partition(" --")

    head, semicolon, marker = spec.partition(";")
    name, at, url = head.partition("@")
    if at and "==" in name:
        # PEP 508 does not allow a version for the direct URL requirements,
        # but `name==version @ url` has always been accepted here, so that
        # the version of the distribution is known.
        name, _, _ = name.partition("==")
        spec = name + at + url + semicolon + marker

    req = pypackaging.requirements.parse(spec)

    return struct(
        name = req.name,
        name_ = req.name.replace("-", "_"),
        marker = req.marker_str or "",
        extras = [e.replace("-", "_") for e in req.extras],
    )
