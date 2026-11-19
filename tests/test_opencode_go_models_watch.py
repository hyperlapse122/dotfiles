"""Drive opencode-go-models-watch against fake OpenCode Go catalogs.

The helper's `curl` command is stubbed on `PATH`, so these tests feed it
fixture bodies and record what it was asked instead of making network calls.
"""

import copy
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/opencode-go-models-watch"
URL = "https://opencode.ai/inference/go/v1/models"
PROTOCOL_BASES = {
    "chat-completions": "https://opencode.ai/inference/go/openai/v1",
    "responses": "https://opencode.ai/inference/go/openai/v1",
    "messages": "https://opencode.ai/inference/go/anthropic/v1",
    "generate-content": "https://opencode.ai/inference/go/google/v1",
}

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


def row(model_id, protocol="chat-completions", cost=True, **extra):
    entry = {
        "id": model_id,
        "object": "model",
        "name": model_id.title(),
        "type": "chat",
        "recommended_api": protocol,
        "api": {
            protocol: {
                "base_url": PROTOCOL_BASES[protocol],
                "sdk": {"aisdk": "@ai-sdk/openai-compatible"},
                "capabilities": {"tools": {"choice": ["auto"]}},
            }
        },
        "limit": {"context": 200000, "output": 64000},
    }
    if cost:
        entry["cost"] = {
            "text": {"input": {"price": 1.5, "cache": {"read": 0.15}}, "output": {"price": 6}},
            "multipliers": [{"factor": 2}],
        }
    entry.update(extra)
    return entry


def catalog(*rows):
    return {"object": "list", "data": list(rows)}


def many(count):
    return catalog(*[row(f"model-{i:02d}") for i in range(count)])


class OpencodeGoWatchTestCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.bin_dir = root / "bin"
        self.bin_dir.mkdir()
        curl = self.bin_dir / "curl"
        curl.write_text(FAKE_CURL.format(python=sys.executable))
        curl.chmod(0o755)
        self.log = root / "curl.json"
        self.snapshot = root / "opencode-go-catalog.json"

    def run_watch(self, outcomes=None, extra=None):
        env = dict(os.environ)
        env["PATH"] = f"{self.bin_dir}:{env.get('PATH', '')}"
        env["FAKE_LOG"] = str(self.log)
        env["FAKE_OUTCOMES"] = json.dumps(outcomes or [])
        args = [sys.executable, str(SCRIPT), "--retry-wait", "0"] + (extra or [])
        return subprocess.run(args, capture_output=True, text=True, env=env)

    def snapshot_of(self, body, extra=None):
        proc = self.run_watch([json.dumps(body)], ["--snapshot", str(self.snapshot)] + (extra or []))
        self.assertEqual(proc.returncode, 0, proc.stderr)
        return json.loads(self.snapshot.read_text())

    def test_keeps_the_fields_the_render_reads_and_drops_the_rest(self):
        data = self.snapshot_of(catalog(row("alpha")))["data"]
        self.assertEqual(
            data,
            [
                {
                    "id": "alpha",
                    "name": "Alpha",
                    "recommended_api": "chat-completions",
                    "api": {"chat-completions": {"base_url": PROTOCOL_BASES["chat-completions"]}},
                    "limit": {"context": 200000, "output": 64000},
                    "cost": {"text": {"input": {"price": 1.5, "cache": {"read": 0.15}}, "output": {"price": 6}}},
                }
            ],
        )

    def test_every_protocol_kind_validates_and_keeps_its_base_url(self):
        body = catalog(*[row(f"model-{p}", protocol=p) for p in PROTOCOL_BASES])
        data = {m["id"]: m for m in self.snapshot_of(body)["data"]}
        self.assertEqual(len(data), 4)
        for protocol, base in PROTOCOL_BASES.items():
            entry = data[f"model-{protocol}"]
            self.assertEqual(entry["recommended_api"], protocol)
            self.assertEqual(entry["api"], {protocol: {"base_url": base}})

    def test_a_row_without_cost_keeps_none(self):
        data = self.snapshot_of(catalog(row("free", cost=False)))["data"]
        self.assertNotIn("cost", data[0])

    def test_rows_are_sorted_by_id(self):
        data = self.snapshot_of(catalog(row("zeta"), row("alpha")))["data"]
        self.assertEqual([m["id"] for m in data], ["alpha", "zeta"])

    def test_fetches_the_catalog_url_without_a_key(self):
        proc = self.run_watch([json.dumps(catalog(row("alpha")))])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        calls = json.loads(self.log.read_text())
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0]["argv"][-1], URL)
        self.assertNotIn("-H", calls[0]["argv"])
        self.assertEqual(calls[0]["stdin"], "")
        self.assertEqual(json.loads(proc.stdout)["data"][0]["id"], "alpha")

    def test_a_snapshot_below_the_retention_floor_leaves_the_file_alone(self):
        self.snapshot_of(many(10))
        before = self.snapshot.read_bytes()
        proc = self.run_watch([json.dumps(many(7))], ["--snapshot", str(self.snapshot)])
        self.assertEqual(proc.returncode, 1)
        self.assertIn("shrank from 10 to 7", proc.stderr)
        self.assertEqual(self.snapshot.read_bytes(), before)

    def test_a_snapshot_at_the_retention_floor_is_written(self):
        self.snapshot_of(many(10))
        data = self.snapshot_of(many(8))["data"]
        self.assertEqual(len(data), 8)

    def test_an_unchanged_catalog_does_not_touch_the_file(self):
        self.snapshot_of(many(3))
        os.utime(self.snapshot, (1, 1))
        self.snapshot_of(many(3))
        self.assertEqual(self.snapshot.stat().st_mtime, 1)

    def test_a_malformed_row_is_skipped_and_its_previous_entry_survives(self):
        self.snapshot_of(catalog(row("alpha"), row("beta")))
        broken = row("beta", protocol="messages")
        broken["api"]["messages"]["base_url"] = "http://insecure.example"
        proc = self.run_watch(
            [json.dumps(catalog(row("alpha"), broken, row("gamma")))],
            ["--snapshot", str(self.snapshot)],
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("skipping catalog entry beta", proc.stderr)
        data = {m["id"]: m for m in json.loads(self.snapshot.read_text())["data"]}
        self.assertEqual(sorted(data), ["alpha", "beta", "gamma"])
        self.assertEqual(data["beta"]["recommended_api"], "chat-completions")

    def test_each_malformed_shape_is_skipped(self):
        def mutate(change):
            entry = copy.deepcopy(row("bad"))
            change(entry)
            return entry

        shapes = {
            "unknown protocol": lambda e: e["api"].update({"carrier-pigeon": {"base_url": "https://x"}}),
            "recommends an absent protocol": lambda e: e.update({"recommended_api": "responses"}),
            "no limit": lambda e: e.pop("limit"),
            "string context": lambda e: e["limit"].update({"context": "big"}),
            "no name": lambda e: e.pop("name"),
            "cost without text": lambda e: e.update({"cost": {}}),
        }
        for label, change in shapes.items():
            with self.subTest(label):
                proc = self.run_watch(
                    [json.dumps(catalog(row("good"), mutate(change)))], ["--snapshot", str(self.snapshot)]
                )
                self.assertEqual(proc.returncode, 0, proc.stderr)
                self.assertIn("skipping catalog entry bad", proc.stderr)
                self.assertEqual([m["id"] for m in json.loads(self.snapshot.read_text())["data"]], ["good"])
                self.snapshot.unlink()

    def test_a_catalog_with_no_well_formed_row_is_refused(self):
        proc = self.run_watch([json.dumps(catalog({"id": "x"}))], ["--snapshot", str(self.snapshot)])
        self.assertEqual(proc.returncode, 1)
        self.assertIn("no well-formed models", proc.stderr)
        self.assertFalse(self.snapshot.exists())

    def test_a_body_without_a_data_list_is_refused(self):
        proc = self.run_watch([json.dumps({"models": []})], ["--snapshot", str(self.snapshot)])
        self.assertEqual(proc.returncode, 1)
        self.assertIn("no data list", proc.stderr)

    def test_one_failed_fetch_is_retried_and_two_leave_the_snapshot(self):
        proc = self.run_watch([22, json.dumps(catalog(row("alpha")))], ["--snapshot", str(self.snapshot)])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(len(json.loads(self.log.read_text())), 2)

        before = self.snapshot.read_bytes()
        self.log.unlink()
        proc = self.run_watch([22, "not json"], ["--snapshot", str(self.snapshot)])
        self.assertEqual(proc.returncode, 1)
        self.assertIn("failed twice", proc.stderr)
        self.assertEqual(self.snapshot.read_bytes(), before)

    def test_reads_the_catalog_from_a_file(self):
        source = Path(self.tmp.name) / "catalog.json"
        source.write_text(json.dumps(catalog(row("alpha"))))
        proc = self.run_watch(extra=["--catalog", str(source)])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertFalse(self.log.exists())
        self.assertEqual(json.loads(proc.stdout)["data"][0]["id"], "alpha")


class CommittedSnapshotTestCase(unittest.TestCase):
    def test_the_committed_snapshot_is_what_the_validator_accepts(self):
        path = Path(__file__).resolve().parents[1] / "home/h82/agents/opencode-go-catalog.json"
        committed = json.loads(path.read_text())
        proc = subprocess.run(
            [sys.executable, str(SCRIPT), "--catalog", str(path)], capture_output=True, text=True
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(json.loads(proc.stdout), committed)
        self.assertEqual(proc.stderr, "")


if __name__ == "__main__":
    unittest.main()
