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

### Measuring with Bazel

The steps are a proxy, so there is also a benchmark that measures a few of the
workloads with Bazel itself:

```shell
bazel run //tests/perf:bazel_benchmark
```

It builds `//tests/perf:bazel_benchmark_analysis`, which executes the workload
that is selected with `--//tests/perf:workload` for
`--//tests/perf:iterations` times during the analysis. Starlark does not have
a clock, so the time of a single iteration is the difference of the wall time
of 2 builds divided by the difference of the iterations. This takes a few
minutes and the results depend on the machine, hence it is not a test.

Use `--bazel` if you need to pass the startup options, e.g. `--bazel="bazel
--host_jvm_args=-Xmx2g"`, otherwise the Bazel server restarts between the
builds.

The same target can be used to profile the code with `--starlark_cpu_profile`,
see https://bazel.build/rules/performance#performance-profiling:

```shell
bazel build //tests/perf:bazel_benchmark_analysis \
    --//tests/perf:workload=evaluate_long_marker \
    --//tests/perf:iterations=10000 \
    --starlark_cpu_profile=/tmp/profile.gz
```

## Results

| Workload | Steps | Time, µs |
|---|---:|---:|
| `evaluate: long marker` | 2055 | 113.1 |
| `evaluate: os_name == 'posix' and sys_platform == 'linux'` | 239 | 12.5 |
| `evaluate: python_version < '3.11' and extra == 'dev' (non-strict)` | 230 | 12.4 |
| `evaluate: python_version >= '3.8'` | 292 | 21.7 |
| `evaluate: sys_platform == 'win32'` | 124 | 7.0 |
| `tokenize: long marker` | 483 | 24.3 |
| `tokenize: python_version>='3.8' and os_name=='posix'` | 232 | 9.0 |
| `tokenize: python_version >= '3.8'` | 45 | 2.4 |
| `version.is_compatible(3.11.4, 3.8)` | 66 | 2.3 |
| `version.is_eq(3.11.4, 3.11.*)` | 11 | 0.7 |
| `version.is_ge(3.11.4, 3.8)` | 53 | 1.7 |
| `version.is_lt(3.11.4, 3.8)` | 47 | 1.9 |
| `version.key(3.11.4)` | 25 | 0.8 |
| `version.normalize('2023.07.19')` | 24 | 1.8 |
| `version.parse('#1 SMP Debian')` | 631 | 55.9 |
| `version.parse('1!2.0.0rc1.post3.dev4+ubuntu.7')` | 1512 | 149.5 |
| `version.parse('3.11.*')` | 54 | 5.4 |
| `version.parse('3.11.4')` | 55 | 5.2 |
| `version.parse('3.13.0rc1')` | 1016 | 99.6 |

### Bazel

The time is of Bazel 9.1.1 on a laptop before and after the optimizations that
are listed in the history below, only the ratios are meaningful. They
confirm that the steps are a good proxy: the workloads that take 4 to 16 times
fewer steps are 4 to 20 times faster.

| Workload | Before, µs | After, µs |
|---|---:|---:|
| `evaluate_long_marker` | 2088.9 | 357.9 |
| `evaluate_python_version` | 426.8 | 54.4 |
| `evaluate_sys_platform` | 37.3 | 22.1 |
| `version_parse_pre_release` | 235.3 | 245.0 |
| `version_parse_release` | 207.5 | 10.3 |

## History

The notable changes of the results, the numbers are the steps.

| Change | Workload | Before | After |
|---|---|---:|---:|
| Parse the release-only versions without the parser | `version.parse('3.11.4')` | 878 | 55 |
| | `evaluate: python_version >= '3.8'` | 1883 | 441 |
| | `evaluate: long marker` | 9313 | 4660 |
| Tokenize the markers with the string methods | `tokenize: long marker` | 2629 | 483 |
| | `evaluate: sys_platform == 'win32'` | 271 | 140 |
| | `evaluate: long marker` | 4660 | 2514 |
| Evaluate the markers in a single pass | `evaluate: long marker` | 2514 | 2055 |
| | `evaluate: os_name == 'posix' and sys_platform == 'linux'` | 287 | 239 |
