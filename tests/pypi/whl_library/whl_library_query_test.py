import os
import unittest


class QueryTest(unittest.TestCase):
    def test_deps_include_the_extras(self):
        with open(os.environ["QUERY_OUTPUT"]) as f:
            got = {
                # The canonical names of the repositories depend on the
                # extension that creates them.
                line.strip().rpartition("whl_library_extras_")[2]
                for line in f
                if "whl_library_extras_" in line
            }

        # The edges in the `METADATA` of the consumer, the first extra is
        # provided by `pkg` and the second one is not.
        self.assertIn("consumer//:_pkg[optional]", got)
        self.assertIn("consumer//:_pkg[unknown]", got)
        # Both of them resolve to the target that selects the extra.
        self.assertIn("pkg//:_extras", got)
        self.assertIn("pkg//:[optional]", got)
        self.assertIn("pkg//:[]", got)
        self.assertNotIn("pkg//:[unknown]", got)
        # The dependency of the `optional` extra.
        self.assertIn("optional_dep//:pkg", got)


if __name__ == "__main__":
    unittest.main()
