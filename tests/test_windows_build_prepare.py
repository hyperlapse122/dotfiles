import os
from pathlib import Path
import platform
import subprocess
import sys
import tempfile
import unittest


@unittest.skipUnless(os.name == "nt" and platform.machine().lower() in ("amd64", "x86_64"), "Windows x64 preparation lane")
class WindowsBuildPrepareTest(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="prepare lane 空白 ")
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        self.receipt = self.root / "calls.txt"
        self.stub = self.root / "mise.cmd"
        self.stub.write_text('@echo off\necho %*>>"%PREP_RECEIPT%"\necho preparation diagnostic\nexit /b %PREP_EXIT%\n', encoding="utf-8")
        self.env = os.environ.copy()
        self.env.update(PATH=str(self.root), PREP_RECEIPT=str(self.receipt), PREP_EXIT="0",
                        GITHUB_ACTIONS="true", RUNNER_ENVIRONMENT="github-hosted")
        self.helper = Path(__file__).with_name("prepare_windows_build_environment.py")

    def invoke(self, *args):
        return subprocess.run([sys.executable, str(self.helper), *args], env=self.env,
                              capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=30)

    def test_preparation_requires_explicit_opt_in_and_disposable_host(self):
        result = self.invoke()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.receipt.exists())
        self.env["RUNNER_ENVIRONMENT"] = "self-hosted"
        result = self.invoke("--provision")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("disposable", result.stdout + result.stderr)
        self.assertFalse(self.receipt.exists())

    def test_opted_in_preparation_runs_twice_without_build_verification(self):
        result = self.invoke("--provision")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.receipt.read_text().splitlines(), ["run windows-build", "run windows-build"])
        self.assertIn("preparation diagnostic", result.stdout)
        self.assertIn("--verify-only", result.stdout)
        self.assertNotIn("PASS:", result.stdout)

    def test_preparation_failure_preserves_diagnostics_and_stops(self):
        self.env["PREP_EXIT"] = "23"
        result = self.invoke("--provision")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.receipt.read_text().splitlines(), ["run windows-build"])
        self.assertIn("preparation diagnostic", result.stdout)
        self.assertIn("23", result.stderr)

    def test_verifier_rejects_provisioning_before_any_task(self):
        result = subprocess.run([sys.executable, str(self.helper.with_name("smoke_windows_build_environment.py")), "--provision"],
                                env=self.env, capture_output=True, text=True, timeout=30)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.receipt.exists())


if __name__ == "__main__":
    unittest.main()
