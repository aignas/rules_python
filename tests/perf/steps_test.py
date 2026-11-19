"""Tests that the Starlark code does not get slower without us noticing."""

import unittest

from tests.perf import starlark_shim
from tests.perf.workloads import workloads

# The maximum number of steps for each workload, see the README.md. The number
# of the steps slightly depends on the Python version, hence the budgets are
# about 10% higher than the measured values.
#
# If you have made the code faster, lower the budget so that it stays that way.
_BUDGETS = {
    # keep sorted
    "evaluate: long marker": 5150,
    "evaluate: os_name == 'posix' and sys_platform == 'linux'": 610,
    "evaluate: python_version < '3.11' and extra == 'dev' (non-strict)": 575,
    "evaluate: python_version >= '3.8'": 490,
    "evaluate: sys_platform == 'win32'": 300,
    "tokenize: long marker": 2900,
    "tokenize: python_version >= '3.8'": 200,
    "version.is_compatible(3.11.4, 3.8)": 73,
    "version.is_eq(3.11.4, 3.11.*)": 13,
    "version.is_ge(3.11.4, 3.8)": 59,
    "version.is_lt(3.11.4, 3.8)": 52,
    "version.key(3.11.4)": 28,
    "version.normalize('2023.07.19')": 27,
    "version.parse('#1 SMP Debian')": 700,
    "version.parse('1!2.0.0rc1.post3.dev4+ubuntu.7')": 1670,
    "version.parse('3.11.*')": 60,
    "version.parse('3.11.4')": 61,
    "version.parse('3.13.0rc1')": 1125,
}


class StepsTest(unittest.TestCase):
    def test_all_workloads_have_budgets(self):
        self.assertEqual(sorted(_BUDGETS), sorted(workloads()))

    def test_steps_are_within_budget(self):
        for name, fn in workloads().items():
            with self.subTest(name):
                steps = starlark_shim.count_steps(fn)
                budget = _BUDGETS[name]
                self.assertLessEqual(
                    steps,
                    budget,
                    "The code got slower, see tests/perf/README.md",
                )
                self.assertGreaterEqual(
                    steps,
                    budget * 0.8,
                    "The code got faster, lower the budget to keep it that way",
                )


if __name__ == "__main__":
    unittest.main()
