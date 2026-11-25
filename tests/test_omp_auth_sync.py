"""Drive omp-auth-sync against a stub omp that keeps credentials in a file.

The stub answers `auth import -` the way omp does at the pinned release: an
imported API key replaces every stored API key of that provider, and OAuth
logins and other providers stay. It records each call's argv, the import
document it read from standard input, and its environment, so the tests can
check that keys travel only on standard input.
"""

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/omp-auth-sync"
PROVIDERS = ("synthetic", "openrouter", "anthropic", "opencode-go", "exa")

FAKE_OMP = """#!{python}
import json, os, sys
store_path, log_path = os.environ['FAKE_STORE'], os.environ['FAKE_LOG']
store = json.load(open(store_path)) if os.path.exists(store_path) else []
args = sys.argv[1:]
call = {{'argv': args, 'env': dict(os.environ)}}
if args == ['auth', 'import', '-']:
    call['stdin'] = sys.stdin.read()
calls = json.load(open(log_path)) if os.path.exists(log_path) else []
calls.append(call)
json.dump(calls, open(log_path, 'w'))
if os.environ.get('FAKE_FAIL'):
    sys.stderr.write('boom\\n')
    sys.exit(3)
if args != ['auth', 'import', '-']:
    sys.exit(9)
document = json.loads(call['stdin'])
assert document['version'] == 1
for entry in document['credentials']:
    provider, credential = entry['provider'], entry['credential']
    store = [row for row in store if not (row['provider'] == provider and row['credential']['type'] == 'api_key')]
    store.append(entry)
json.dump(store, open(store_path, 'w'))
"""


def api_key(provider, key, source="login"):
    return {"provider": provider, "credential": {"type": "api_key", "key": key, "source": source}}


def oauth(provider):
    return {"provider": provider, "credential": {"type": "oauth", "access": "a", "refresh": "r", "expires": 1}}


class OmpAuthSyncTestCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.binary = self.root / "omp"
        self.binary.write_text(FAKE_OMP.format(python=sys.executable))
        self.binary.chmod(0o755)
        self.store = self.root / "store.json"
        self.log = self.root / "log.json"
        self.keys = {provider: f"FAKE-CANARY {provider} key" for provider in PROVIDERS}
        self.paths = {provider: self.write_key(provider, self.keys[provider] + "\n") for provider in PROVIDERS}

    def write_key(self, name, text):
        path = self.root / f"{name}_api_key"
        path.write_text(text)
        return path

    def run_sync(self, credentials=None, env=None):
        credentials = credentials or list(self.paths.items())
        args = [sys.executable, str(SCRIPT), "--omp", str(self.binary)]
        for provider, path in credentials:
            args += ["--credential", f"{provider}={path}"]
        full_env = dict(os.environ, FAKE_STORE=str(self.store), FAKE_LOG=str(self.log), **(env or {}))
        return subprocess.run(args, capture_output=True, text=True, env=full_env)

    def calls(self):
        return json.loads(self.log.read_text()) if self.log.exists() else []

    def stored(self):
        return json.loads(self.store.read_text()) if self.store.exists() else []

    def test_an_empty_store_gets_every_key_as_a_login_api_key(self):
        proc = self.run_sync()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual([call["argv"] for call in self.calls()], [["auth", "import", "-"]])
        self.assertCountEqual(self.stored(), [api_key(p, self.keys[p]) for p in PROVIDERS])

    def test_hand_entered_keys_are_replaced_and_oauth_and_other_providers_kept(self):
        others = [api_key("deepseek", "hand key"), oauth("anthropic")]
        self.store.write_text(json.dumps([api_key("synthetic", "hand key"), api_key("openrouter", "hand key"), *others]))
        proc = self.run_sync()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertCountEqual(self.stored(), [*others, *(api_key(p, self.keys[p]) for p in PROVIDERS)])

    def test_a_rotated_key_file_replaces_the_stored_key(self):
        self.assertEqual(self.run_sync().returncode, 0)
        self.write_key("synthetic", "FAKE-CANARY rotated synthetic key")
        proc = self.run_sync()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        synthetic = [row for row in self.stored() if row["provider"] == "synthetic"]
        self.assertEqual(synthetic, [api_key("synthetic", "FAKE-CANARY rotated synthetic key")])

    def test_keys_travel_only_on_standard_input(self):
        proc = self.run_sync()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        (call,) = self.calls()
        exposed = " ".join(call["argv"]) + json.dumps(call["env"])
        self.assertNotIn("FAKE-CANARY", exposed)
        self.assertNotIn("FAKE-CANARY", proc.stdout + proc.stderr)
        self.assertIn(self.keys["exa"], call["stdin"])

    def test_a_missing_or_empty_key_file_stops_before_omp_runs(self):
        missing = self.root / "absent"
        empty = self.write_key("empty", "  \n")
        for label, path in (("missing", missing), ("empty", empty)):
            with self.subTest(label):
                proc = self.run_sync([("synthetic", self.paths["synthetic"]), ("exa", path)])
                self.assertEqual(proc.returncode, 1)
                self.assertIn("omp-auth-sync:", proc.stderr)
                self.assertIn(str(path), proc.stderr)
                self.assertEqual(self.calls(), [])
                self.assertNotIn("FAKE-CANARY", proc.stderr)

    def test_a_failed_import_fails_without_printing_a_key(self):
        proc = self.run_sync(env={"FAKE_FAIL": "1"})
        self.assertEqual(proc.returncode, 1)
        self.assertIn("omp auth import failed", proc.stderr)
        self.assertNotIn("FAKE-CANARY", proc.stdout + proc.stderr)

    def test_a_malformed_credential_argument_is_refused(self):
        proc = subprocess.run(
            [sys.executable, str(SCRIPT), "--omp", str(self.binary), "--credential", "no-equals-sign"],
            capture_output=True,
            text=True,
        )
        self.assertEqual(proc.returncode, 2)
        self.assertIn("PROVIDER=KEYFILE", proc.stderr)


if __name__ == "__main__":
    unittest.main()
