import importlib.util
import io
from pathlib import Path
import unittest


SPEC = importlib.util.spec_from_file_location("test_area_runner", Path(__file__).resolve().parents[1] / "scripts/run-test-area.py")
runner = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runner)


class AreaSelectionTest(unittest.TestCase):
    def suite(self, module, names=("test_first", "test_second")):
        case = type("Fixture", (unittest.TestCase,), {"__module__": module, **{name: lambda self: None for name in names}})
        return unittest.defaultTestLoader.loadTestsFromTestCase(case)

    def test_disjoint_areas_preserve_baseline_ids_and_skips(self):
        first = self.suite("test_first")
        second = self.suite("test_second")
        baseline = unittest.TestSuite([first, second])
        selected = runner.partition(baseline, {"one": ("test_first",), "two": ("test_second",)}, {"test_first", "test_second"})
        self.assertEqual([case.id() for case in runner.cases(selected["one"])],
                         ["test_first.Fixture.test_first", "test_first.Fixture.test_second"])
        self.assertEqual([case.id() for case in runner.cases(selected["two"])],
                         ["test_second.Fixture.test_first", "test_second.Fixture.test_second"])

    def test_unassigned_new_module_fails_even_when_selected_area_is_known(self):
        with self.assertRaisesRegex(ValueError, "unassigned.*test_new"):
            runner.partition(unittest.TestSuite([self.suite("test_old"), self.suite("test_new")]),
                             {"one": ("test_old",)}, {"test_old", "test_new"})

    def test_duplicate_assignment_is_not_silently_deduplicated(self):
        with self.assertRaisesRegex(ValueError, "multiple.*test_first"):
            runner.partition(self.suite("test_first"), {"one": ("test_first",), "two": ("test_first",)}, {"test_first"})

    def test_removed_manifest_module_and_duplicate_ids_fail(self):
        with self.assertRaisesRegex(ValueError, "missing.*test_removed"):
            runner.partition(self.suite("test_first"), {"one": ("test_first", "test_removed")}, {"test_first"})
        with self.assertRaisesRegex(ValueError, "duplicate test ID"):
            runner.partition(unittest.TestSuite([self.suite("test_first"), self.suite("test_first")]),
                             {"one": ("test_first",)}, {"test_first"})

    def test_import_failure_cannot_be_partitioned_as_a_platform_skip(self):
        failed = unittest.TestLoader().loadTestsFromName("not_a_real_ci_fixture_module")
        with self.assertRaisesRegex(ValueError, "discovery failed"):
            runner.partition(failed, {"one": ()}, set())

    def test_whole_class_keeps_fixture_lifecycle_and_skip(self):
        observed = []

        class Fixture(unittest.TestCase):
            __module__ = "test_fixture"

            @classmethod
            def setUpClass(cls):
                observed.append("setup")

            @classmethod
            def tearDownClass(cls):
                observed.append("teardown")

            def test_run(self):
                observed.append("run")

            @unittest.skip("platform fixture")
            def test_skip(self):
                self.fail("skip was lost")

        baseline = unittest.TestSuite([unittest.defaultTestLoader.loadTestsFromTestCase(Fixture)])
        selected = runner.partition(baseline, {"one": ("test_fixture",)}, {"test_fixture"})
        result = unittest.TextTestRunner(stream=io.StringIO()).run(selected["one"])
        self.assertEqual(observed, ["setup", "run", "teardown"])
        self.assertEqual(result.testsRun, 2)
        self.assertEqual([(case._testMethodName, reason) for case, reason in result.skipped], [("test_skip", "platform fixture")])
        self.assertTrue(result.wasSuccessful())


if __name__ == "__main__":
    unittest.main()
