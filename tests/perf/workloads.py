"""The workloads that are measured by the benchmark and the steps test."""

import os

from tests.perf import starlark_shim

_ENV = {
    "extra": "foo",
    "implementation_name": "cpython",
    "implementation_version": "3.11.4",
    "os_name": "posix",
    "platform_machine": "x86_64",
    "platform_python_implementation": "CPython",
    "platform_release": "6.1.0",
    "platform_system": "Linux",
    "platform_version": "#1 SMP Debian",
    "python_full_version": "3.11.4",
    "python_version": "3.11",
    "sys_platform": "linux",
}

# This is what the universal lock files have for the packages that are only
# built for some of the platforms.
_LONG_MARKER = (
    "(python_full_version >= '3.12' and platform_machine == 'aarch64' and sys_platform == 'linux')"
    " or (python_full_version >= '3.12' and platform_machine == 'x86_64' and sys_platform == 'linux')"
    " or (python_full_version < '3.12' and platform_machine != 'aarch64'"
    " and platform_machine != 'x86_64' and sys_platform == 'linux')"
    " or sys_platform == 'darwin' or sys_platform == 'win32'"
)


def workloads(root=None):
    """Return the functions to measure.

    Args:
        root: the directory with the sources, defaults to finding them in the
            runfiles or the current directory.

    Returns:
        A dict of the workload names and the functions.
    """
    shim = starlark_shim.Shim(_resolver(root))
    version = shim.load("//python/private:version.bzl")["version"]
    pep508 = shim.load("//python/private/pypi:pep508_evaluate.bzl")
    evaluate = pep508["evaluate"]
    tokenize = pep508["tokenize"]

    v_3_11_4 = version.parse("3.11.4")
    v_3_8 = version.parse("3.8")
    v_3_11_prefix = version.parse("3.11.*")

    return {
        # keep sorted
        "evaluate: long marker": lambda: evaluate(_LONG_MARKER, env=_ENV),
        "evaluate: os_name == 'posix' and sys_platform == 'linux'": lambda: evaluate(
            "os_name == 'posix' and sys_platform == 'linux'", env=_ENV
        ),
        "evaluate: python_version < '3.11' and extra == 'dev' (non-strict)": lambda: (
            evaluate(
                "python_version < '3.11' and extra == 'dev'",
                env={"extra": "dev"},
                strict=False,
            )
        ),
        "evaluate: python_version >= '3.8'": lambda: evaluate(
            "python_version >= '3.8'", env=_ENV
        ),
        "evaluate: sys_platform == 'win32'": lambda: evaluate(
            "sys_platform == 'win32'", env=_ENV
        ),
        "tokenize: long marker": lambda: tokenize(_LONG_MARKER),
        "tokenize: python_version >= '3.8'": lambda: tokenize(
            "python_version >= '3.8'"
        ),
        "version.is_compatible(3.11.4, 3.8)": lambda: version.is_compatible(
            v_3_11_4, v_3_8
        ),
        "version.is_eq(3.11.4, 3.11.*)": lambda: version.is_eq(v_3_11_4, v_3_11_prefix),
        "version.is_ge(3.11.4, 3.8)": lambda: version.is_ge(v_3_11_4, v_3_8),
        "version.is_lt(3.11.4, 3.8)": lambda: version.is_lt(v_3_11_4, v_3_8),
        "version.key(3.11.4)": lambda: version.key(v_3_11_4),
        "version.normalize('2023.07.19')": lambda: version.normalize("2023.07.19"),
        "version.parse('#1 SMP Debian')": lambda: version.parse("#1 SMP Debian"),
        "version.parse('1!2.0.0rc1.post3.dev4+ubuntu.7')": lambda: version.parse(
            "1!2.0.0rc1.post3.dev4+ubuntu.7"
        ),
        "version.parse('3.11.*')": lambda: version.parse("3.11.*"),
        "version.parse('3.11.4')": lambda: version.parse("3.11.4"),
        "version.parse('3.13.0rc1')": lambda: version.parse("3.13.0rc1"),
    }


def _resolver(root):
    if root:
        return lambda path: os.path.join(root, path)

    if os.path.exists("python/private/version.bzl"):
        return lambda path: path

    from python.runfiles import runfiles

    rfiles = runfiles.Create()
    assert rfiles is not None, "Failed to create runfiles"

    def resolve(path):
        # The main repository is `_main` with bzlmod and `rules_python` without.
        for repo in ["_main", "rules_python"]:
            resolved = rfiles.Rlocation("{}/{}".format(repo, path))
            if resolved and os.path.exists(resolved):
                return resolved
        raise FileNotFoundError(path)

    return resolve
