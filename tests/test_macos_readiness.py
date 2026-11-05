import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


REPO = Path(__file__).resolve().parents[1]


class MacReadinessTest(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location("macos_readiness", REPO / "scripts/macos-readiness.py")
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)
        scratch = tempfile.TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        self.home = Path(scratch.name)

    def collect(self, *, available=True, system="Darwin", machine="arm64", version="15.0"):
        with patch.object(self.module.platform, "system", return_value=system), \
             patch.object(self.module.platform, "machine", return_value=machine), \
             patch.object(self.module.platform, "mac_ver", return_value=(version, (), "")), \
             patch.object(self.module.shutil, "which", return_value="/fixture/tool" if available else None), \
             patch.object(self.module.subprocess, "run") as run:
            run.return_value.returncode = 0
            run.return_value.stdout = "8.0.100 [fixture]\n10.0.100 [fixture]\n"
            result = self.module.collect(self.home)
            return result, run

    def test_unperformed_authenticated_and_runtime_checks_stay_pending(self):
        result, _ = self.collect()
        pending = {check["name"] for check in result["checks"] if check["status"] == "pending"}
        self.assertIn("Authenticated CE invocation", pending)
        self.assertIn("Native builds and execution", pending)
        self.assertTrue(any(check["name"] == "Claude instructions" and check["status"] == "failed"
                            for check in result["checks"]))
        self.assertFalse(result["ready"])
        self.assertEqual(self.module.exit_code(result), 1)  # Missing managed files are failures.

    def test_missing_command_fails_without_installer_or_auth_commands(self):
        result, run = self.collect(available=False)
        for command in ("codex", "claude"):
            self.assertTrue(any(check["name"] == "Command: " + command and check["status"] == "failed"
                                for check in result["checks"]))
        run.assert_not_called()

    def test_unsupported_host_stops_before_probing_commands(self):
        for override in ({"system": "Windows"}, {"machine": "x86_64"}, {"version": "14.7"}):
            with self.subTest(override=override):
                result, run = self.collect(**override)
                self.assertEqual(self.module.exit_code(result), 1)
                self.assertEqual(len(result["checks"]), 1)
                run.assert_not_called()

    def test_only_read_only_probes_execute_and_output_is_not_disclosed(self):
        result, run = self.collect()
        commands = [call.args[0] for call in run.call_args_list]
        self.assertEqual(commands, [["xcrun", "--find", "clang"], ["dotnet", "--list-sdks"]])
        self.assertNotIn("8.0.100", json.dumps(result))
        self.assertNotIn("fixture", json.dumps(result))

    def test_pending_prevents_success_even_without_failed_checks(self):
        result = {"ready": False, "checks": [{"name": "manual", "status": "pending", "detail": "Run manually"}]}
        self.assertEqual(self.module.exit_code(result), 2)
        result = {"ready": True, "checks": [{"name": "complete", "status": "passed", "detail": "Observed"}]}
        self.assertEqual(self.module.exit_code(result), 0)


if __name__ == "__main__":
    unittest.main()
