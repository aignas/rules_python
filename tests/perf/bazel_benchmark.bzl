"""A rule to measure the Starlark code with Bazel itself, see the README.md."""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("//python/private:version.bzl", "version")  # buildifier: disable=bzl-visibility
load("//python/private/pypi:pep508_evaluate.bzl", "evaluate", "parse")  # buildifier: disable=bzl-visibility

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

_LONG_MARKER = (
    "(python_full_version >= '3.12' and platform_machine == 'aarch64' and sys_platform == 'linux')" +
    " or (python_full_version >= '3.12' and platform_machine == 'x86_64' and sys_platform == 'linux')" +
    " or (python_full_version < '3.12' and platform_machine != 'aarch64'" +
    " and platform_machine != 'x86_64' and sys_platform == 'linux')" +
    " or sys_platform == 'darwin' or sys_platform == 'win32'"
)

_PARSED_LONG_MARKER = parse(_LONG_MARKER)

# A subset of the workloads from `workloads.py`.
WORKLOADS = {
    # keep sorted
    "evaluate_long_marker": lambda: evaluate(_LONG_MARKER, env = _ENV),
    "evaluate_long_marker_parsed": lambda: evaluate(_PARSED_LONG_MARKER, env = _ENV),
    "evaluate_python_version": lambda: evaluate("python_version >= '3.8'", env = _ENV),
    "evaluate_sys_platform": lambda: evaluate("sys_platform == 'win32'", env = _ENV),
    "noop": lambda: None,
    "parse_long_marker": lambda: parse(_LONG_MARKER),
    "version_parse_pre_release": lambda: version.parse("3.13.0rc1"),
    "version_parse_release": lambda: version.parse("3.11.4"),
}

def _bazel_benchmark_impl(ctx):
    workload = ctx.attr._workload[BuildSettingInfo].value
    if not workload:
        return []

    fn = WORKLOADS[workload]
    for _ in range(ctx.attr._iterations[BuildSettingInfo].value):
        fn()

    return []

bazel_benchmark = rule(
    implementation = _bazel_benchmark_impl,
    doc = "Runs the workload that is selected with the flags during the analysis.",
    attrs = {
        "_iterations": attr.label(default = ":iterations"),
        "_workload": attr.label(default = ":workload"),
    },
)
