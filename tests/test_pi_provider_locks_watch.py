"""Drive pi-provider-locks-watch against fake provider lists and Pi catalogs.

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
SCRIPT = ROOT / "scripts/pi-provider-locks-watch"
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
sys.stdout.write(outcome)
"""


def listing(*ids, **extra):
    return {"data": [{"id": model_id} for model_id in ids], **extra}


def pi_catalog(provider, *rows):
    return {provider: [{"id": model_id, "type": kind} if kind else {"id": model_id} for model_id, kind in rows]}


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
        self.release = self.root / "pi-release.json"
        self.release.write_text(json.dumps({"source": {"rev": "abc123"}}))

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

    def run_offline(self, provider, api, catalog, extra=None):
        return self.run_watch(
            provider,
            extra=["--catalog", self.write("api.json", api), "--pi-catalog", self.write("pi.json", catalog)]
            + (extra or []),
        )

    def ids_of(self, proc):
        self.assertEqual(proc.returncode, 0, proc.stderr)
        return [row["id"] for row in json.loads(proc.stdout)["data"]]

    def test_keeps_only_listed_chat_models_that_pi_defines(self):
        proc = self.run_offline(
            "openai",
            listing("text-embedding-3-large", "gpt-5.5", "gpt-brand-new"),
            pi_catalog("openai", ("gpt-5.5", "chat"), ("text-embedding-3-large", "embedding"), ("gpt-4", "chat")),
        )
        self.assertEqual(self.ids_of(proc), ["gpt-5.5"])

    def test_an_id_with_a_chat_and_a_classifier_entry_is_listed_once(self):
        proc = self.run_offline(
            "openai",
            listing("gpt-6-luna", "gpt-5.5"),
            pi_catalog("openai", ("gpt-6-luna", "chat"), ("gpt-6-luna", "classifier"), ("gpt-5.5", "chat")),
        )
        self.assertEqual(self.ids_of(proc), ["gpt-5.5", "gpt-6-luna"])

    def test_a_classifier_only_id_is_not_kept(self):
        proc = self.run_offline(
            "openai",
            listing("gpt-6-luna", "gpt-5.5"),
            pi_catalog("openai", ("gpt-6-luna", "classifier"), ("gpt-5.5", "chat")),
        )
        self.assertEqual(self.ids_of(proc), ["gpt-5.5"])

    def test_a_catalog_row_without_a_type_is_a_chat_model(self):
        proc = self.run_offline("anthropic", listing("claude-opus-5"), pi_catalog("anthropic", ("claude-opus-5", None)))
        self.assertEqual(self.ids_of(proc), ["claude-opus-5"])

    def test_ids_are_sorted(self):
        proc = self.run_offline(
            "openai", listing("b", "a"), pi_catalog("openai", ("b", "chat"), ("a", "chat"))
        )
        self.assertEqual(self.ids_of(proc), ["a", "b"])

    def test_a_model_that_is_not_active_is_excluded(self):
        api = {"data": [{"id": "old", "lifecycle": "deprecated"}, {"id": "new", "lifecycle": "active"}]}
        proc = self.run_offline("anthropic", api, pi_catalog("anthropic", ("old", "chat"), ("new", "chat")))
        self.assertEqual(self.ids_of(proc), ["new"])

    def test_a_response_with_more_pages_is_refused(self):
        proc = self.run_offline(
            "anthropic",
            listing("claude-opus-5", has_more=True),
            pi_catalog("anthropic", ("claude-opus-5", "chat")),
            ["--snapshot", str(self.snapshot)],
        )
        self.assertEqual(proc.returncode, 1)
        self.assertIn("more pages", proc.stderr)
        self.assertFalse(self.snapshot.exists())

    def test_a_list_entry_without_an_id_is_skipped_with_a_warning(self):
        api = {"data": [{"object": "model"}, {"id": "gpt-5.5"}]}
        proc = self.run_offline("openai", api, pi_catalog("openai", ("gpt-5.5", "chat")))
        self.assertEqual(self.ids_of(proc), ["gpt-5.5"])
        self.assertIn("without an id", proc.stderr)

    def test_a_snapshot_seeded_wide_narrows_in_one_refresh(self):
        wide = [f"model-{i:02d}" for i in range(44)]
        self.snapshot.write_text(json.dumps({"data": [{"id": i} for i in wide]}))
        proc = self.run_offline(
            "openai",
            listing(*wide[:10]),
            pi_catalog("openai", *[(i, "chat") for i in wide]),
            ["--snapshot", str(self.snapshot)],
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual([m["id"] for m in json.loads(self.snapshot.read_text())["data"]], wide[:10])

    def test_an_empty_result_is_refused_and_leaves_the_file(self):
        self.snapshot.write_text('{"data": [{"id": "kept"}]}\n')
        before = self.snapshot.read_bytes()
        proc = self.run_offline(
            "openai", listing("embed"), pi_catalog("openai", ("gpt-5.5", "chat")), ["--snapshot", str(self.snapshot)]
        )
        self.assertEqual(proc.returncode, 1)
        self.assertIn("no listed model", proc.stderr)
        self.assertEqual(self.snapshot.read_bytes(), before)

    def test_an_unchanged_result_does_not_touch_the_file(self):
        args = (listing("a"), pi_catalog("openai", ("a", "chat")), ["--snapshot", str(self.snapshot)])
        self.run_offline("openai", *args)
        os.utime(self.snapshot, (1, 1))
        self.run_offline("openai", *args)
        self.assertEqual(self.snapshot.stat().st_mtime, 1)

    def test_openai_sends_a_bearer_header_on_stdin_and_refuses_redirects(self):
        outcomes = [
            json.dumps(listing("gpt-5.5")),
            json.dumps({"revision": "sha256-pin"}),
            json.dumps(pi_catalog("openai", ("gpt-5.5", "chat"))),
        ]
        proc = self.run_watch("openai", outcomes, ["--release", str(self.release)])
        self.assertEqual(self.ids_of(proc), ["gpt-5.5"])
        calls = json.loads(self.log.read_text())
        self.assertEqual(len(calls), 3)
        self.assertEqual(calls[0]["argv"][-1], "https://api.openai.com/v1/models")
        self.assertIn("--max-redirs", calls[0]["argv"])
        self.assertEqual(calls[0]["stdin"], "Authorization: Bearer FAKE-KEY\n")
        self.assertNotIn("FAKE-KEY", " ".join(calls[0]["argv"]))

    def test_anthropic_sends_its_key_header_on_stdin_and_asks_for_active_models(self):
        outcomes = [
            json.dumps(listing("claude-opus-5")),
            json.dumps({"revision": "sha256-pin"}),
            json.dumps(pi_catalog("anthropic", ("claude-opus-5", "chat"))),
        ]
        proc = self.run_watch("anthropic", outcomes, ["--release", str(self.release)])
        self.assertEqual(self.ids_of(proc), ["claude-opus-5"])
        first = json.loads(self.log.read_text())[0]
        self.assertEqual(first["argv"][-1], "https://api.anthropic.com/v1/models?lifecycle=active&limit=1000")
        self.assertIn("--max-redirs", first["argv"])
        self.assertIn("x-api-key: FAKE-KEY\n", first["stdin"])
        self.assertIn("anthropic-version: ", first["stdin"])
        self.assertNotIn("FAKE-KEY", " ".join(first["argv"]))

    def test_the_pi_catalog_is_fetched_from_the_pinned_revision_without_a_key(self):
        outcomes = [
            json.dumps(listing("gpt-5.5")),
            json.dumps({"revision": "sha256-pin"}),
            json.dumps(pi_catalog("openai", ("gpt-5.5", "chat"))),
        ]
        self.run_watch("openai", outcomes, ["--release", str(self.release)])
        calls = json.loads(self.log.read_text())
        self.assertEqual(
            calls[1]["argv"][-1],
            "https://raw.githubusercontent.com/earendil-works/pi/abc123/nix/model-catalog.json",
        )
        self.assertEqual(
            calls[2]["argv"][-1], "https://pi.dev/api/models/revisions/sha256-pin?types=chat,image,classifier"
        )
        for call in calls[1:]:
            self.assertEqual(call["stdin"], "")
            self.assertNotIn("-H", call["argv"])
            self.assertNotIn("--max-redirs", call["argv"])

    def test_a_missing_key_fails_before_any_fetch(self):
        proc = self.run_watch("openai", extra=["--release", str(self.release)], key="")
        self.assertEqual(proc.returncode, 1)
        self.assertIn("OPENAI_API_KEY is not set", proc.stderr)
        self.assertFalse(self.log.exists())

    def test_one_failed_fetch_is_retried_and_two_leave_the_snapshot(self):
        catalog = [json.dumps({"revision": "sha256-pin"}), json.dumps(pi_catalog("openai", ("gpt-5.5", "chat")))]
        proc = self.run_watch(
            "openai",
            [22, json.dumps(listing("gpt-5.5"))] + catalog,
            ["--release", str(self.release), "--snapshot", str(self.snapshot)],
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(len(json.loads(self.log.read_text())), 4)

        before = self.snapshot.read_bytes()
        self.log.unlink()
        proc = self.run_watch(
            "openai", [22, "not json"], ["--release", str(self.release), "--snapshot", str(self.snapshot)]
        )
        self.assertEqual(proc.returncode, 1)
        self.assertIn("failed twice", proc.stderr)
        self.assertEqual(self.snapshot.read_bytes(), before)

    def test_a_body_without_a_data_list_is_refused(self):
        proc = self.run_offline("openai", {"models": []}, pi_catalog("openai", ("a", "chat")))
        self.assertEqual(proc.returncode, 1)
        self.assertIn("no data list", proc.stderr)


class CommittedSnapshotTestCase(unittest.TestCase):
    def test_each_committed_snapshot_is_sorted_distinct_ids(self):
        for provider in KEYS:
            with self.subTest(provider):
                path = ROOT / f"home/h82/agents/pi-{provider}-model-lock.json"
                ids = [row["id"] for row in json.loads(path.read_text())["data"]]
                self.assertTrue(ids)
                self.assertEqual(ids, sorted(set(ids)))
                self.assertTrue(all(isinstance(i, str) and i for i in ids))


if __name__ == "__main__":
    unittest.main()
