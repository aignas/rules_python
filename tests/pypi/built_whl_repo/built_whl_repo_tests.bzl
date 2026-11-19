""

load("@rules_testing//lib:test_suite.bzl", "test_suite")
load("//python/private/pypi:built_whl_repo.bzl", "render_built_whl_build")  # buildifier: disable=bzl-visibility

_tests = []

def _test_render(env):
    got = render_built_whl_build(
        builder = "@@rules_pycross+//pycross:rules_python.bzl",
        builder_symbol = "sdist_builder",
        sdist = "@pypi_foo_sdist_deadbeef_file//:foo-1.0.tar.gz",
        package_name = "foo",
        version = "1.0",
    )
    env.expect.that_str(got).equals("""load("@@rules_pycross+//pycross:rules_python.bzl", _sdist_builder = "sdist_builder")

package(default_visibility = ["//visibility:public"])

_sdist_builder(
    name = "srcs",
    sdist = "@pypi_foo_sdist_deadbeef_file//:foo-1.0.tar.gz",
    package_name = "foo",
    version = "1.0",
    whl_name = "whl_file",
    dist_info_name = "dist_info",
    visibility = ["//visibility:public"],
)

filegroup(
    name = "data",
    srcs = [],
)

filegroup(
    name = "extracted_whl_files",
    srcs = [],
)
""")

_tests.append(_test_render)

def built_whl_repo_test_suite(name):
    """Create the test suite.

    Args:
        name: the name of the test suite
    """
    test_suite(name = name, basic_tests = _tests)
