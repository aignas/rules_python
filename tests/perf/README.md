# Performance of the Starlark code

The version and the environment marker handling is executed many times when
`pip.parse` is evaluated: for every requirement, for every target platform and
for every Python version. This directory has the tools to ensure that this code
stays fast.

## How it works

Bazel cannot benchmark Starlark functions and it cannot count how many steps
the interpreter executes. However, the `.bzl` files that only have pure
functions are almost valid Python, so `starlark_shim.py` executes them with
CPython and counts the executed lines of the `.bzl` files, which we call
_steps_.

The number of steps is deterministic, it does not depend on the machine and it
changes when the amount of work that the code does changes. The time is only
indicative, because it is the time of CPython and not of Bazel.

The shim is not a Starlark interpreter, it only supports what the measured
files need. If you start using something that is not supported, extend the
shim.

## Running

Print the table below:

```shell
bazel run //tests/perf:benchmark
```

Only run the workloads that have `version` in the name:

```shell
bazel run //tests/perf:benchmark -- version
```

Check that the number of steps is within the budgets, this runs as part of
the regular tests:

```shell
bazel test //tests/perf:steps_test
```

If the test fails because the code got slower, then either fix the code or, if
the extra work is necessary, increase the budget in `steps_test.py`. If it
fails because the code got faster, then lower the budget. In both cases update
the results below.

To profile the code in Bazel itself, use `--starlark_cpu_profile`, see
https://bazel.build/rules/performance#performance-profiling.

## Results

| Workload | Steps | Time, µs |
|---|---:|---:|
| `evaluate: long marker` | 4660 | 385.4 |
| `evaluate: os_name == 'posix' and sys_platform == 'linux'` | 552 | 44.1 |
| `evaluate: python_version < '3.11' and extra == 'dev' (non-strict)` | 521 | 43.4 |
| `evaluate: python_version >= '3.8'` | 441 | 46.5 |
| `evaluate: sys_platform == 'win32'` | 271 | 22.9 |
| `tokenize: long marker` | 2629 | 107.9 |
| `tokenize: python_version >= '3.8'` | 178 | 7.9 |
| `version.is_compatible(3.11.4, 3.8)` | 66 | 3.8 |
| `version.is_eq(3.11.4, 3.11.*)` | 11 | 1.1 |
| `version.is_ge(3.11.4, 3.8)` | 53 | 2.7 |
| `version.is_lt(3.11.4, 3.8)` | 47 | 2.9 |
| `version.key(3.11.4)` | 25 | 1.3 |
| `version.normalize('2023.07.19')` | 24 | 2.6 |
| `version.parse('#1 SMP Debian')` | 631 | 85.9 |
| `version.parse('1!2.0.0rc1.post3.dev4+ubuntu.7')` | 1512 | 239.9 |
| `version.parse('3.11.*')` | 54 | 8.1 |
| `version.parse('3.11.4')` | 55 | 8.0 |
| `version.parse('3.13.0rc1')` | 1016 | 161.7 |

## History

The notable changes of the results, the numbers are the steps.

| Change | Workload | Before | After |
|---|---|---:|---:|
| Parse the release-only versions without the parser | `version.parse('3.11.4')` | 878 | 55 |
| | `evaluate: python_version >= '3.8'` | 1883 | 441 |
| | `evaluate: long marker` | 9313 | 4660 |
