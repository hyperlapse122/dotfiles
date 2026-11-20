"""Run opencode-serving-model against a scratch HOME holding an OpenCode 2.x database.

The fixture copies the `session_v2` and `session_message` columns the helper
reads. Rows carry the JSON shape OpenCode writes for assistant messages:
`model.providerID`, `model.id`, `time.completed`, and a `tokens` object.
"""

import hashlib
import json
import os
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/opencode-serving-model"

SCHEMA = """
CREATE TABLE session_v2 (id text PRIMARY KEY);
CREATE TABLE session_message (
  id text PRIMARY KEY,
  session_id text NOT NULL,
  type text NOT NULL,
  seq integer NOT NULL,
  time_created integer NOT NULL,
  time_updated integer NOT NULL,
  data text NOT NULL
);
"""


def assistant(provider, model, created, completed=True, tokens=True):
    data = {
        "model": {"id": model, "providerID": provider, "variant": "default"},
        "time": {"created": created},
        "content": [],
    }
    if completed:
        data["time"]["completed"] = created + 5
    if tokens:
        data["tokens"] = {"input": 10, "output": 5}
    return data


class ServingModelTest(unittest.TestCase):
    def setUp(self):
        self.home = Path(tempfile.mkdtemp())
        self.db = self.home / ".local/share/opencode/opencode.db"
        self.db.parent.mkdir(parents=True)
        self.conn = sqlite3.connect(self.db)
        self.conn.executescript(SCHEMA)
        self.seq = 0

    def add(self, session, kind, data, created, msg_id=None):
        self.seq += 1
        self.conn.execute("INSERT OR IGNORE INTO session_v2 VALUES (?)", (session,))
        self.conn.execute(
            "INSERT INTO session_message VALUES (?, ?, ?, ?, ?, ?, ?)",
            (msg_id or f"msg_{self.seq}", session, kind, self.seq, created, created, json.dumps(data)),
        )
        self.conn.commit()

    def run_helper(self, *args, session=None):
        env = {"HOME": str(self.home), "PATH": os.environ.get("PATH", "")}
        if session is not None:
            env["OPENCODE_SESSION_ID"] = session
        return subprocess.run(
            [sys.executable, str(SCRIPT), *args], env=env, capture_output=True, text=True
        )

    def test_prints_latest_completed_assistant_model(self):
        self.add("ses_a", "assistant", assistant("anthropic", "claude-opus-5-5", 100), 100)
        self.add("ses_a", "assistant", assistant("openai", "gpt-6.2-sol", 200), 200)
        result = self.run_helper(session="ses_a")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "openai/gpt-6.2-sol\n")

    def test_skips_incomplete_and_usage_less_rows(self):
        self.add("ses_a", "assistant", assistant("anthropic", "claude-opus-5-5", 100), 100)
        self.add("ses_a", "assistant", assistant("openai", "gpt-6.2-sol", 200, completed=False), 200)
        self.add("ses_a", "assistant", assistant("synthetic", "hf:zai-org/GLM-5.3", 300, tokens=False), 300)
        self.add("ses_a", "user", {"text": "hello"}, 400)
        result = self.run_helper(session="ses_a")
        self.assertEqual(result.stdout, "anthropic/claude-opus-5-5\n")

    def test_ignores_other_sessions(self):
        self.add("ses_a", "assistant", assistant("anthropic", "claude-opus-5-5", 100), 100)
        self.add("ses_b", "assistant", assistant("openai", "gpt-6.2-sol", 200), 200)
        self.assertEqual(self.run_helper(session="ses_a").stdout, "anthropic/claude-opus-5-5\n")
        self.assertEqual(self.run_helper("--session", "ses_b", session="ses_a").stdout, "openai/gpt-6.2-sol\n")

    def test_message_selects_its_session(self):
        self.add("ses_child", "assistant", assistant("openai", "gpt-6.2-terra", 100), 100, msg_id="msg_child")
        self.add("ses_child", "assistant", assistant("openai", "gpt-6.2-sol", 200), 200)
        self.add("ses_parent", "assistant", assistant("anthropic", "claude-opus-5-5", 300), 300)
        result = self.run_helper("--message", "msg_child", session="ses_parent")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "openai/gpt-6.2-sol\n")

    def test_family_maps_direct_providers_only(self):
        cases = {
            "anthropic": "claude",
            "openai": "codex",
            "synthetic": "unknown",
            "opencode-go": "unknown",
        }
        for index, (provider, family) in enumerate(cases.items()):
            session = f"ses_{provider}"
            self.add(session, "assistant", assistant(provider, "some-model", 100 + index), 100 + index)
            result = self.run_helper("--family", session=session)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, family + "\n", provider)

    def test_failures_exit_nonzero_without_stdout(self):
        self.add("ses_a", "user", {"text": "hello"}, 100)
        cases = [
            ((), None),  # no session given
            ((), "ses_a"),  # no completed assistant row
            (("--message", "msg_missing"), None),  # unknown message
        ]
        for args, session in cases:
            result = self.run_helper(*args, session=session)
            self.assertNotEqual(result.returncode, 0, (args, session))
            self.assertEqual(result.stdout, "", (args, session))
            self.assertTrue(result.stderr.strip(), (args, session))
        self.db.unlink()
        result = self.run_helper(session="ses_a")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")

    def test_database_is_not_modified(self):
        self.add("ses_a", "assistant", assistant("anthropic", "claude-opus-5-5", 100), 100)
        self.conn.close()
        before = hashlib.sha256(self.db.read_bytes()).hexdigest()
        self.assertEqual(self.run_helper(session="ses_a").returncode, 0)
        self.assertEqual(hashlib.sha256(self.db.read_bytes()).hexdigest(), before)


if __name__ == "__main__":
    unittest.main()
