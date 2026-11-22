"""A list of packages that this logical testdata hub repo contains."""

# The values are the extras that are requested in the hub, the `pkg` package
# does not provide the `nope` extra. The `optional` extra of `pkg` is not
# requested in the hub, but the `consumer` package depends on it.
packages = {
    "consumer": [],
    "optional_dep": [],
    "pkg": [
        "nope",
    ],
}

# The marker environments of the target platforms of the hub. The `pkg`
# package has dependencies that are not in `packages` and a warning is only
# printed for the ones that are needed on these platforms.
target_platform_envs = [
    {
        "implementation_name": "cpython",
        "os_name": "posix",
        "platform_machine": "x86_64",
        "platform_system": "Linux",
        "python_full_version": python_full_version,
        "python_version": python_full_version.rpartition(".")[0],
        "sys_platform": "linux",
    }
    for python_full_version in ["3.10.20", "3.12.13"]
]
