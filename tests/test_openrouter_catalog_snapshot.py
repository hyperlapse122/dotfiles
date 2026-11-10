"""Drive openrouter-catalog-snapshot against a trimmed 2026-10-23 sample.

The fixture is a handful of whole rows from OpenRouter's public /models
endpoint. These tests record what a stub `curl` on `PATH` received instead of
making network calls.
"""

import copy
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/openrouter-catalog-snapshot"
FIXTURE = ROOT / "tests/fixtures/openrouter-models/models-2026-10-23.json"
URL = "https://openrouter.ai/api/v1/models/user"
KEY = "sk-or-v1-fake-0123456789"

GPT5 = "openai/gpt-5"
AUTO = "openrouter/auto"
IMAGE = "google/gemini-3.1-flash-image"

# Records its argv, stdin, and whether the key reached its environment, then
# prints the catalog file it is given.
FAKE_FETCH = """#!{python}
import json, os, sys
json.dump({{'argv': sys.argv[1:], 'stdin': sys.stdin.read(),
           'env_has_key': 'OPENROUTER_API_KEY' in os.environ}}, open(os.environ['FAKE_LOG'], 'w'))
sys.stdout.write(open(os.environ['FAKE_CATALOG']).read())
"""


def fixture():
    return json.loads(FIXTURE.read_text())


def row_of(catalog, model_id):
    return next(m for m in catalog["data"] if m["id"] == model_id)


class SnapshotTest(unittest.TestCase):
    SENTINEL = "untouched\n"

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.out = self.root / "openrouter-catalog.json"
        self.out.write_text(self.SENTINEL)

    def run_snapshot(self, catalog):
        path = self.root / "catalog.json"
        path.write_text(json.dumps(catalog))
        env = dict(os.environ)
        env.pop("OPENROUTER_API_KEY", None)
        return subprocess.run(
            [sys.executable, str(SCRIPT), "--catalog", str(path), "--snapshot", str(self.out)],
            capture_output=True, text=True, env=env,
        )

    def written(self):
        return json.loads(self.out.read_text())["data"]

    def test_every_text_row_keeps_only_the_fields_omp_renders(self):
        catalog = fixture()
        proc = self.run_snapshot(catalog)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertTrue(self.out.read_text().endswith("}\n"))
        written = self.written()
        self.assertEqual([m["id"] for m in written], sorted(m["id"] for m in catalog["data"]))
        for entry in written:
            upstream = row_of(catalog, entry["id"])
            expected = {
                "id": upstream["id"],
                "name": upstream["name"],
                "architecture": {
                    "input_modalities": upstream["architecture"]["input_modalities"],
                    "output_modalities": upstream["architecture"]["output_modalities"],
                },
                "context_length": upstream["context_length"],
            }
            if "reasoning" in upstream:
                expected["reasoning"] = upstream["reasoning"]
            self.assertEqual(entry, expected)
        auto = row_of({"data": written}, AUTO)
        self.assertNotIn("reasoning", auto)
        self.assertEqual(
            row_of({"data": written}, GPT5)["reasoning"]["supported_efforts"],
            ["high", "medium", "low", "minimal"],
        )

    def test_volatile_metadata_neither_changes_nor_invalidates_the_snapshot(self):
        self.assertEqual(self.run_snapshot(fixture()).returncode, 0)
        first = self.out.read_text()
        for replacement in (None, {}, "invalid", {"prompt": "999", "context_length": 1}):
            catalog = fixture()
            for row in catalog["data"]:
                row["pricing"] = replacement
                row["top_provider"] = replacement
            with self.subTest(replacement=replacement):
                proc = self.run_snapshot(catalog)
                self.assertEqual(proc.returncode, 0, proc.stderr)
                self.assertEqual(self.out.read_text(), first)
        catalog = fixture()
        for row in catalog["data"]:
            row.pop("pricing", None)
            row.pop("top_provider", None)
        proc = self.run_snapshot(catalog)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(self.out.read_text(), first)

    def test_retained_legacy_rows_lose_volatile_metadata(self):
        self.out.write_text(json.dumps(fixture()))
        catalog = fixture()
        row_of(catalog, GPT5)["context_length"] = "400k"
        proc = self.run_snapshot(catalog)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn(GPT5, proc.stderr)
        self.assertEqual(row_of({"data": self.written()}, GPT5)["context_length"],
                         row_of(fixture(), GPT5)["context_length"])
        for row in self.written():
            self.assertNotIn("pricing", row)
            self.assertNotIn("top_provider", row)

    def test_a_row_whose_output_lacks_text_is_skipped(self):
        catalog = fixture()
        row_of(catalog, IMAGE)["architecture"]["output_modalities"] = ["image"]
        proc = self.run_snapshot(catalog)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        ids = [m["id"] for m in self.written()]
        self.assertNotIn(IMAGE, ids)
        self.assertEqual(len(ids), len(catalog["data"]) - 1)

    def test_a_malformed_row_is_skipped_and_named_or_keeps_its_previous_entry(self):
        catalog = fixture()
        row_of(catalog, GPT5)["context_length"] = "400k"
        proc = self.run_snapshot(catalog)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn(GPT5, proc.stderr)
        ids = [m["id"] for m in self.written()]
        self.assertNotIn(GPT5, ids)
        self.assertEqual(len(ids), len(catalog["data"]) - 1)

        self.assertEqual(self.run_snapshot(fixture()).returncode, 0)
        first = self.out.read_text()
        proc = self.run_snapshot(catalog)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn(GPT5, proc.stderr)
        self.assertEqual(self.out.read_text(), first)

    def test_a_snapshot_that_shrinks_below_the_retention_floor_is_refused(self):
        self.assertEqual(self.run_snapshot(fixture()).returncode, 0)
        first = self.out.read_text()
        truncated = copy.deepcopy(fixture())
        truncated["data"] = truncated["data"][:2]
        proc = self.run_snapshot(truncated)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("shrank from 6 to 2 models (floor 5)", proc.stderr)
        self.assertEqual(self.out.read_text(), first)

    def test_an_empty_result_exits_non_zero_and_leaves_the_file(self):
        only_image = copy.deepcopy(fixture())
        only_image["data"] = [row_of(only_image, IMAGE)]
        only_image["data"][0]["architecture"]["output_modalities"] = ["image"]
        for label, catalog in {"empty data": {"data": []}, "no text row": only_image}.items():
            with self.subTest(label):
                proc = self.run_snapshot(catalog)
                self.assertNotEqual(proc.returncode, 0)
                self.assertEqual(self.out.read_text(), self.SENTINEL)

    def test_a_second_run_leaves_the_file_as_it_is(self):
        self.assertEqual(self.run_snapshot(fixture()).returncode, 0)
        first = self.out.read_text()
        os.utime(self.out, (1, 1))
        self.assertEqual(self.run_snapshot(fixture()).returncode, 0)
        self.assertEqual(self.out.read_text(), first)
        self.assertEqual(self.out.stat().st_mtime, 1)


class FetchTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.out = self.root / "openrouter-catalog.json"
        self.log = self.root / "fetch-log.json"
        self.stubs = self.root / "bin"
        self.stubs.mkdir()
        catalog = self.root / "served.json"
        catalog.write_text(json.dumps(fixture()))
        self.env = dict(os.environ)
        self.env.pop("OPENROUTER_API_KEY", None)
        self.env.update({
            "PATH": f"{self.stubs}:{self.env.get('PATH', '')}",
            "FAKE_LOG": str(self.log),
            "FAKE_CATALOG": str(catalog),
        })

    def run_fetch(self, **env):
        return subprocess.run(
            [sys.executable, str(SCRIPT), "--snapshot", str(self.out)],
            capture_output=True, text=True, env={**self.env, **env},
        )

    def test_the_default_fetch_is_curl_with_the_key_on_stdin_only(self):
        curl = self.stubs / "curl"
        curl.write_text(FAKE_FETCH.format(python=sys.executable))
        curl.chmod(0o755)
        proc = self.run_fetch(OPENROUTER_API_KEY=KEY)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        call = json.loads(self.log.read_text())
        self.assertEqual(call["argv"], ["-sSfL", "--max-time", "60", "-H", "@-", URL])
        self.assertEqual(call["stdin"], f"Authorization: Bearer {KEY}\n")
        self.assertFalse(call["env_has_key"])
        for text in (proc.stdout, proc.stderr, self.out.read_text()):
            self.assertNotIn(KEY, text)
        self.assertEqual(len(json.loads(self.out.read_text())["data"]), len(fixture()["data"]))

    def test_a_missing_key_exits_non_zero_without_fetching(self):
        curl = self.stubs / "curl"
        curl.write_text(FAKE_FETCH.format(python=sys.executable))
        curl.chmod(0o755)
        for key in (None, ""):
            with self.subTest(key=key):
                env = {}
                if key is not None:
                    env["OPENROUTER_API_KEY"] = key
                proc = self.run_fetch(**env)
                self.assertNotEqual(proc.returncode, 0)
                self.assertIn("OPENROUTER_API_KEY", proc.stderr)
                self.assertFalse(self.log.exists())
                self.assertFalse(self.out.exists())


if __name__ == "__main__":
    unittest.main()
