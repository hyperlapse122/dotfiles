"""Drive npm-release against a fake npm registry, npm, and prefetch-npm-deps.

The helper's `curl`, `npm`, and `prefetch-npm-deps` calls are stubbed on `PATH`
so these tests feed it fixtures without network access.
"""

import base64
import hashlib
import io
import json
import os
import subprocess
import sys
import tarfile
import tempfile
import time
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/npm-release"

BASE = "https://registry.npmjs.org"
NAME = "acpx"
VERSION = "0.0.34"
DEPS_HASH = "sha256-" + base64.b64encode(b"d" * 32).decode("ascii")
PACKAGE_JSON = {
    "name": NAME,
    "version": VERSION,
    "bin": {"acpx": "dist/index.js"},
    "dependencies": {"zod": "^3.25.0"},
    "devDependencies": {"tsup": "^8.0.0"},
}
LOCK = {
    "name": NAME,
    "version": VERSION,
    "lockfileVersion": 3,
    "requires": True,
    "packages": {
        "": {"name": NAME, "version": VERSION, "dependencies": {"zod": "^3.25.0"}},
        "node_modules/zod": {
            "version": "3.25.76",
            "resolved": f"{BASE}/zod/-/zod-3.25.76.tgz",
            "integrity": "sha512-" + base64.b64encode(b"z" * 64).decode("ascii"),
        },
    },
}


def make_tarball(package_json=None):
    data = json.dumps(PACKAGE_JSON if package_json is None else package_json).encode()
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w:gz") as archive:
        info = tarfile.TarInfo("package/package.json")
        info.size = len(data)
        archive.addfile(info, io.BytesIO(data))
    return buffer.getvalue()


def integrity_of(body):
    return "sha512-" + base64.b64encode(hashlib.sha512(body).digest()).decode("ascii")


TARBALL = make_tarball()
TARBALL_URL = f"{BASE}/{NAME}/-/{NAME}-{VERSION}.tgz"


def latest_url(base=BASE):
    return f"{base}/{NAME}/latest"


def registry(version=VERSION, base=BASE, tarball=TARBALL):
    """Build a URL -> body map shaped like the npm registry's responses."""
    return {
        latest_url(base): {
            "name": NAME,
            "version": version,
            "dist": {"tarball": TARBALL_URL, "integrity": integrity_of(tarball)},
        },
        TARBALL_URL: {"base64": base64.b64encode(tarball).decode("ascii")},
    }


def pin(version=VERSION):
    return {
        "version": version,
        "url": TARBALL_URL,
        "hash": integrity_of(TARBALL),
        "npmDepsHash": DEPS_HASH,
    }


FAKE_CURL = """#!{python}
import base64, json, os, sys
if sys.argv[1:4] != ['-sfL', '--max-time', '60'] or len(sys.argv) != 5:
    sys.stderr.write(f'unexpected curl argv: {{sys.argv[1:]!r}}\\n')
    sys.exit(99)
routes = json.loads(os.environ['FAKE_ROUTES'])
body = routes.get(sys.argv[4])
if body is None:
    sys.exit(22)
if isinstance(body, dict) and set(body) == {{'base64'}}:
    sys.stdout.buffer.write(base64.b64decode(body['base64']))
else:
    sys.stdout.write(body if isinstance(body, str) else json.dumps(body))
"""

# Records its argv and the package.json it was run beside, then writes the
# fixture lock file the way `npm install --package-lock-only` would.
FAKE_NPM = """#!{python}
import json, os, sys, time
time.sleep(float(os.environ.get('FAKE_NPM_SLEEP', '0')))
with open('package.json') as f:
    manifest = json.load(f)
with open(os.environ['FAKE_NPM_LOG'], 'w') as f:
    json.dump({{'argv': sys.argv[1:], 'manifest': manifest}}, f)
status = int(os.environ.get('FAKE_NPM_STATUS', '0'))
if status:
    sys.exit(status)
with open('package-lock.json', 'w') as f:
    f.write(os.environ['FAKE_LOCK'])
"""

FAKE_PREFETCH = """#!{python}
import os, sys, time
if len(sys.argv) != 2:
    sys.stderr.write(f'unexpected prefetch-npm-deps argv: {{sys.argv[1:]!r}}\\n')
    sys.exit(99)
time.sleep(float(os.environ.get('FAKE_PREFETCH_SLEEP', '0')))
with open(sys.argv[1]) as f:
    open(os.environ['FAKE_PREFETCH_LOG'], 'w').write(f.read())
print(os.environ['FAKE_DEPS_HASH'])
"""


class NpmReleaseTestCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.bin_dir = self.root / "bin"
        self.bin_dir.mkdir()
        for name, body in [
            ("curl", FAKE_CURL),
            ("npm", FAKE_NPM),
            ("prefetch-npm-deps", FAKE_PREFETCH),
        ]:
            path = self.bin_dir / name
            path.write_text(body.format(python=sys.executable))
            path.chmod(0o755)
        self.output = self.root / "acpx-release.json"
        self.lock = self.root / "acpx" / "package-lock.json"
        self.lock.parent.mkdir()
        self.npm_log = self.root / "npm.json"
        self.prefetch_log = self.root / "prefetch.json"

    def run_release(self, routes=None, extra_args=None, lock=None, deps_hash=DEPS_HASH, env_extra=None):
        env = dict(os.environ)
        env["PATH"] = f"{self.bin_dir}:{env.get('PATH', '')}"
        env["FAKE_ROUTES"] = json.dumps(registry() if routes is None else routes)
        env["FAKE_LOCK"] = json.dumps(LOCK if lock is None else lock, indent=2) + "\n"
        env["FAKE_DEPS_HASH"] = deps_hash
        env["FAKE_NPM_LOG"] = str(self.npm_log)
        env["FAKE_PREFETCH_LOG"] = str(self.prefetch_log)
        env.update(env_extra or {})
        args = [sys.executable, str(SCRIPT), "--package", NAME]
        args.extend(
            extra_args
            if extra_args is not None
            else ["-o", str(self.output), "--lock", str(self.lock)]
        )
        return subprocess.run(args, capture_output=True, text=True, env=env)

    def write_pin(self, version):
        self.output.write_text(json.dumps({"version": version}))
        self.lock.write_text('{"old": true}\n')

    def assert_refused(self, needle, **kwargs):
        """Run against an existing older pin and expect a refusal that leaves both files alone."""
        self.write_pin("0.0.1")
        before = (self.output.read_bytes(), self.lock.read_bytes())
        result = self.run_release(**kwargs)
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("npm-release:", result.stderr)
        self.assertIn(needle, result.stderr)
        self.assertEqual((self.output.read_bytes(), self.lock.read_bytes()), before)

    def test_writes_pin_and_lock_file_from_the_registry(self):
        self.write_pin("0.0.33")
        result = self.run_release()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("updated", result.stdout)
        self.assertEqual(json.loads(self.output.read_text()), pin())
        self.assertEqual(json.loads(self.lock.read_text()), LOCK)
        # prefetch-npm-deps hashed the same lock file that was written.
        self.assertEqual(json.loads(self.prefetch_log.read_text()), LOCK)

    def test_npm_sees_the_tarball_manifest_without_dev_dependencies(self):
        result = self.run_release()
        self.assertEqual(result.returncode, 0, result.stderr)
        log = json.loads(self.npm_log.read_text())
        expected = dict(PACKAGE_JSON)
        del expected["devDependencies"]
        self.assertEqual(log["manifest"], expected)
        self.assertIn("--package-lock-only", log["argv"])
        self.assertIn("--ignore-scripts", log["argv"])
        self.assertIn(f"--registry={BASE}/", log["argv"])

    def test_same_or_older_version_changes_nothing(self):
        for version in [VERSION, "0.0.40", "0.1.0"]:
            with self.subTest(version=version):
                self.write_pin(version)
                before = (self.output.read_bytes(), self.lock.read_bytes())
                result = self.run_release()
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("already up to date", result.stdout)
                self.assertEqual((self.output.read_bytes(), self.lock.read_bytes()), before)
                self.assertFalse(self.npm_log.exists())

    def test_numeric_version_comparison_beats_lexical(self):
        self.write_pin("0.0.9")
        result = self.run_release()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(self.output.read_text())["version"], VERSION)

    def test_dry_run_prints_json_and_writes_nothing(self):
        result = self.run_release(extra_args=["--dry-run", "-o", str(self.output), "--lock", str(self.lock)])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), pin())
        self.assertFalse(self.output.exists())
        self.assertFalse(self.lock.exists())

    def test_output_without_lock_is_refused(self):
        result = self.run_release(extra_args=["-o", str(self.output)])
        self.assertEqual(result.returncode, 1)
        self.assertIn("--output and --lock go together", result.stderr)
        self.assertFalse(self.output.exists())

    def test_refuses_a_deprecated_latest(self):
        routes = registry()
        routes[latest_url()]["deprecated"] = "use something else"
        self.assert_refused("deprecated", routes=routes)

    def test_refuses_a_version_that_is_not_a_plain_release(self):
        for version in ["0.0.35-beta.1", "1.0.0-rc.0"]:
            with self.subTest(version=version):
                self.assert_refused(version, routes=registry(version=version))

    def test_refuses_a_manifest_for_another_package(self):
        routes = registry()
        routes[latest_url()]["name"] = "acpx-fork"
        self.assert_refused("acpx-fork", routes=routes)

    def test_refuses_a_tarball_outside_the_npm_registry(self):
        for url in ["https://evil.example/x.tgz", "http://registry.npmjs.org/x.tgz", None]:
            with self.subTest(url=url):
                routes = registry()
                routes[latest_url()]["dist"]["tarball"] = url
                self.assert_refused("tarball", routes=routes)

    def test_refuses_integrity_that_is_not_a_single_sha512_digest(self):
        for integrity in ["sha1-" + base64.b64encode(b"x" * 20).decode("ascii"), "sha512-short", None]:
            with self.subTest(integrity=integrity):
                routes = registry()
                routes[latest_url()]["dist"]["integrity"] = integrity
                self.assert_refused("integrity", routes=routes)

    def test_refuses_a_tarball_that_does_not_match_its_integrity(self):
        routes = registry()
        routes[TARBALL_URL] = {"base64": base64.b64encode(make_tarball({**PACKAGE_JSON, "x": 1})).decode("ascii")}
        self.assert_refused("does not match its integrity", routes=routes)

    def test_refuses_a_tarball_whose_package_json_names_another_release(self):
        other = make_tarball({**PACKAGE_JSON, "version": "0.0.33"})
        self.assert_refused("package.json", routes=registry(tarball=other))

    def test_refuses_a_lock_entry_outside_the_registry(self):
        for resolved in ["git+ssh://git@github.com/x/y.git", "file:../z", None]:
            with self.subTest(resolved=resolved):
                lock = json.loads(json.dumps(LOCK))
                lock["packages"]["node_modules/zod"]["resolved"] = resolved
                self.assert_refused("node_modules/zod", lock=lock)

    def test_refuses_a_lock_entry_without_integrity(self):
        lock = json.loads(json.dumps(LOCK))
        del lock["packages"]["node_modules/zod"]["integrity"]
        self.assert_refused("no integrity", lock=lock)

    def test_refuses_a_failed_npm_run(self):
        self.assert_refused("npm could not write a lock file", env_extra={"FAKE_NPM_STATUS": "1"})

    def test_refuses_a_prefetch_output_that_is_not_a_hash(self):
        self.assert_refused("prefetch-npm-deps printed no sha256 hash", deps_hash="error: boom")

    def test_a_hung_npm_or_prefetch_times_out_and_changes_nothing(self):
        for label, variable in (("npm install --package-lock-only", "FAKE_NPM_SLEEP"),
                                ("prefetch-npm-deps", "FAKE_PREFETCH_SLEEP")):
            with self.subTest(label):
                started = time.monotonic()
                self.assert_refused(f"{label} timed out after 1 seconds",
                                    env_extra={variable: "60", "NPM_RELEASE_TIMEOUT": "1"})
                self.assertLess(time.monotonic() - started, 30)

    def test_refuses_a_timeout_that_is_not_a_positive_number(self):
        for raw in ("soon", "0", "-5", "nan"):
            with self.subTest(raw):
                self.assert_refused("NPM_RELEASE_TIMEOUT", env_extra={"NPM_RELEASE_TIMEOUT": raw})

    def test_fetch_error_fails_naming_the_url(self):
        self.assert_refused(f"{latest_url()} failed with status 22", routes={})

    def test_refuses_a_name_that_is_not_an_npm_package(self):
        result = subprocess.run(
            [sys.executable, str(SCRIPT), "--package", "../etc", "--dry-run"],
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("not an npm package name", result.stderr)


if __name__ == "__main__":
    unittest.main()
