""

load("@rules_testing//lib:test_suite.bzl", "test_suite")
load("@toml.bzl", "toml")
load("//python/private:repo_utils.bzl", "repo_utils")  # buildifier: disable=bzl-visibility
load("//python/private/pypi:lock_model.bzl", "lock_requirements")  # buildifier: disable=bzl-visibility
load("//python/private/pypi:pep508_env.bzl", pep508_env = "env")  # buildifier: disable=bzl-visibility
load("//python/private/pypi:pylock.bzl", "pylock_entries")  # buildifier: disable=bzl-visibility

_tests = []

def _platform(os, arch, whl_platform_tags):
    return struct(
        env = pep508_env(python_version = "3.12.4", os = os, arch = arch),
        whl_abi_tags = ["cp312", "abi3", "none"],
        whl_platform_tags = whl_platform_tags + ["any"],
    )

_PLATFORMS = {
    "linux_x86_64": _platform("linux", "x86_64", ["manylinux_*_x86_64"]),
    "osx_aarch64": _platform("osx", "aarch64", ["macosx_*_arm64", "macosx_*_universal2"]),
}

_PYLOCK = """\
lock-version = "1.0"
created-by = "uv"
requires-python = ">=3.10"
extras = ["socks"]
default-groups = ["default"]
dependency-groups = ["dev"]

[[packages]]
name = "requests"
version = "2.32.3"
index = "https://pypi.org/simple"
sdist = { url = "https://files.pythonhosted.org/requests-2.32.3.tar.gz", upload-time = 2024-05-29T15:37:49Z, size = 131218, hashes = { sha256 = "deadbeef" } }
wheels = [{ url = "https://files.pythonhosted.org/requests-2.32.3-py3-none-any.whl", upload-time = 2024-05-29T15:37:47Z, size = 64928, hashes = { sha256 = "deadbaaf" } }]

[[packages]]
name = "pysocks"
version = "1.7.1"
marker = "'socks' in extras"
wheels = [{ name = "PySocks-1.7.1-py3-none-any.whl", url = "https://example.org/simple/pysocks/download", hashes = { sha256 = "deadb00f" } }]

[[packages]]
name = "pytest"
version = "8.0.0"
marker = "'test' in dependency_groups"
wheels = [{ url = "https://example.org/pytest-8.0.0-py3-none-any.whl", hashes = { sha256 = "deadb11f" } }]

[[packages]]
name = "uvloop"
version = "0.21.0"
marker = "sys_platform != 'win32' and 'dev' in dependency_groups"
requires-python = ">=3.8"
wheels = [
    { url = "https://example.org/uvloop-0.21.0-cp312-cp312-manylinux_2_17_x86_64.whl", hashes = { sha256 = "deadb22f" } },
    { url = "https://example.org/uvloop-0.21.0-cp312-cp312-macosx_10_13_universal2.whl", hashes = { sha256 = "deadb33f" } },
]

[[packages]]
name = "attrs"
version = "24.0"
marker = "'default' in dependency_groups"
requires-python = ">=3.8"
wheels = [{ url = "https://example.org/attrs-24.0-py3-none-any.whl?x=1#sha256=deadb44f", hashes = { sha256 = "deadb44f" } }]
"""

def _logger(failures):
    return repo_utils.logger(struct(getenv = {}.get), "unit-test", printer = lambda _, message: failures.append(message))

def _test_simple(env):
    failures = []
    lock = pylock_entries(
        toml.decode(_PYLOCK),
        all_platforms = sorted(_PLATFORMS),
        platforms = _PLATFORMS,
        logger = _logger(failures),
        _fail = failures.append,
    )
    env.expect.that_collection(failures).contains_exactly([])
    env.expect.that_collection(lock.platforms).contains_exactly(sorted(_PLATFORMS))
    env.expect.that_collection([(e.name, e.target_platforms) for e in lock.entries]).contains_exactly([
        ("requests", ["linux_x86_64", "osx_aarch64"]),
        ("pysocks", ["linux_x86_64", "osx_aarch64"]),
        ("pytest", []),
        ("uvloop", ["linux_x86_64", "osx_aarch64"]),
        ("attrs", ["linux_x86_64", "osx_aarch64"]),
    ])

    got = lock_requirements(
        lock.entries,
        all_platforms = lock.platforms,
        platforms = _PLATFORMS,
        logger = _logger(failures),
    )
    env.expect.that_collection([
        (r.name, r.index_url, r.is_exposed, [(s.requirement_line, s.filename, s.digest, s.target_platforms) for s in r.srcs])
        for r in got
    ]).contains_exactly([
        ("attrs", "", True, [("attrs==24.0", "attrs-24.0-py3-none-any.whl", "sha256:deadb44f", ["linux_x86_64", "osx_aarch64"])]),
        ("pysocks", "", True, [("pysocks==1.7.1", "PySocks-1.7.1-py3-none-any.whl", "sha256:deadb00f", ["linux_x86_64", "osx_aarch64"])]),
        ("pytest", "", False, []),
        ("requests", "https://pypi.org/simple/requests", True, [("requests==2.32.3", "requests-2.32.3-py3-none-any.whl", "sha256:deadbaaf", ["linux_x86_64", "osx_aarch64"])]),
        ("uvloop", "", True, [
            ("uvloop==0.21.0", "uvloop-0.21.0-cp312-cp312-manylinux_2_17_x86_64.whl", "sha256:deadb22f", ["linux_x86_64"]),
            ("uvloop==0.21.0", "uvloop-0.21.0-cp312-cp312-macosx_10_13_universal2.whl", "sha256:deadb33f", ["osx_aarch64"]),
        ]),
    ])

_tests.append(_test_simple)

def _test_errors(env):
    for contents, want in [
        ('lock-version = "2.0"', "Only the pylock.toml 'lock-version' 1.x is supported, got: '2.0'"),
        ('lock-version = "1.0"\nrequires-python = ">=3.13"', "The pylock.toml 'requires-python = \">=3.13\"' does not match the Python version 3.12.4 of the 'linux_x86_64' platform"),
        ('lock-version = "1.0"\n[[packages]]\nname = "foo"\nvcs = { type = "git", url = "https://example.org/foo.git", commit-id = "abc" }', "The pylock.toml package 'foo' has a 'vcs' source, which is not supported"),
        ('lock-version = "1.0"\n[[packages]]\nname = "foo"', "The pylock.toml package 'foo' has no 'version'"),
        ('lock-version = "1.0"\n[[packages]]\nname = "foo"\nversion = "1.0"\nrequires-python = "<3.12"', "The pylock.toml package 'foo' has 'requires-python = \"<3.12\"', which does not match the Python version 3.12.4 of the 'linux_x86_64' platform"),
    ]:
        failures = []
        pylock_entries(
            toml.decode(contents),
            all_platforms = sorted(_PLATFORMS),
            platforms = _PLATFORMS,
            logger = _logger(failures),
            _fail = failures.append,
        )
        env.expect.where(contents = contents).that_collection(failures).contains_exactly([want])

    # The platforms that do not match the environments are ignored
    failures = []
    lock = pylock_entries(
        toml.decode('lock-version = "1.0"\nenvironments = ["sys_platform == \'linux\'"]\n[[packages]]\nname = "foo"\nversion = "1.0"\nwheels = [{ url = "https://example.org/foo-1.0-py3-none-any.whl" }]'),
        all_platforms = sorted(_PLATFORMS),
        platforms = _PLATFORMS,
        logger = _logger(failures),
        _fail = failures.append,
    )
    env.expect.that_collection(lock.platforms).contains_exactly(["linux_x86_64"])
    env.expect.that_collection([e.target_platforms for e in lock.entries]).contains_exactly([["linux_x86_64"]])

    # The package is exposed on all of the platforms that the lock supports
    got = lock_requirements(lock.entries, all_platforms = lock.platforms, platforms = _PLATFORMS, logger = _logger(failures))
    env.expect.that_collection([r.is_exposed for r in got]).contains_exactly([True])
    env.expect.that_collection(failures).contains_exactly([
        "The pylock.toml 'environments' do not match the 'osx_aarch64' platform, ignoring it",
    ])

_tests.append(_test_errors)

def pylock_test_suite(name):
    """Create the test suite.

    Args:
        name: the name of the test suite
    """
    test_suite(name = name, basic_tests = _tests)
