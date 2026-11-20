"""Drive provider-models-watch against fake provider lists and models.dev documents.

The helper's `curl` command is stubbed on `PATH`, so these tests feed it
fixture bodies and record what it was asked instead of making network calls.
"""

import importlib.machinery
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/provider-models-watch"
KEYS = {"openai": "OPENAI_API_KEY", "anthropic": "ANTHROPIC_API_KEY"}

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

    def run_watch(self, provider, outcomes=None, extra=None, key="FAKE-KEY"):
        env = dict(os.environ)
        for variable in KEYS.values():
            env.pop(variable, None)
        if key:
            env[KEYS[provider]] = key
        env["PATH"] = f"{self.bin_dir}:{env.get('PATH', '')}"
        env["FAKE_LOG"] = str(self.log)
        env["FAKE_OUTCOMES"] = json.dumps(outcomes or [])
        args = [sys.executable, str(SCRIPT), "--provider", provider, "--retry-wait", "0"] + (extra or [])
        return subprocess.run(args, capture_output=True, text=True, env=env)

    def write(self, name, value):
        path = self.root / name
        path.write_text(json.dumps(value))
        return str(path)

    def run_offline(self, provider, api, documented, extra=None):
        return self.run_watch(
            provider,
            extra=["--catalog", self.write("api.json", api), "--models-dev", self.write("dev.json", documented)]
            + (extra or []),
        )

    def rows_of(self, proc):
        self.assertEqual(proc.returncode, 0, proc.stderr)
        return json.loads(proc.stdout)["models"]

    def ids_of(self, proc):
        return [row["id"] for row in self.rows_of(proc)]

    def openai_dev(self, *ids):
        return models_dev("openai", **{model_id: detail(model_id.upper()) for model_id in ids})

    def anthropic_dev(self, *ids):
        return models_dev("anthropic", **{model_id: detail(model_id.upper()) for model_id in ids})

    def test_new_models_that_pi_does_not_define_are_listed_with_models_dev_details(self):
        proc = self.run_offline(
            "openai",
            listing("gpt-6.2-sol", "gpt-6.2-astra"),
            models_dev("openai", **{"gpt-6.2-sol": detail("GPT-6.2 Sol"), "gpt-6.2-astra": detail("GPT-6.2 Astra")}),
        )
        rows = self.rows_of(proc)
        self.assertEqual([row["id"] for row in rows], ["gpt-6.2-astra", "gpt-6.2-sol"])
        self.assertEqual(
            rows[1],
            {
                "id": "gpt-6.2-sol",
                "name": "GPT-6.2 Sol",
                "reasoning": True,
                "input": ["text", "image"],
                "cost": {"input": 2.5, "output": 15, "cacheRead": 0.25, "cacheWrite": 3},
                "contextWindow": 1050000,
                "maxTokens": 128000,
            },
        )

    def test_the_openai_filter_and_version_floor_pick_only_current_families(self):
        ids = ["gpt-5.6-sol", "gpt-6-sol", "gpt-6.1-sol", "gpt-6.1", "gpt-6.1-codex-spark", "gpt-5-mini", "o3"]
        proc = self.run_offline("openai", listing(*ids), self.openai_dev(*ids))
        self.assertEqual(self.ids_of(proc), ["gpt-6.1-sol"])

    def test_the_openai_floor_is_numeric_and_covers_later_versions(self):
        ids = ["gpt-6.10-sol", "gpt-6.2-sol", "gpt-7-sol", "gpt-6.0-sol", "gpt-6.1.2-sol", "gpt-6..1-sol"]
        proc = self.run_offline("openai", listing(*ids), self.openai_dev(*ids))
        self.assertEqual(self.ids_of(proc), ["gpt-6.10-sol", "gpt-6.2-sol", "gpt-7-sol"])
        self.assertIn("gpt-6.1.2-sol has a version this tool cannot read", proc.stderr)
        self.assertIn("gpt-6..1-sol has a version this tool cannot read", proc.stderr)

    def test_a_filtered_in_model_without_a_models_dev_entry_is_named_and_left_out(self):
        proc = self.run_offline(
            "openai", listing("gpt-6.3-sol", "gpt-6.2-sol"), self.openai_dev("gpt-6.2-sol")
        )
        self.assertEqual(self.ids_of(proc), ["gpt-6.2-sol"])
        self.assertIn("gpt-6.3-sol passes the openai filter but models.dev has no entry", proc.stderr)

    def test_a_models_dev_entry_without_limits_is_named_and_left_out(self):
        documented = models_dev(
            "openai", **{"gpt-6.2-sol": detail("Sol"), "gpt-6.2-astra": detail("Astra", limit={"context": 1})}
        )
        proc = self.run_offline("openai", listing("gpt-6.2-sol", "gpt-6.2-astra"), documented)
        self.assertEqual(self.ids_of(proc), ["gpt-6.2-sol"])
        self.assertIn("gpt-6.2-astra: no usable context and output limits", proc.stderr)

    def test_missing_models_dev_fields_get_conservative_defaults(self):
        documented = models_dev("openai", **{"gpt-6.2-sol": {"limit": {"context": 100, "output": 10}}})
        row = self.rows_of(self.run_offline("openai", listing("gpt-6.2-sol"), documented))[0]
        self.assertEqual(row["name"], "gpt-6.2-sol")
        self.assertEqual(row["input"], ["text"])
        self.assertIs(row["reasoning"], False)
        self.assertEqual(row["cost"], {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0})

    def test_anthropic_api_limits_override_models_dev_and_cost_stays(self):
        api = {
            "data": [
                {"id": "claude-opus-5-5", "max_input_tokens": 900000, "max_tokens": 64000},
                {"id": "claude-sonnet-5-5", "max_input_tokens": None, "max_tokens": None},
            ]
        }
        rows = self.rows_of(
            self.run_offline("anthropic", api, self.anthropic_dev("claude-opus-5-5", "claude-sonnet-5-5"))
        )
        self.assertEqual((rows[0]["contextWindow"], rows[0]["maxTokens"]), (900000, 64000))
        self.assertEqual(rows[0]["cost"]["input"], 2.5)
        self.assertEqual((rows[1]["contextWindow"], rows[1]["maxTokens"]), (1050000, 128000))

    def test_anthropic_keeps_dated_ids_and_drops_ids_that_fail_the_filter_or_are_not_active(self):
        api = {
            "data": [
                {"id": "claude-haiku-4-5-20251001"},
                {"id": "claude-haiku-4-5"},
                {"id": "claude-opus-5-5", "lifecycle": "deprecated"},
                {"id": "claude-instant"},
                {"id": "claude-3-opus"},
            ]
        }
        dev = self.anthropic_dev("claude-haiku-4-5-20251001", "claude-haiku-4-5", "claude-opus-5-5", "claude-3-opus")
        self.assertEqual(self.ids_of(self.run_offline("anthropic", api, dev)), ["claude-haiku-4-5", "claude-haiku-4-5-20251001"])

    def test_a_response_with_more_pages_is_refused(self):
        proc = self.run_offline(
            "anthropic",
            listing("claude-opus-5-5", has_more=True),
            self.anthropic_dev("claude-opus-5-5"),
            ["--snapshot", str(self.snapshot)],
        )
        self.assertEqual(proc.returncode, 1)
        self.assertIn("more pages", proc.stderr)
        self.assertFalse(self.snapshot.exists())

    def test_a_list_entry_without_an_id_is_skipped_with_a_warning(self):
        api = {"data": [{"object": "model"}, {"id": "gpt-6.2-sol"}]}
        proc = self.run_offline("openai", api, self.openai_dev("gpt-6.2-sol"))
        self.assertEqual(self.ids_of(proc), ["gpt-6.2-sol"])
        self.assertIn("without an id", proc.stderr)

    def test_a_body_without_a_data_list_is_refused(self):
        proc = self.run_offline("openai", {"models": []}, self.openai_dev("gpt-6.2-sol"))
        self.assertEqual(proc.returncode, 1)
        self.assertIn("no data list", proc.stderr)

    def test_a_models_dev_document_without_the_provider_is_refused(self):
        proc = self.run_offline("openai", listing("gpt-6.2-sol"), {"anthropic": {"models": {}}})
        self.assertEqual(proc.returncode, 1)
        self.assertIn("models.dev has no openai models", proc.stderr)

    def test_an_empty_result_is_refused_and_leaves_the_file(self):
        self.snapshot.write_text('{"models": [{"id": "kept"}]}\n')
        before = self.snapshot.read_bytes()
        proc = self.run_offline(
            "openai",
            listing("gpt-5.5", "text-embedding-3-large"),
            self.openai_dev("gpt-5.5"),
            ["--snapshot", str(self.snapshot)],
        )
        self.assertEqual(proc.returncode, 1)
        self.assertIn("no listed openai model passes the filter", proc.stderr)
        self.assertEqual(self.snapshot.read_bytes(), before)

    def test_a_refresh_replaces_a_wide_snapshot_and_sorts_by_id(self):
        self.snapshot.write_text(json.dumps({"models": [{"id": f"old-{i}"} for i in range(40)]}))
        proc = self.run_offline(
            "openai",
            listing("gpt-6.2-sol", "gpt-6.1-sol"),
            self.openai_dev("gpt-6.2-sol", "gpt-6.1-sol"),
            ["--snapshot", str(self.snapshot)],
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual([m["id"] for m in json.loads(self.snapshot.read_text())["models"]], ["gpt-6.1-sol", "gpt-6.2-sol"])

    def test_an_unchanged_result_does_not_touch_the_file(self):
        args = (listing("gpt-6.2-sol"), self.openai_dev("gpt-6.2-sol"), ["--snapshot", str(self.snapshot)])
        self.run_offline("openai", *args)
        os.utime(self.snapshot, (1, 1))
        self.run_offline("openai", *args)
        self.assertEqual(self.snapshot.stat().st_mtime, 1)

    def test_openai_sends_a_bearer_header_on_stdin_and_refuses_redirects(self):
        outcomes = [json.dumps(listing("gpt-6.2-sol")), json.dumps(self.openai_dev("gpt-6.2-sol"))]
        proc = self.run_watch("openai", outcomes)
        self.assertEqual(self.ids_of(proc), ["gpt-6.2-sol"])
        calls = json.loads(self.log.read_text())
        self.assertEqual(len(calls), 2)
        self.assertEqual(calls[0]["argv"][-1], "https://api.openai.com/v1/models")
        self.assertIn("--max-redirs", calls[0]["argv"])
        self.assertEqual(calls[0]["stdin"], "Authorization: Bearer FAKE-KEY\n")
        self.assertNotIn("FAKE-KEY", " ".join(calls[0]["argv"]))

    def test_anthropic_sends_its_key_header_on_stdin_and_asks_for_active_models(self):
        outcomes = [json.dumps(listing("claude-opus-5-5")), json.dumps(self.anthropic_dev("claude-opus-5-5"))]
        proc = self.run_watch("anthropic", outcomes)
        self.assertEqual(self.ids_of(proc), ["claude-opus-5-5"])
        first = json.loads(self.log.read_text())[0]
        self.assertEqual(first["argv"][-1], "https://api.anthropic.com/v1/models?lifecycle=active&limit=1000")
        self.assertIn("--max-redirs", first["argv"])
        self.assertIn("x-api-key: FAKE-KEY\n", first["stdin"])
        self.assertIn("anthropic-version: ", first["stdin"])
        self.assertNotIn("FAKE-KEY", " ".join(first["argv"]))

    def test_models_dev_is_fetched_without_a_key(self):
        outcomes = [json.dumps(listing("gpt-6.2-sol")), json.dumps(self.openai_dev("gpt-6.2-sol"))]
        self.run_watch("openai", outcomes)
        second = json.loads(self.log.read_text())[1]
        self.assertEqual(second["argv"][-1], "https://models.dev/api.json")
        self.assertEqual(second["stdin"], "")
        self.assertNotIn("-H", second["argv"])
        self.assertNotIn("--max-redirs", second["argv"])

    def test_a_missing_key_fails_before_any_fetch(self):
        proc = self.run_watch("openai", key="")
        self.assertEqual(proc.returncode, 1)
        self.assertIn("OPENAI_API_KEY is not set", proc.stderr)
        self.assertFalse(self.log.exists())

    def test_one_failed_fetch_is_retried_and_two_leave_the_snapshot(self):
        documented = json.dumps(self.openai_dev("gpt-6.2-sol"))
        proc = self.run_watch(
            "openai", [22, json.dumps(listing("gpt-6.2-sol")), documented], ["--snapshot", str(self.snapshot)]
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(len(json.loads(self.log.read_text())), 3)

        before = self.snapshot.read_bytes()
        self.log.unlink()
        proc = self.run_watch("openai", [22, "not json"], ["--snapshot", str(self.snapshot)])
        self.assertEqual(proc.returncode, 1)
        self.assertIn("failed twice", proc.stderr)
        self.assertEqual(self.snapshot.read_bytes(), before)

    def test_a_failed_models_dev_fetch_leaves_the_snapshot(self):
        self.snapshot.write_text('{"models": [{"id": "kept"}]}\n')
        before = self.snapshot.read_bytes()
        proc = self.run_watch(
            "openai", [json.dumps(listing("gpt-6.2-sol")), 22, 22], ["--snapshot", str(self.snapshot)]
        )
        self.assertEqual(proc.returncode, 1)
        self.assertIn("https://models.dev/api.json", proc.stderr)
        self.assertIn("failed twice", proc.stderr)
        self.assertEqual(self.snapshot.read_bytes(), before)

    def test_a_key_echoed_in_curl_stderr_is_not_logged(self):
        leak = {"status": 22, "stderr": "curl: (22) rejected key FAKE-KEY"}
        proc = self.run_watch("openai", [leak, leak])
        self.assertEqual(proc.returncode, 1)
        self.assertIn("failed twice", proc.stderr)
        self.assertNotIn("FAKE-KEY", proc.stderr)


class CommittedSnapshotTestCase(unittest.TestCase):
    def test_each_committed_snapshot_is_sorted_distinct_complete_rows_that_pass_the_filter(self):
        sys.path.insert(0, str(ROOT / "scripts"))
        loader = importlib.machinery.SourceFileLoader("provider_models_watch", str(SCRIPT))
        spec = importlib.util.spec_from_loader(loader.name, loader)
        watch = importlib.util.module_from_spec(spec)
        loader.exec_module(watch)
        for provider in KEYS:
            with self.subTest(provider):
                rows = json.loads((ROOT / f"home/h82/agents/{provider}-models.json").read_text())["models"]
                ids = [row["id"] for row in rows]
                self.assertTrue(ids)
                self.assertEqual(ids, sorted(set(ids)))
                for row in rows:
                    self.assertTrue(watch.passes_filter(provider, row["id"]), row["id"])
                    self.assertEqual(
                        sorted(row), ["contextWindow", "cost", "id", "input", "maxTokens", "name", "reasoning"]
                    )
                    self.assertEqual(sorted(row["cost"]), ["cacheRead", "cacheWrite", "input", "output"])


if __name__ == "__main__":
    unittest.main()
