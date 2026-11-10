"""Drive mise-release against fake SHASUMS256.txt fixtures.

The helper's `curl` command is stubbed on `PATH` so these tests feed it a
fixture body instead of a network call.
"""

import base64
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/mise-release"

MUSL_HEX = "e331f3fa3c360c63e996ef70bc183ce178cb16d21f8bf4926c61cf6fa6b9fafd"
ARM64_MUSL_HEX = "ef349bbbcf3526865c551dc3dc317d354d63b26553855014db51caf7a063c7d2"
MACOS_ARM64_HEX = "28ecc8640b0a28dab52817766f37fecfd898f1dff82e03f36fcb072e971f9246"
GLIBC_HEX = "2148d2485d1e6e48eb918729d86af4ecd438f9b5b63be360fb26005c85f0d853"


def shasums(version, musl_hex=MUSL_HEX, include_musl=True, include_arm64_musl=True,
            include_macos_arm64=True):
    """Build a SHASUMS256.txt body shaped like upstream's release asset."""
    lines = [
        f"09ea631d6f3e7031d63606a0892dc4c796f9fb57f493bc45937f9f7113c88216  ./mise-v{version}-linux-x64",
        f"b46c551f5e795a81144a3dbe74227c40b7cbe231024d8e9167e691208031ec30  ./mise-v{version}-linux-x64-musl",
        f"45e8f07235640ca52dd168933d6e369435f1af9e486ee70997bc15f0fac22987  ./mise-v{version}-linux-x64-musl.tar.xz",
        f"3e17995959d92d46d638a481134421ba6c9b1695e22a032761a01acbf45b2d7a  ./mise-v{version}-linux-x64-musl.tar.zst",
        f"{GLIBC_HEX}  ./mise-v{version}-linux-x64.tar.gz",
        f"a1d0c6e83f027327d8461063f4ac58a6b7c7a23b5c5d5e9d6c0d4d2c1e7f3a90  ./mise-v{version}-linux-arm64-musl.tar.xz",
        f"0999bd4943523ccdbd149b5ad4080281536801b3f6406ac4495699bd0310969c  ./mise-v{version}-macos-arm64",
        f"5372494c3027260ddf8efa79504c4d968bbe671a58248ec575f57e1472e5d9c2  ./mise-v{version}-macos-arm64.tar.xz",
        f"791b92b446729c53e6501acd2b84ea207f541659ca9d0480c9c70c291919a321  ./mise-v{version}-macos-x64.tar.gz",
    ]
    if include_musl:
        lines.insert(2, f"{musl_hex}  ./mise-v{version}-linux-x64-musl.tar.gz")
    if include_arm64_musl:
        lines.append(f"{ARM64_MUSL_HEX}  ./mise-v{version}-linux-arm64-musl.tar.gz")
    if include_macos_arm64:
        lines.append(f"{MACOS_ARM64_HEX}  ./mise-v{version}-macos-arm64.tar.gz")
    return "\n".join(lines) + "\n"


def sri(hex_digest):
    return "sha256-" + base64.b64encode(bytes.fromhex(hex_digest)).decode("ascii")


DEFAULT_URL = "https://github.com/jdx/mise/releases/latest/download/SHASUMS256.txt"

FAKE_CURL = """#!{python}
import os, sys
expected = ['-sfL', '--max-time', '60', os.environ['FAKE_EXPECTED_URL']]
if sys.argv[1:] != expected:
    sys.stderr.write(f'unexpected curl argv: {{sys.argv[1:]!r}} != {{expected!r}}\\n')
    sys.exit(99)
status = int(os.environ.get('FAKE_STATUS', '0'))
if status:
    sys.exit(status)
sys.stdout.write(os.environ.get('FAKE_BODY', ''))
"""


class MiseReleaseTestCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.bin_dir = root / "bin"
        self.bin_dir.mkdir()
        curl = self.bin_dir / "curl"
        curl.write_text(FAKE_CURL.format(python=sys.executable))
        curl.chmod(0o755)
        self.output = root / "mise-release.json"

    def run_release(self, body=None, extra_args=None, status=0):
        if body is None:
            body = shasums("2026.9.15")
        env = dict(os.environ)
        env["PATH"] = f"{self.bin_dir}:{env.get('PATH', '')}"
        env["FAKE_EXPECTED_URL"] = DEFAULT_URL
        env["FAKE_BODY"] = body
        env["FAKE_STATUS"] = str(status)
        args = [sys.executable, str(SCRIPT)]
        args.extend(extra_args if extra_args is not None else ["--dry-run"])
        return subprocess.run(args, capture_output=True, text=True, env=env)

    def write_pin(self, version):
        entry = {"sha256": "0" * 64, "hash": sri("0" * 64)}
        self.output.write_text(
            json.dumps(
                {
                    "version": version,
                    "systems": {
                        "x86_64-linux": {"asset": "linux-x64-musl", **entry},
                        "aarch64-linux": {"asset": "linux-arm64-musl", **entry},
                        "aarch64-darwin": {"asset": "macos-arm64", **entry},
                    },
                }
            )
        )

    def test_writes_version_and_a_tarball_hash_for_every_system(self):
        self.write_pin("2026.9.14")
        result = self.run_release(extra_args=["-o", str(self.output)])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("updated", result.stdout)
        self.assertEqual(
            json.loads(self.output.read_text()),
            {
                "version": "2026.9.15",
                "systems": {
                    "x86_64-linux": {
                        "asset": "linux-x64-musl",
                        "sha256": MUSL_HEX,
                        "hash": sri(MUSL_HEX),
                    },
                    "aarch64-linux": {
                        "asset": "linux-arm64-musl",
                        "sha256": ARM64_MUSL_HEX,
                        "hash": sri(ARM64_MUSL_HEX),
                    },
                    "aarch64-darwin": {
                        "asset": "macos-arm64",
                        "sha256": MACOS_ARM64_HEX,
                        "hash": sri(MACOS_ARM64_HEX),
                    },
                },
            },
        )

    def test_writes_a_pin_when_none_exists(self):
        result = self.run_release(extra_args=["-o", str(self.output)])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(self.output.read_text())["version"], "2026.9.15")

    def test_numeric_version_comparison_beats_lexical(self):
        self.write_pin("2026.9.9")
        result = self.run_release(extra_args=["-o", str(self.output)])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(self.output.read_text())["version"], "2026.9.15")

    def test_same_version_leaves_the_pin_byte_identical(self):
        self.write_pin("2026.9.15")
        before = self.output.read_bytes()
        result = self.run_release(extra_args=["-o", str(self.output)])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("already up to date", result.stdout)
        self.assertEqual(self.output.read_bytes(), before)

    def test_refuses_a_downgrade(self):
        self.write_pin("2026.10.0")
        before = self.output.read_bytes()
        result = self.run_release(extra_args=["-o", str(self.output)])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("already up to date", result.stdout)
        self.assertEqual(self.output.read_bytes(), before)

    def test_unreadable_existing_pin_is_treated_as_absent(self):
        self.output.write_text(json.dumps([1, 2, 3]))
        result = self.run_release(extra_args=["-o", str(self.output)])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(self.output.read_text())["version"], "2026.9.15")

    def test_refuses_a_release_without_the_musl_tarball(self):
        result = self.run_release(
            body=shasums("2026.9.15", include_musl=False),
            extra_args=["-o", str(self.output)],
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("linux-x64-musl.tar.gz", result.stderr)
        self.assertFalse(self.output.exists())

    def test_refuses_a_release_without_the_arm64_musl_tarball(self):
        self.write_pin("2026.9.14")
        before = self.output.read_bytes()
        result = self.run_release(
            body=shasums("2026.9.15", include_arm64_musl=False),
            extra_args=["-o", str(self.output)],
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("linux-arm64-musl.tar.gz", result.stderr)
        self.assertEqual(self.output.read_bytes(), before)

    def test_refuses_a_release_without_the_macos_arm64_tarball(self):
        self.write_pin("2026.9.14")
        before = self.output.read_bytes()
        result = self.run_release(
            body=shasums("2026.9.15", include_macos_arm64=False),
            extra_args=["-o", str(self.output)],
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("macos-arm64.tar.gz", result.stderr)
        self.assertEqual(self.output.read_bytes(), before)

    def test_refuses_architectures_on_different_versions(self):
        self.write_pin("2026.9.14")
        before = self.output.read_bytes()
        body = shasums("2026.9.15", include_arm64_musl=False) + (
            f"{ARM64_MUSL_HEX}  ./mise-v2026.9.16-linux-arm64-musl.tar.gz\n"
        )
        result = self.run_release(body=body, extra_args=["-o", str(self.output)])
        self.assertEqual(result.returncode, 1)
        self.assertIn("more than one version", result.stderr)
        self.assertEqual(self.output.read_bytes(), before)

    def test_refuses_a_malformed_checksum(self):
        result = self.run_release(body=shasums("2026.9.15", musl_hex="abc123"))
        self.assertEqual(result.returncode, 1)
        self.assertFalse(self.output.exists())

    def test_refuses_a_non_numeric_version(self):
        result = self.run_release(body=shasums("2026.9.15-rc1"))
        self.assertEqual(result.returncode, 1)

    def test_fetch_error_names_the_url(self):
        result = self.run_release(status=22)
        self.assertEqual(result.returncode, 1)
        self.assertIn("SHASUMS256.txt failed with status 22", result.stderr)

    def test_dry_run_prints_json_and_writes_nothing(self):
        result = self.run_release(extra_args=["--dry-run", "-o", str(self.output)])
        self.assertEqual(result.returncode, 0, result.stderr)
        systems = json.loads(result.stdout)["systems"]
        self.assertEqual(systems["x86_64-linux"]["hash"], sri(MUSL_HEX))
        self.assertEqual(systems["aarch64-linux"]["hash"], sri(ARM64_MUSL_HEX))
        self.assertEqual(systems["aarch64-darwin"]["hash"], sri(MACOS_ARM64_HEX))
        self.assertFalse(self.output.exists())


if __name__ == "__main__":
    unittest.main()
