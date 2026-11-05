import copy
import importlib.util
from pathlib import Path
import unittest


SPEC = importlib.util.spec_from_file_location("ci_event_policy", Path(__file__).resolve().parents[1] / "scripts/ci-event-policy.py")
policy = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(policy)


class EventAdmissionTest(unittest.TestCase):
    def setUp(self):
        self.event = {"ref": "refs/heads/feature", "after": "head-1", "repository": {
            "full_name": "owner/repo", "default_branch": "main"}}
        self.pr = {"number": 12, "state": "open", "mergeable": True,
                   "head": {"sha": "head-1", "ref": "feature", "repo": {"full_name": "owner/repo"}},
                   "base": {"sha": "base-1"}}
        self.run = {"event": "pull_request", "head_sha": "head-1", "status": "queued",
                    "display_title": "Test pull_request refs/pull/12/merge", "conclusion": None}
        self.snapshot = {"branch_sha": "head-1", "pulls": [self.pr], "pr_runs": [self.run]}

    def test_merge_validation_replaces_matching_branch_suite(self):
        self.assertFalse(policy.decide("push", self.event, self.snapshot)["run"])
        for status, conclusion in [("in_progress", None), ("completed", "success"), ("completed", "failure")]:
            with self.subTest(status=status, conclusion=conclusion):
                self.run.update(status=status, conclusion=conclusion)
                self.assertFalse(policy.decide("push", self.event, self.snapshot)["run"])

    def test_missing_conflicted_or_uncertain_pr_keeps_branch_coverage(self):
        for mergeable in [False, None]:
            with self.subTest(mergeable=mergeable):
                self.pr["mergeable"] = mergeable
                self.assertTrue(policy.decide("push", self.event, self.snapshot)["run"])
        self.snapshot["pulls"] = []
        self.assertTrue(policy.decide("push", self.event, self.snapshot)["run"])

    def test_pr_without_usable_scheduled_merge_run_cannot_drop_push(self):
        for runs in [[], [{**self.run, "conclusion": "cancelled", "status": "completed"}],
                     [{**self.run, "display_title": "Test pull_request refs/pull/99/merge"}],
                     [{**self.run, "head_sha": "previous-head"}]]:
            with self.subTest(runs=runs):
                self.snapshot["pr_runs"] = runs
                self.assertTrue(policy.decide("push", self.event, self.snapshot)["run"])

    def test_same_named_foreign_branch_does_not_replace_this_push(self):
        self.pr["head"]["repo"]["full_name"] = "fork/repo"
        self.assertTrue(policy.decide("push", self.event, self.snapshot)["run"])

    def test_default_branch_and_same_named_tag_always_retain_validation(self):
        for ref in ["refs/heads/main", "refs/tags/feature"]:
            with self.subTest(ref=ref):
                self.event["ref"] = ref
                self.assertTrue(policy.decide("push", self.event, self.snapshot)["run"])

    def test_delayed_old_push_does_not_admit_obsolete_head(self):
        self.snapshot["branch_sha"] = "head-2"
        self.assertFalse(policy.decide("push", self.event, self.snapshot)["run"])

    def test_unchanged_pr_head_keeps_event_merge_after_base_only_advance(self):
        event = {"pull_request": copy.deepcopy(self.pr), "number": 12}
        current = copy.deepcopy(self.pr)
        current["base"]["sha"] = "base-2"
        self.assertTrue(policy.decide("pull_request", event, {"current_pr": current})["run"])
        current["head"]["sha"] = "head-2"
        self.assertFalse(policy.decide("pull_request", event, {"current_pr": current})["run"])

    def test_fork_pr_keeps_merge_validation(self):
        event = {"pull_request": copy.deepcopy(self.pr), "number": 12}
        event["pull_request"]["head"]["repo"]["full_name"] = "fork/repo"
        self.assertTrue(policy.decide("pull_request", event, {"current_pr": event["pull_request"]})["run"])

    def test_explicit_invocations_and_api_failure_do_not_suppress_coverage(self):
        for event_name in ["workflow_dispatch", "workflow_call", "schedule"]:
            with self.subTest(event_name=event_name):
                self.assertTrue(policy.decide(event_name, self.event, self.snapshot)["run"])
        self.assertTrue(policy.decide("push", self.event, {"api_error": "unavailable"})["run"])
        self.assertTrue(policy.decide("pull_request", {"pull_request": self.pr}, {"api_error": "unavailable"})["run"])


if __name__ == "__main__":
    unittest.main()
