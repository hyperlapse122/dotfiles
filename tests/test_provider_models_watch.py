"""Drive provider-models-watch against a fake Anthropic list and models.dev document.

The helper's `curl` command is stubbed on `PATH`, so these tests feed it
fixture bodies and record what it was asked instead of making network calls.
"""

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/provider-models-watch"
KEYS = {"anthropic": "ANTHROPIC_API_KEY"}

FAKE_CURL = """#!{python}
import json, os, sys
log = os.environ['FAKE_LOG']
calls = json.load(open(log)) if os.path.exists(log) else []
calls.append({{'argv': sys.argv[1:], 'stdin': sys.stdin.read()}})
json.dump(calls, open(log, 'w'))
outcomes = json.loads(os.environ['FAKE_OUTCOMES'])
outcome = outcomes[min(len(calls), len(outcomes)) - 1]
if isinstance(outcome, int):
    sys.stderr.write('curl: (22) The requested URL returned error: 503\\n')
    sys.exit(outcome)
if isinstance(outcome, dict):
    sys.stderr.write(outcome['stderr'] + '\\n')
    sys.exit(outcome['status'])
sys.stdout.write(outcome)
"""


def listing(*ids, **extra):
    return {"data": [{"id": model_id} for model_id in ids], **extra}


def detail(name, **extra):
    row = {
        "name": name,
        "reasoning": True,
        "modalities": {"input": ["text", "image", "pdf"], "output": ["text"]},
        "cost": {"input": 2.5, "output": 15, "cache_read": 0.25, "cache_write": 3},
        "limit": {"context": 1050000, "input": 922000, "output": 128000},
    }
    row.update(extra)
    return row


def models_dev(provider, **rows):
    return {provider: {"models": {model_id: row for model_id, row in rows.items()}}}


class WatchTestCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        curl = bin_dir / "curl"
        curl.write_text(FAKE_CURL.format(python=sys.executable))
        curl.chmod(0o755)
        self.bin_dir = bin_dir
        self.log = self.root / "curl.json"
        self.snapshot = self.root / "snapshot.json"

    def run_watch(self, outcomes=None, extra=None, key="FAKE-KEY"):
        env = dict(os.environ)
        env.pop(KEYS["anthropic"], None)
        if key:
            env[KEYS["anthropic"]] = key
        env["PATH"] = f"{self.bin_dir}:{env.get('PATH', '')}"
        env["FAKE_LOG"] = str(self.log)
        env["FAKE_OUTCOMES"] = json.dumps(outcomes or [])
        args = [sys.executable, str(SCRIPT), "--provider", "anthropic", "--retry-wait", "0"] + (extra or [])
        return subprocess.run(args, capture_output=True, text=True, env=env)

    def write(self, name, value):
        path = self.root / name
        path.write_text(json.dumps(value))
        return str(path)

    def run_offline(self, api, documented, extra=None):
        return self.run_watch(
            extra=["--catalog", self.write("api.json", api), "--models-dev", self.write("dev.json", documented)]
            + (extra or []),
        )

    def rows_of(self, proc):
        self.assertEqual(proc.returncode, 0, proc.stderr)
        return json.loads(proc.stdout)["models"]

    def ids_of(self, proc):
        return [row["id"] for row in self.rows_of(proc)]

    def anthropic_dev(self, *ids):
        return models_dev("anthropic", **{model_id: detail(model_id.upper()) for model_id in ids})

    def test_new_models_are_listed_with_models_dev_details(self):
        proc = self.run_offline(
            listing("claude-haiku-5-5", "claude-opus-5-5"),
            models_dev("anthropic", **{"claude-haiku-5-5": detail("Claude Haiku 5.5"),
                                       "claude-opus-5-5": detail("Claude Opus 5.5")}),
        )
        rows = self.rows_of(proc)
        self.assertEqual([row["id"] for row in rows], ["claude-haiku-5-5", "claude-opus-5-5"])
        self.assertEqual(rows[0], {
            "id": "claude-haiku-5-5",
            "name": "Claude Haiku 5.5",
            "reasoning": True,
            "input": ["text", "image"],
            "cost": {"input": 2.5, "output": 15, "cacheRead": 0.25, "cacheWrite": 3},
            "contextWindow": 1050000,
            "maxTokens": 128000,
        })

    def test_a_filtered_in_model_without_a_models_dev_entry_is_named_and_left_out(self):
        proc = self.run_offline(
            listing("claude-haiku-5-5", "claude-opus-5-5"),
            models_dev("anthropic", **{"claude-haiku-5-5": detail("Haiku")}),
        )
        self.assertEqual(self.ids_of(proc), ["claude-haiku-5-5"])
        self.assertIn("claude-opus-5-5 passes the anthropic filter but models.dev has no entry", proc.stderr)

    def test_a_models_dev_entry_without_limits_is_named_and_left_out(self):
        documented = models_dev("anthropic", **{"claude-haiku-5-5": detail("Haiku"),
                                                "claude-opus-5-5": detail("Opus", limit={"context": 1})})
        proc = self.run_offline(listing("claude-haiku-5-5", "claude-opus-5-5"), documented)
        self.assertEqual(self.ids_of(proc), ["claude-haiku-5-5"])
        self.assertIn("claude-opus-5-5: no usable context and output limits", proc.stderr)

    def test_missing_models_dev_fields_get_conservative_defaults(self):
        documented = models_dev("anthropic", **{"claude-haiku-5-5": {"limit": {"context": 100, "output": 10}}})
        row = self.rows_of(self.run_offline(listing("claude-haiku-5-5"), documented))[0]
        self.assertEqual(row["name"], "claude-haiku-5-5")
        self.assertFalse(row["reasoning"])
        self.assertEqual(row["input"], ["text"])
        self.assertEqual(row["cost"], {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0})

    def test_anthropic_api_limits_override_models_dev_and_cost_stays(self):
        listed = {"data": [{"id": "claude-opus-5-5", "max_input_tokens": 900000, "max_tokens": 64000}]}
        documented = models_dev("anthropic", **{"claude-opus-5-5": detail("Opus")})
        row = self.rows_of(self.run_offline(listed, documented))[0]
        self.assertEqual(row["contextWindow"], 900000)
        self.assertEqual(row["maxTokens"], 64000)
        self.assertEqual(row["cost"]["input"], 2.5)

    def test_anthropic_keeps_dated_ids_and_drops_ids_that_fail_the_filter_or_are_not_active(self):
        listed = {"data": [
            {"id": "claude-haiku-5-5-20260115"},
            {"id": "claude-opus-5-5", "lifecycle": "retired"},
            {"id": "not-a-claude"},
        ]}
        documented = self.anthropic_dev("claude-haiku-5-5-20260115", "claude-opus-5-5")
        proc = self.run_offline(listed, documented)
        self.assertEqual(self.ids_of(proc), ["claude-haiku-5-5-20260115"])

    def test_a_response_with_more_pages_is_refused(self):
        proc = self.run_offline(listing("claude-haiku-5-5", has_more=True), self.anthropic_dev("claude-haiku-5-5"))
        self.assertEqual(proc.returncode, 1)
        self.assertIn("more pages than one request returns", proc.stderr)

    def test_a_list_entry_without_an_id_is_skipped_with_a_warning(self):
        api = {"data": [{"object": "model"}, {"id": "claude-haiku-5-5"}]}
        proc = self.run_offline(api, self.anthropic_dev("claude-haiku-5-5"))
        self.assertEqual(self.ids_of(proc), ["claude-haiku-5-5"])
        self.assertIn("skipping a anthropic list entry without an id", proc.stderr)

    def test_a_body_without_a_data_list_is_refused(self):
        proc = self.run_offline({"models": []}, self.anthropic_dev("claude-haiku-5-5"))
        self.assertEqual(proc.returncode, 1)
        self.assertIn("the anthropic list has no data list", proc.stderr)

    def test_a_models_dev_document_without_the_provider_is_refused(self):
        proc = self.run_offline(listing("claude-haiku-5-5"), {"other": {"models": {}}})
        self.assertEqual(proc.returncode, 1)
        self.assertIn("models.dev has no anthropic models", proc.stderr)

    def test_an_empty_result_is_refused_and_leaves_the_file(self):
        self.snapshot.write_text('{"models":[{"id":"keep"}]}\n')
        proc = self.run_offline(
            listing("not-a-claude"),
            self.anthropic_dev("not-a-claude"),
            ["--snapshot", str(self.snapshot)],
        )
        self.assertEqual(proc.returncode, 1)
        self.assertIn("no listed anthropic model passes the filter", proc.stderr)
        self.assertEqual(self.snapshot.read_text(), '{"models":[{"id":"keep"}]}\n')

    def test_a_refresh_replaces_a_wide_snapshot_and_sorts_by_id(self):
        self.snapshot.write_text('{"models":[{"id":"old"},{"id":"wider"}]}\n')
        proc = self.run_offline(
            listing("claude-opus-5-5", "claude-haiku-5-5"),
            self.anthropic_dev("claude-opus-5-5", "claude-haiku-5-5"),
            ["--snapshot", str(self.snapshot)],
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual([m["id"] for m in json.loads(self.snapshot.read_text())["models"]],
                         ["claude-haiku-5-5", "claude-opus-5-5"])

    def test_an_unchanged_result_does_not_touch_the_file(self):
        args = (listing("claude-haiku-5-5"), self.anthropic_dev("claude-haiku-5-5"), ["--snapshot", str(self.snapshot)])
        self.run_offline(*args)
        before = self.snapshot.stat().st_mtime_ns
        self.run_offline(*args)
        self.assertEqual(self.snapshot.stat().st_mtime_ns, before)

    def test_anthropic_sends_its_key_header_on_stdin_and_asks_for_active_models(self):
        outcomes = [json.dumps(listing("claude-haiku-5-5")), json.dumps(self.anthropic_dev("claude-haiku-5-5"))]
        proc = self.run_watch(outcomes)
        self.assertEqual(self.ids_of(proc), ["claude-haiku-5-5"])
        calls = json.loads(self.log.read_text())
        self.assertIn("x-api-key: FAKE-KEY", calls[0]["stdin"])
        self.assertIn("anthropic-version", calls[0]["stdin"])
        self.assertEqual(calls[0]["argv"][-1],
                         "https://api.anthropic.com/v1/models?lifecycle=active&limit=1000")

    def test_models_dev_is_fetched_without_a_key(self):
        outcomes = [json.dumps(listing("claude-haiku-5-5")), json.dumps(self.anthropic_dev("claude-haiku-5-5"))]
        self.run_watch(outcomes)
        calls = json.loads(self.log.read_text())
        self.assertEqual(calls[1]["stdin"], "")
        self.assertEqual(calls[1]["argv"][-1], "https://models.dev/api.json")

    def test_a_missing_key_fails_before_any_fetch(self):
        proc = self.run_watch(key="")
        self.assertEqual(proc.returncode, 1)
        self.assertIn("ANTHROPIC_API_KEY is not set", proc.stderr)
        self.assertFalse(self.log.exists())

    def test_one_failed_fetch_is_retried_and_two_leave_the_snapshot(self):
        self.snapshot.write_text('{"models":[{"id":"keep"}]}\n')
        documented = json.dumps(self.anthropic_dev("claude-haiku-5-5"))
        proc = self.run_watch([22, json.dumps(listing("claude-haiku-5-5")), documented],
                              ["--snapshot", str(self.snapshot)])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("claude-haiku-5-5", self.snapshot.read_text())
        self.snapshot.write_text('{"models":[{"id":"keep"}]}\n')
        proc = self.run_watch([22, "not json"], ["--snapshot", str(self.snapshot)])
        self.assertEqual(proc.returncode, 1)
        self.assertEqual(self.snapshot.read_text(), '{"models":[{"id":"keep"}]}\n')

    def test_a_failed_models_dev_fetch_leaves_the_snapshot(self):
        self.snapshot.write_text('{"models":[{"id":"keep"}]}\n')
        proc = self.run_watch(
            [json.dumps(listing("claude-haiku-5-5")), 22, 22],
            ["--snapshot", str(self.snapshot)],
        )
        self.assertEqual(proc.returncode, 1)
        self.assertEqual(self.snapshot.read_text(), '{"models":[{"id":"keep"}]}\n')

    def test_a_key_echoed_in_curl_stderr_is_not_logged(self):
        leak = json.dumps({"stderr": "x-api-key: FAKE-KEY", "status": 22})
        proc = self.run_watch([leak, leak])
        self.assertEqual(proc.returncode, 1)
        self.assertNotIn("FAKE-KEY", proc.stdout)
        self.assertNotIn("FAKE-KEY", proc.stderr)


class CommittedSnapshotTestCase(unittest.TestCase):
    def test_the_committed_anthropic_snapshot_is_sorted_distinct_complete_rows_that_pass_the_filter(self):
        snapshot = json.loads((ROOT / "home/h82/agents/anthropic-models.json").read_text())
        rows = snapshot["models"]
        ids = [row["id"] for row in rows]
        self.assertEqual(ids, sorted(ids))
        self.assertEqual(len(ids), len(set(ids)))
        for row in rows:
            self.assertRegex(row["id"], r"^claude-\w+-[0-9\-.]+$")
            self.assertTrue(row["name"])
            self.assertIsInstance(row["reasoning"], bool)
            self.assertTrue(row["input"])
            self.assertGreater(row["contextWindow"], 0)
            self.assertGreater(row["maxTokens"], 0)


if __name__ == "__main__":
    unittest.main()
