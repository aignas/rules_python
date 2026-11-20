"""Measure the Starlark code with Bazel itself and print a Markdown table.

    bazel run //tests/perf:bazel_benchmark

The workload is executed during the analysis of a target and the number of the
iterations is a build flag, so the time of a single iteration is the
difference of the wall time of 2 builds divided by the difference of the
iterations. See the README.md for details.
"""

import argparse
import os
import statistics
import subprocess
import time

_TARGET = "//tests/perf:bazel_benchmark_analysis"


def _build(bazel, workload, iterations):
    """Analyze the target and return the wall time in seconds."""
    cmd = bazel + [
        "build",
        _TARGET,
        "--//tests/perf:workload={}".format(workload),
        "--//tests/perf:iterations={}".format(iterations),
    ]
    start = time.perf_counter()
    subprocess.run(cmd, check=True, capture_output=True)
    return time.perf_counter() - start


def _measure(bazel, workload, *, min_seconds, repeat):
    """Return the time of a single iteration in microseconds."""

    # Find the number of iterations that takes long enough for the noise of
    # the Bazel invocation itself to not matter.
    iterations = 1000
    while True:
        overhead = _build(bazel, "noop", iterations)
        elapsed = _build(bazel, workload, iterations)
        if elapsed - overhead >= min_seconds or iterations >= 10**7:
            break
        iterations *= 4

    # The analysis is cached, so every build needs a different number of
    # iterations.
    samples = []
    for i in range(repeat):
        low = iterations + i
        high = iterations * 2 + i
        elapsed = _build(bazel, workload, high) - _build(bazel, workload, low)
        samples.append(elapsed / (high - low) * 1e6)

    return statistics.median(samples), iterations * 2


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("filter", nargs="?", default="")
    parser.add_argument(
        "--bazel",
        default="bazel",
        help="The Bazel command, the startup options can be included.",
    )
    parser.add_argument(
        "--workloads",
        required=True,
        help="The comma separated names of the workloads, set by the BUILD file.",
    )
    parser.add_argument(
        "--min-seconds",
        type=float,
        default=0.5,
        help="Increase the iterations until the workload takes at least this long.",
    )
    parser.add_argument("--repeat", type=int, default=3)
    args = parser.parse_args()

    workspace = os.environ.get("BUILD_WORKSPACE_DIRECTORY")
    if workspace:
        os.chdir(workspace)

    bazel = args.bazel.split()
    # Start the server and load the packages.
    _build(bazel, "noop", 1)

    print("| Workload | Time, µs | Iterations |")
    print("|---|---:|---:|")
    for workload in args.workloads.split(","):
        if args.filter not in workload:
            continue
        micros, iterations = _measure(
            bazel,
            workload,
            min_seconds=args.min_seconds,
            repeat=args.repeat,
        )
        print("| `{}` | {:.1f} | {} |".format(workload, micros, iterations), flush=True)


if __name__ == "__main__":
    main()
