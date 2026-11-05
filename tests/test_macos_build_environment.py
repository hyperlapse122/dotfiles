import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from test_native_ca_shell import find_bash


def shell_path(path):
    value = Path(path).as_posix()
    if os.name == "nt":
        return "/" + value[0].lower() + value[2:]
    return value


@unittest.skipUnless(find_bash(), "Bash required")
class MacosBuildEnvironmentTest(unittest.TestCase):
    def setUp(self):
        self.repo = Path(__file__).resolve().parents[1]
        self.scratch = tempfile.TemporaryDirectory(prefix="mac build ")
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        self.bin = self.root / "commands"
        self.bin.mkdir()
        self.home = self.root / "home"
        self.home.mkdir()
        self.env = os.environ.copy()
        self.env.update(HOME=shell_path(self.home), PATH=shell_path(self.bin) + ":/usr/bin:/bin")
        self.command("uname", "echo Darwin")
        self.command("sw_vers", "echo 15.0")

    def command(self, name, body):
        path = self.bin / name
        path.write_text("#!/bin/sh\n" + body + "\n", encoding="utf-8", newline="\n")
        path.chmod(0o755)
        return path

    def run_phase(self, *args):
        return subprocess.run([find_bash(), "-c", 'PATH="$1:/usr/bin:/bin"; export PATH; shift; exec /bin/sh "$@"',
                               "probe", shell_path(self.bin), self.repo.joinpath("scripts/macos-build-environment.sh").as_posix(), *args],
                              env=self.env, capture_output=True, text=True, timeout=30)

    def test_other_platform_does_not_publish_environment(self):
        self.command("uname", "echo Linux")
        result = self.run_phase("dotnet", "8")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(list(self.home.iterdir()), [])

    def test_missing_sdk_does_not_publish_root(self):
        root = self.root / "dotnet sdk"
        root.mkdir()
        executable = root / "dotnet"
        executable.write_text("#!/bin/sh\necho '10.0.100 [sdk]'\n", newline="\n")
        executable.chmod(0o755)
        self.env["DOTNET_ROOT"] = shell_path(root)
        result = self.run_phase("dotnet", "8")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("SDK 8", result.stderr)
        self.assertFalse((self.home / ".local/share/dotfiles/build/DOTNET_ROOT").exists())

    def test_published_sdk_is_available_in_fresh_shell(self):
        root = self.root / "dotnet sdk"
        root.mkdir()
        executable = root / "dotnet"
        executable.write_text("#!/bin/sh\necho '8.0.100 [sdk]'\necho '10.0.100 [sdk]'\n", newline="\n")
        executable.chmod(0o755)
        self.env["DOTNET_ROOT"] = shell_path(root)
        for _ in range(2):
            result = self.run_phase("dotnet", "8")
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.env.pop("DOTNET_ROOT")
        fragment = self.repo / "home/dot_config/dotfiles/path.sh"
        result = subprocess.run([find_bash(), "-c", 'PATH="$1:/usr/bin:/bin"; export PATH; . "$2"; printf "%s\\n" "$DOTNET_ROOT"; command -v dotnet', "probe", shell_path(self.bin), fragment.as_posix()],
                                env=self.env, capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(shell_path(root), result.stdout)

    def test_wrong_rust_host_does_not_publish(self):
        cargo = self.root / "cargo"
        (cargo / "bin").mkdir(parents=True)
        rustc = cargo / "bin/rustc"
        rustc.write_text("#!/bin/sh\necho 'host: x86_64-apple-darwin'\n", newline="\n")
        rustc.chmod(0o755)
        self.env.update(CARGO_HOME=shell_path(cargo), RUSTUP_HOME=shell_path(self.root / "rustup"), RUSTUP_TOOLCHAIN="stable-aarch64-apple-darwin")
        result = self.run_phase("rust")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("aarch64-apple-darwin", result.stderr)
        self.assertFalse((self.home / ".local/share/dotfiles/build/CARGO_HOME").exists())

    def test_dirty_vcpkg_checkout_is_not_updated(self):
        checkout = self.home / ".local/share/dotfiles/vcpkg"
        (checkout / ".git").mkdir(parents=True)
        self.command("git", '''case "$3" in
remote) echo https://github.com/microsoft/vcpkg.git;;
rev-parse) printf '%s\\n' "$2";;
status) echo ' M ports/local-change';;
*) echo unexpected-update >&2; exit 31;;
esac''')
        result = self.run_phase("vcpkg", "https://github.com/microsoft/vcpkg.git", "2026.10.16")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Preserve local vcpkg changes", result.stderr)
        self.assertNotIn("unexpected-update", result.stderr)
        self.assertFalse((self.home / ".local/share/dotfiles/build/VCPKG_ROOT").exists())

    def test_task_utilities_remain_available_outside_mise(self):
        for tool in ("cmake", "ninja", "python", "pwsh"):
            self.command(tool, f"echo '{tool} managed-version'")
        result = self.run_phase("tools")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        fragment = self.repo / "home/dot_config/dotfiles/path.sh"
        # Remove the task command directory. Discovery must come from publication.
        probe = 'PATH=/usr/bin:/bin; export PATH; . "$1"; cmake --version; ninja --version; python --version; pwsh --version'
        # The fragment only loads native-Mac build paths; retain the fake uname
        # as a shell function without making the task binaries discoverable.
        probe = 'uname() { echo Darwin; }; ' + probe
        result = subprocess.run([find_bash(), "-c", probe, "fresh-shell", fragment.as_posix()],
                                env=self.env, capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        for tool in ("cmake", "ninja", "python", "pwsh"):
            self.assertIn(f"{tool} managed-version", result.stdout)

    def test_failed_compiler_preflight_does_not_publish(self):
        self.command("uname", 'case "$1" in -m) echo arm64;; *) echo Darwin;; esac')
        self.command("xcode-select", "exit 23")
        result = self.run_phase("preflight")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(list(self.home.iterdir()), [])

    def test_unsupported_macos_stops_before_compiler_and_publication(self):
        self.command("uname", 'case "$1" in -m) echo arm64;; *) echo Darwin;; esac')
        self.command("sw_vers", "echo 14.7")
        self.command("xcode-select", "echo should-not-run")
        result = self.run_phase("preflight")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("macOS 15", result.stderr)
        self.assertNotIn("should-not-run", result.stdout)
        self.assertEqual(list(self.home.iterdir()), [])
