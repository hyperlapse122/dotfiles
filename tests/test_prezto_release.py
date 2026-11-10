"""Drive the real updater through argument-checking network stubs."""

import base64
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "scripts/prezto-release"
PATHS = [
    "modules/autosuggestions/external", "modules/completion/external",
    "modules/history-substring-search/external", "modules/syntax-highlighting/external",
    "modules/prompt/external/powerline", "modules/prompt/external/agnoster",
    "modules/prompt/external/pure", "modules/prompt/external/async",
    "modules/prompt/external/powerlevel10k",
]
ROOT = "sorin-ionescu/prezto"
REV = "a" * 40
STUB = r'''#!PYTHON
import base64, json, os, pathlib, sys
fixture = json.loads(pathlib.Path(os.environ['PREZTO_FIXTURE']).read_text())
if pathlib.Path(sys.argv[0]).name == 'gh':
    assert sys.argv[1:4] == ['api', '--hostname', 'github.com'], sys.argv
    assert len(sys.argv) == 5, sys.argv
    result = fixture['api'][sys.argv[4]]
    print(json.dumps(result))
else:
    assert sys.argv[1:5] == ['-sfL', '--max-time', '60', '--'], sys.argv
    assert len(sys.argv) == 6, sys.argv
    body = fixture['downloads'].get(sys.argv[5])
    if body is None:
        sys.exit(22)
    sys.stdout.buffer.write(base64.b64decode(body))
'''


class PreztoReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.output = self.root / "pin.json"
        self.fixture = {"api": {}, "downloads": {}}
        self.fixture["api"][f"repos/{ROOT}"] = {"default_branch": "main"}
        self.fixture["api"][f"repos/{ROOT}/commits/main"] = {"sha": REV}
        self.expected = []
        self.add_repository(ROOT, REV, "", [
            (path, f"example/dependency-{index}", f"{index + 1:040x}")
            for index, path in enumerate(PATHS)
        ] + [("modules/extra/external", "example/extra", "e" * 40)])
        for index, path in enumerate(PATHS):
            children = [("vendor/nested", "example/nested", "f" * 40)] if index == 0 else []
            self.add_repository(f"example/dependency-{index}", f"{index + 1:040x}", path, children)
            if children:
                self.add_repository("example/nested", "f" * 40, path + "/vendor/nested", [])
        self.add_repository("example/extra", "e" * 40, "modules/extra/external", [])
        binary = self.root / "bin"
        binary.mkdir()
        for name in ["gh", "curl"]:
            executable = binary / name
            executable.write_text(STUB.replace("PYTHON", sys.executable))
            executable.chmod(0o755)
        self.env = dict(os.environ, PATH=str(binary) + os.pathsep + os.environ["PATH"],
                        PREZTO_FIXTURE=str(self.root / "fixture.json"))

    def add_repository(self, repository, revision, prefix, children):
        url = f"https://codeload.github.com/{repository}/tar.gz/{revision}"
        payload = f"archive bytes for {repository} at {revision}".encode()
        self.fixture["downloads"][url] = base64.b64encode(payload).decode()
        self.expected.append({"path": prefix, "repository": repository, "commit": revision,
                              "url": url, "sha256": hashlib.sha256(payload).hexdigest()})
        base = f"repos/{repository}"
        self.fixture["api"][f"{base}/git/trees/{revision}?recursive=1"] = {
            "truncated": False,
            "tree": [{"path": path, "mode": "160000", "sha": commit}
                     for path, _, commit in children],
        }
        if children:
            document = "\n".join(f'[submodule "{index}"]\npath = {path}\nurl = https://github.com/{repo}.git'
                                 for index, (path, repo, _) in enumerate(children))
            self.fixture["api"][f"{base}/contents/.gitmodules?ref={revision}"] = {
                "content": base64.b64encode(document.encode()).decode(),
            }

    def run_release(self, *extra):
        Path(self.env["PREZTO_FIXTURE"]).write_text(json.dumps(self.fixture))
        return subprocess.run([sys.executable, str(SCRIPT), "--output", str(self.output), *extra],
                              env=self.env, text=True, capture_output=True)

    def test_recursive_commits_and_real_archive_hashes(self):
        result = self.run_release()
        self.assertEqual(result.returncode, 0, result.stderr)
        pin = json.loads(self.output.read_text())["zshLock"]["archives"]
        self.assertEqual({p["path"]: p for p in pin}, {p["path"]: p for p in self.expected})
        self.assertEqual(pin[0]["path"], "")
        paths = [p["path"] for p in pin]
        self.assertLess(paths.index(PATHS[0]), paths.index(PATHS[0] + "/vendor/nested"))

    def test_unchanged_pin_and_check_do_not_write(self):
        self.assertEqual(self.run_release().returncode, 0)
        before = self.output.read_bytes(), self.output.stat().st_mtime_ns
        self.assertEqual(self.run_release("--check").returncode, 0)
        self.assertEqual(self.run_release().returncode, 0)
        self.assertEqual((self.output.read_bytes(), self.output.stat().st_mtime_ns), before)

    def test_stale_check_preserves_existing_bytes(self):
        self.output.write_bytes(b'{"old": "pin"}\n')
        result = self.run_release("--check")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(self.output.read_bytes(), b'{"old": "pin"}\n')

    def test_default_branch_is_discovered(self):
        self.fixture["api"][f"repos/{ROOT}"]["default_branch"] = "next/release"
        self.fixture["api"][f"repos/{ROOT}/commits/next%2Frelease"] = {"sha": REV}
        del self.fixture["api"][f"repos/{ROOT}/commits/main"]
        result = self.run_release()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_failed_refresh_preserves_pin_and_temporary_files_are_removed(self):
        tree = self.fixture["api"][f"repos/{ROOT}/git/trees/{REV}?recursive=1"]
        cases = [
            ("truncated tree", lambda: tree.update(truncated=True)),
            ("missing submodule", lambda: tree["tree"].pop(0)),
            ("invalid commit", lambda: tree["tree"][0].update(sha="not-a-commit")),
            ("unsafe path", lambda: tree["tree"][0].update(path="../escape")),
            ("download failure", lambda: self.fixture["downloads"].clear()),
            ("empty archive", lambda: self.fixture["downloads"].update(
                {next(iter(self.fixture["downloads"])): ""})),
        ]
        original = json.dumps(self.fixture)
        for label, mutate in cases:
            with self.subTest(label=label):
                self.fixture = json.loads(original)
                tree = self.fixture["api"][f"repos/{ROOT}/git/trees/{REV}?recursive=1"]
                self.output.write_bytes(b"previous complete pin\n")
                mutate()
                result = self.run_release()
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertNotIn("Traceback", result.stderr)
                self.assertEqual(self.output.read_bytes(), b"previous complete pin\n")
                self.assertEqual(sorted(p.name for p in self.root.glob(".pin.json.*")), [])

    def test_recursive_cycle_is_rejected(self):
        endpoint = f"repos/example/nested/git/trees/{'f' * 40}?recursive=1"
        self.fixture["api"][endpoint]["tree"] = [{"path": "loop", "mode": "160000", "sha": REV}]
        self.fixture["api"][f"repos/example/nested/contents/.gitmodules?ref={'f' * 40}"] = {
            "content": base64.b64encode(f'[submodule "loop"]\npath = loop\nurl = https://github.com/{ROOT}.git'.encode()).decode(),
        }
        result = self.run_release()
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("Cyclic", result.stderr)
        self.assertFalse(self.output.exists())


if __name__ == "__main__":
    unittest.main()
