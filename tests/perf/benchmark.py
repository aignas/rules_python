"""Print the benchmark of the Starlark code as a Markdown table.

    bazel run //tests/perf:benchmark

See the README.md for details.
"""

import sys

from tests.perf import starlark_shim
from tests.perf.workloads import workloads


def main(argv):
    only = argv[0] if argv else ""
    print("| Workload | Steps | Time, µs |")
    print("|---|---:|---:|")
    for name, fn in workloads().items():
        if only not in name:
            continue
        print(
            "| `{}` | {} | {:.1f} |".format(
                name,
                starlark_shim.count_steps(fn),
                starlark_shim.time_it(fn),
            )
        )


if __name__ == "__main__":
    main(sys.argv[1:])
