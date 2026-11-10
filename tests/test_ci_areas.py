import importlib.util
import io
import os
from pathlib import Path
import re
import subprocess
import sys
import unittest


REPO = Path(__file__).resolve().parents[1]
PROBE = importlib.util.spec_from_file_location("linux_platform", REPO / "scripts/linux-platform.py")
linux_platform = importlib.util.module_from_spec(PROBE)
PROBE.loader.exec_module(linux_platform)
# The Linux CI image follows the Fedora release the host probe validates.
FEDORA_IMAGE = f"registry.fedoraproject.org/fedora:{linux_platform.VALIDATED_RELEASE}"

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


class PinUpdateWorkflowTest(unittest.TestCase):
    def test_generated_candidates_publish_without_validation(self):
        repo = Path(__file__).resolve().parents[1]
        for name in ("font", "harness-plugin", "personal-app"):
            with self.subTest(updater=name):
                updater = (repo / f".github/workflows/update-{name}-lock.yml").read_text()
                self.assertNotRegex(updater, r"(?m)^  validate:")
                self.assertNotIn("uses: ./.github/workflows/test.yml", updater)
                publish = updater.split("\n  publish:\n", 1)[1]
                self.assertRegex(publish, r"\A    needs: resolve\n")
                self.assertIn("ref: ${{ needs.resolve.outputs.base-sha }}", publish)
                self.assertIn("artifact-ids: ${{ needs.resolve.outputs.lock-artifact }}", publish)
                self.assertIn("git diff --quiet", publish)

    def test_reusable_suite_keeps_font_candidate_coverage(self):
        repo = Path(__file__).resolve().parents[1]
        suite = (repo / ".github/workflows/test.yml").read_text()
        self.assertIn("font-lock-artifact:", suite)
        self.assertIn("&download-font-lock", suite)
        self.assertIn("&select-font-lock", suite)
        self.assertIn("- *download-font-lock", suite)
        self.assertIn("- *select-font-lock", suite)
        self.assertIn("python tests/smoke_fonts.py", suite)
        base = re.search(r"- &fedora-base\n(?:        .*\n)+", suite).group(0)
        self.assertIn("fontconfig", base)


class MacBuildWorkflowTest(unittest.TestCase):
    def test_native_builds_keep_candidate_checkout_and_disposable_roots(self):
        workflow = (Path(__file__).resolve().parents[1] / ".github/workflows/test.yml").read_text(encoding="utf-8")
        job = workflow.split("\n  macos-build:\n", 1)[1]
        self.assertNotIn("${{ runner.", job.split("\n    steps:\n", 1)[0],
                         "GitHub rejects the runner context in job-level env")
        self.assertIn("runs-on: macos-26", job)
        for anchor in ("checkout", "candidate-lock", "select-lock", "download-harness-lock", "select-harness-lock"):
            self.assertIn("- *" + anchor + "\n", job)
        self.assertIn("MISE_DATA_DIR: ${{ runner.temp }}/mise-macos-build/data", job)
        self.assertIn("MISE_CACHE_DIR: ${{ runner.temp }}/mise-macos-build/cache", job)
        self.assertIn("env -u DOTNET_ROOT -u CARGO_HOME -u RUSTUP_HOME -u RUSTUP_TOOLCHAIN", job)
        self.assertIn('HOME="$fixture_home" mise run macos-build', job)
        self.assertLess(job.index("mise run macos-build"), job.index("tests/smoke_macos_build_environment.py"))
        self.assertIn('--home "$RUNNER_TEMP/macos-build-home"', job)
        self.assertIn('if: always()', job)
        self.assertIn("native-macos-build.json", job)
        self.assertNotIn("mise run apply", job)


class GhosttyWorkflowTest(unittest.TestCase):
    def test_native_status_accepts_only_the_expected_missing_manager(self):
        spec = importlib.util.spec_from_file_location("ghostty_smoke", Path(__file__).with_name("smoke_ghostty.py"))
        smoke = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(smoke)
        expected = "Terminal environment PENDING: The systemd user-manager environment is unavailable; verify in a desktop session.\n"
        smoke.verify_terminal_status(subprocess.CompletedProcess([], 2, "", expected))
        smoke.verify_terminal_status(subprocess.CompletedProcess([], 0, "READY", ""))
        for unexpected in ("Managed Ghostty configuration differs", "Account login shell is not zsh"):
            with self.subTest(unexpected=unexpected), self.assertRaises(RuntimeError):
                smoke.verify_terminal_status(subprocess.CompletedProcess(
                    [], 2, "", expected + "Terminal environment PENDING: " + unexpected + "\n"))

    def test_native_smoke_refuses_a_personal_workstation(self):
        repo = Path(__file__).resolve().parents[1]
        environment = {**os.environ, "GITHUB_ACTIONS": "false", "RUNNER_ENVIRONMENT": "personal"}
        result = subprocess.run([sys.executable, str(repo / "tests/smoke_ghostty.py")],
                                env=environment, capture_output=True, text=True, timeout=15)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("restricted to disposable GitHub-hosted runners", result.stdout + result.stderr)

    def test_native_matrix_excludes_desktop_work_on_ineligible_targets(self):
        workflow = (Path(__file__).resolve().parents[1] / ".github/workflows/test.yml").read_text()
        native = workflow.split("\n  native:\n", 1)[1].split("\n  macos-build:\n", 1)[0]
        areas = re.search(r"\barea:\s*\[([^]]+)\]", native).group(1)
        self.assertIn("ghostty", [area.strip().strip("\"'") for area in areas.split(",")])
        for runner_name, target in (("windows-2025", "windows-amd64"),
                                    ("windows-11-arm", "windows-arm64")):
            self.assertIn(f"- area: ghostty\n            platform:\n              runner: {runner_name}\n              target: {target}", native)
        for area in ("ghostty", "t3", "t3-instructions"):
            self.assertIn(f"- area: {area}\n            platform:\n              runner: ubuntu-24.04\n"
                          f"              target: linux-amd64\n              container: {FEDORA_IMAGE}\n", native)
        self.assertIn("python tests/smoke_ghostty.py --expected-target ${{ matrix.platform.target }}", native)
        self.assertIn("matrix.area == 'antigravity'", native)


class FedoraImageWorkflowTest(unittest.TestCase):
    def setUp(self):
        self.workflow = (Path(__file__).resolve().parents[1] / ".github/workflows/test.yml").read_text()

    def job(self, name):
        return re.search(rf"(?ms)^  {name}:\n.*?(?=^  \S|\Z)", self.workflow).group(0)

    def test_linux_lanes_run_in_the_validated_fedora_image(self):
        for name in ("unit", "native", "pinentry"):
            with self.subTest(job=name):
                job = self.job(name)
                self.assertIn("    container: ${{ matrix.platform.container }}\n", job)
                self.assertEqual(re.findall(r"(?m)^            container: (\S+)$", job.split("exclude:")[0]),
                                 [FEDORA_IMAGE])
                steps = job.split("\n    steps:\n", 1)[1]
                self.assertTrue(steps.startswith("      - &fedora-base\n") or steps.startswith("      - *fedora-base\n"))
                self.assertLess(steps.index("fedora-base"), steps.index("checkout"))

    def test_linux_lanes_are_amd64_only_and_use_dnf(self):
        self.assertNotIn("apt-get", self.workflow)
        self.assertNotIn("ubuntu-26.04", self.workflow)
        self.assertNotRegex(self.workflow, r"ubuntu-[0-9.]+-arm")
        self.assertNotIn("linux-arm64", self.workflow)
        self.assertEqual(set(re.findall(r"runner: (ubuntu-\S+)", self.workflow)), {"ubuntu-24.04"})


if __name__ == "__main__":
    unittest.main()
