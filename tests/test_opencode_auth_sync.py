"""Drive opencode-auth-sync against a stub opencode that keeps credentials in a file.

The stub answers `auth export`, `auth logout`, and `auth import` the way
OpenCode v2.3.2 does, including skipping an import whose account is already
stored, and records every call so the tests can read what was asked of it.
"""

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/opencode-auth-sync"
SYNTHETIC_KEY = "FAKE-CANARY synthetic key"
GO_KEY = "FAKE-CANARY go key"

FAKE_OPENCODE = """#!{python}
import json, os, stat, sys
store_path, log_path = os.environ['FAKE_STORE'], os.environ['FAKE_LOG']
store = json.load(open(store_path)) if os.path.exists(store_path) else []
args = sys.argv[1:]
call = {{'argv': args}}
if args[:2] == ['auth', 'import']:
    path = args[2]
    call['file_mode'] = stat.S_IMODE(os.stat(path).st_mode)
    call['dir_mode'] = stat.S_IMODE(os.stat(os.path.dirname(path)).st_mode)
    call['path'] = path
calls = json.load(open(log_path)) if os.path.exists(log_path) else []
calls.append(call)
json.dump(calls, open(log_path, 'w'))
if os.environ.get('FAKE_FAIL') == args[1]:
    sys.stderr.write('boom while running ' + args[1] + '\\n')
    sys.exit(3)
if args[:2] == ['auth', 'export']:
    print(json.dumps(store))
elif args[:2] == ['auth', 'logout']:
    removed_active = any(e['integrationID'] == args[2] and e['id'] == args[3] and e['active'] for e in store)
    store = [e for e in store if not (e['integrationID'] == args[2] and e['id'] == args[3])]
    if removed_active:
        for e in store:
            if e['integrationID'] == args[2]:
                e['active'] = True
                break
    json.dump(store, open(store_path, 'w'))
elif args[:2] == ['auth', 'import']:
    added = 0
    for entry in json.load(open(args[2])):
        if any(e['id'] == entry['id'] or (e['integrationID'] == entry['integrationID'] and e['label'] == entry['label']) for e in store):
            continue
        if any(e['integrationID'] == entry['integrationID'] and e['active'] for e in store):
            entry['active'] = False
        store.append(entry)
        added += 1
    json.dump(store, open(store_path, 'w'))
    print('Imported %d credentials' % added)
elif args[:2] == ['auth', 'switch']:
    if not any(e['integrationID'] == args[2] and e['id'] == args[3] for e in store):
        sys.exit(4)
    for e in store:
        if e['integrationID'] == args[2]:
            e['active'] = e['id'] == args[3]
    json.dump(store, open(store_path, 'w'))
else:
    sys.exit(9)
"""


def account(integration, key, label="nix-config", active=True, credential_id=None):
    return {
        "id": credential_id or integration,
        "integrationID": integration,
        "label": label,
        "active": active,
        "value": {"type": "key", "key": key},
    }


class OpencodeAuthSyncTestCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.binary = self.root / "opencode"
        self.binary.write_text(FAKE_OPENCODE.format(python=sys.executable))
        self.binary.chmod(0o755)
        self.store = self.root / "store.json"
        self.log = self.root / "log.json"
        self.synthetic = self.write_key("synthetic_api_key", SYNTHETIC_KEY + "\n")
        self.go = self.write_key("opencode_go_api_key", GO_KEY)

    def write_key(self, name, text):
        path = self.root / name
        path.write_text(text)
        return path

    def run_sync(self, credentials=None, env=None):
        credentials = credentials or [("synthetic", self.synthetic), ("opencode-go", self.go)]
        args = [sys.executable, str(SCRIPT), "--opencode", str(self.binary)]
        for integration, path in credentials:
            args += ["--credential", f"{integration}={path}"]
        full_env = dict(
            os.environ,
            FAKE_STORE=str(self.store),
            FAKE_LOG=str(self.log),
            XDG_STATE_HOME=str(self.root / "state"),
            **(env or {}),
        )
        return subprocess.run(args, capture_output=True, text=True, env=full_env)

    def calls(self):
        return json.loads(self.log.read_text()) if self.log.exists() else []

    def stored(self):
        return json.loads(self.store.read_text()) if self.store.exists() else []

    def verbs(self):
        return [call["argv"][1] for call in self.calls()]

    def test_a_fresh_store_gets_both_credentials_through_a_private_file(self):
        proc = self.run_sync()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(self.verbs(), ["export", "import", "export"])
        self.assertEqual(
            sorted((e["integrationID"], e["value"]["key"]) for e in self.stored()),
            [("opencode-go", GO_KEY), ("synthetic", SYNTHETIC_KEY)],
        )
        imported = self.calls()[1]
        self.assertEqual((imported["dir_mode"], imported["file_mode"]), (0o700, 0o600))
        self.assertFalse(Path(imported["path"]).exists(), "the import file was left behind")
        self.assertFalse(Path(imported["path"]).parent.exists(), "the private directory was left behind")

    def test_every_call_runs_standalone_and_no_key_reaches_argv_or_output(self):
        proc = self.run_sync()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        for call in self.calls():
            self.assertEqual(call["argv"][-1], "--standalone")
            self.assertNotIn(SYNTHETIC_KEY, " ".join(call["argv"]))
            self.assertNotIn(GO_KEY, " ".join(call["argv"]))
        self.assertNotIn("FAKE-CANARY", proc.stdout + proc.stderr)

    def test_matching_stored_keys_cause_no_logout_and_no_import(self):
        self.store.write_text(json.dumps([account("synthetic", SYNTHETIC_KEY), account("opencode-go", GO_KEY)]))
        proc = self.run_sync()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(self.verbs(), ["export"])

    def test_a_rotated_key_replaces_only_its_own_stored_account(self):
        self.store.write_text(json.dumps([account("synthetic", "old key"), account("opencode-go", GO_KEY)]))
        proc = self.run_sync()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(self.verbs(), ["export", "logout", "import", "export"])
        self.assertEqual(self.calls()[1]["argv"][2:4], ["synthetic", "synthetic"])
        keys = {e["integrationID"]: e["value"]["key"] for e in self.stored()}
        self.assertEqual(keys, {"synthetic": SYNTHETIC_KEY, "opencode-go": GO_KEY})
        self.assertEqual(len(self.stored()), 2)

    def test_accounts_under_other_labels_are_never_touched(self):
        other = account("synthetic", "hand-connected key", label="personal")
        self.store.write_text(json.dumps([other]))
        proc = self.run_sync()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertNotIn("logout", self.verbs())
        self.assertIn(other, self.stored())
        self.assertEqual(len(self.stored()), 3)

    def test_rotation_keeps_the_selected_account(self):
        key = self.write_key("anthropic_api_key", "FAKE-CANARY new Anthropic key")
        for managed_active in (True, False):
            with self.subTest(managed_active=managed_active):
                other = account(
                    "anthropic", "personal key", label="personal", active=not managed_active, credential_id="personal-id"
                )
                self.store.write_text(json.dumps([account("anthropic", "old key", active=managed_active), other]))
                proc = self.run_sync([("anthropic", key)])
                self.assertEqual(proc.returncode, 0, proc.stderr)
                self.assertCountEqual(
                    self.stored(),
                    [account("anthropic", "FAKE-CANARY new Anthropic key", active=managed_active), other],
                )

    def test_retry_restores_selection_after_an_import_or_switch_failure(self):
        key = self.write_key("anthropic_api_key", "FAKE-CANARY new Anthropic key")
        for verb in ("import", "switch"):
            with self.subTest(verb=verb):
                other = account("anthropic", "personal key", label="personal", active=False, credential_id="personal-id")
                self.store.write_text(json.dumps([account("anthropic", "old key"), other]))
                proc = self.run_sync([("anthropic", key)], {"FAKE_FAIL": verb})
                self.assertEqual(proc.returncode, 1, proc.stderr)
                proc = self.run_sync([("anthropic", key)])
                self.assertEqual(proc.returncode, 0, proc.stderr)
                self.assertCountEqual(self.stored(), [account("anthropic", "FAKE-CANARY new Anthropic key"), other])

    def test_a_missing_or_empty_key_file_stops_before_opencode_runs(self):
        missing = self.root / "absent"
        empty = self.write_key("empty", "  \n")
        for label, path in (("missing", missing), ("empty", empty)):
            with self.subTest(label):
                proc = self.run_sync([("synthetic", self.synthetic), ("opencode-go", path)])
                self.assertEqual(proc.returncode, 1)
                self.assertIn("opencode-auth-sync:", proc.stderr)
                self.assertIn(str(path), proc.stderr)
                self.assertEqual(self.calls(), [])
                self.assertNotIn("FAKE-CANARY", proc.stderr)

    def test_an_opencode_failure_is_reported_and_leaves_no_import_file(self):
        proc = self.run_sync(env={"FAKE_FAIL": "import"})
        self.assertEqual(proc.returncode, 1)
        self.assertIn("opencode auth import failed", proc.stderr)
        self.assertNotIn("FAKE-CANARY", proc.stderr)
        imported = self.calls()[-1]
        self.assertFalse(Path(imported["path"]).parent.exists())

    def test_a_failed_export_stops_before_any_logout_or_import(self):
        self.store.write_text(json.dumps([account("synthetic", "old key")]))
        proc = self.run_sync(env={"FAKE_FAIL": "export"})
        self.assertEqual(proc.returncode, 1)
        self.assertIn("opencode auth export failed", proc.stderr)
        self.assertEqual(self.verbs(), ["export"])

    def test_a_failed_logout_stops_before_the_import(self):
        self.store.write_text(json.dumps([account("synthetic", "old key")]))
        proc = self.run_sync(env={"FAKE_FAIL": "logout"})
        self.assertEqual(proc.returncode, 1)
        self.assertIn("opencode auth logout failed", proc.stderr)
        self.assertEqual(self.verbs(), ["export", "logout"])
        self.assertEqual(self.stored()[0]["value"]["key"], "old key")

    def test_an_export_that_is_not_a_list_is_refused(self):
        self.store.write_text(json.dumps({"not": "a list"}))
        proc = self.run_sync()
        self.assertEqual(proc.returncode, 1)
        self.assertIn("printed no list", proc.stderr)
        self.assertEqual(self.verbs(), ["export"])

    def test_a_malformed_credential_argument_is_refused(self):
        proc = subprocess.run(
            [sys.executable, str(SCRIPT), "--opencode", str(self.binary), "--credential", "no-equals-sign"],
            capture_output=True,
            text=True,
        )
        self.assertEqual(proc.returncode, 2)
        self.assertIn("INTEGRATION=KEYFILE", proc.stderr)


if __name__ == "__main__":
    unittest.main()
