from pathlib import Path
import re
import unittest


REPO = Path(__file__).resolve().parents[1]


class TestWorkflowTest(unittest.TestCase):
    def test_direct_events_keep_branch_tag_and_pr_coverage(self):
        workflow = (REPO / ".github/workflows/test.yml").read_text()
        triggers = workflow.split("\non:\n", 1)[1].split("\npermissions:", 1)[0]
        for event in ("push", "pull_request"):
            self.assertRegex(triggers, rf"(?m)^  {event}:\s*\n(?=  \w)")
        for event in ("workflow_dispatch", "workflow_call"):
            self.assertIn(f"\n  {event}:\n", "\n" + triggers)
        self.assertIn("ref: ${{ inputs.base-sha || github.sha }}", workflow)
        for artifact in ("lock-artifact", "harness-lock-artifact", "font-lock-artifact"):
            self.assertIn(f"if: inputs.{artifact} != ''", workflow)

    def test_actual_jobs_replace_the_conditional_admission_wrapper(self):
        workflow = (REPO / ".github/workflows/test.yml").read_text()
        self.assertFalse((REPO / ".github/workflows/test-events.yml").exists())
        self.assertFalse((REPO / "scripts/ci-event-policy.py").exists())
        for forbidden in ("needs: admission", "cancel-in-progress: true", "actions: write",
                          "uses: ./.github/workflows/test.yml"):
            self.assertNotIn(forbidden, workflow)
        self.assertIn("permissions:\n  contents: read\n", workflow)
        self.assertTrue(re.search(r"(?m)^  unit:\s*$", workflow))
        self.assertTrue(re.search(r"(?m)^  native:\s*$", workflow))


if __name__ == "__main__":
    unittest.main()
