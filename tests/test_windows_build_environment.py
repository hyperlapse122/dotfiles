import base64
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
import uuid

if os.name == "nt":
    import winreg


# Native executables delegate only to this local fixture, never to installed tools.
LAUNCHER = r'''
using System;
using System.Diagnostics;
using System.IO;
using System.Text;
public static class FixtureCommand {
    private static string Quote(string value) {
        var result = new StringBuilder("\"");
        int slashes = 0;
        foreach (char c in value) {
            if (c == '\\') { slashes++; continue; }
            if (c == '"') { result.Append('\\', slashes * 2 + 1); }
            else { result.Append('\\', slashes); }
            result.Append(c); slashes = 0;
        }
        result.Append('\\', slashes * 2); result.Append('"');
        return result.ToString();
    }
    public static int Main(string[] args) {
        var arguments = new StringBuilder(Quote(Environment.GetEnvironmentVariable("BUILD_FIXTURE_SCRIPT")));
        arguments.Append(" " + Quote(Path.GetFileNameWithoutExtension(Process.GetCurrentProcess().MainModule.FileName)));
        foreach (var arg in args) arguments.Append(" " + Quote(arg));
        var start = new ProcessStartInfo(Environment.GetEnvironmentVariable("BUILD_FIXTURE_PYTHON"), arguments.ToString());
        start.UseShellExecute = false;
        using (var process = Process.Start(start)) { process.WaitForExit(); return process.ExitCode; }
    }
}
'''

FIXTURE = r'''
import json
import os
from pathlib import Path
import shutil
import sys

name, *args = sys.argv[1:]
state_path = Path(os.environ["BUILD_FIXTURE_STATE"])
state = json.loads(state_path.read_text(encoding="utf-8"))
with Path(os.environ["BUILD_FIXTURE_LOG"]).open("a", encoding="utf-8") as log:
    log.write(json.dumps([name, args]) + "\n")
operation = name
if name == "git":
    operation += ":" + (args[2] if args[:1] == ["-C"] else args[0])
if state.get("fail") == operation:
    print("fixture native failure: " + operation, file=sys.stderr)
    sys.exit(23)
root = Path(os.environ["BUILD_FIXTURE_VCPKG"])
if name == "dotnet":
    for major in state["sdks"]:
        print(str(major) + ".0.100 [" + str(Path(sys.argv[0]).parent) + "]")
elif name == "rustc":
    print("rustc 1.92.0 (fixture)")
    print("host: x86_64-pc-windows-msvc")
elif name == "cargo":
    print("cargo 1.92.0 (fixture)")
elif name == "rustup":
    if args[:2] == ["target", "list"]:
        print("\n".join(state["targets"]))
    elif args[:2] == ["toolchain", "list"]:
        print("stable-x86_64-pc-windows-msvc" + (" (active, default)" if state["default"] == "stable" else ""))
        if state["default"] == "nightly":
            print("nightly-x86_64-pc-windows-msvc (default)")
    elif args[:1] == ["default"]:
        state["default"] = args[1]
    else:
        sys.exit(87)
elif name == "git":
    if args[0] == "clone":
        root.mkdir(parents=True, exist_ok=True)
        (root / ".git").mkdir()
        (root / "ports").mkdir()
        (root / "scripts/buildsystems/msbuild").mkdir(parents=True)
        (root / "scripts/buildsystems/msbuild/vcpkg.targets").write_text("fixture", encoding="utf-8")
        (root / "bootstrap-vcpkg.bat").write_text(
            '@echo off\n"%BUILD_FIXTURE_PYTHON%" "%BUILD_FIXTURE_SCRIPT%" bootstrap\nexit /b %errorlevel%\n', encoding="utf-8")
    elif args[2] == "rev-parse":
        print(root if "--show-toplevel" in args else state["commit"])
    elif args[2] == "remote":
        print(state["origin"])
    elif args[2] == "status":
        if state["dirty"]:
            print(" M ports/keep.txt")
    elif args[2] == "fetch":
        state["fetched"] = args[-1]
    elif args[2] == "checkout":
        state["checkout"] = args[-1]
    else:
        sys.exit(87)
elif name == "bootstrap":
    shutil.copy2(os.environ["BUILD_FIXTURE_LAUNCHER"], root / "vcpkg.exe")
elif name == "vcpkg":
    if args == ["integrate", "install"]:
        state["integration"] = str(root)
    elif args == ["version"]:
        print("vcpkg fixture version")
    else:
        sys.exit(87)
else:
    sys.exit(87)
state_path.write_text(json.dumps(state), encoding="utf-8")
'''


def ps_quote(value):
    return "'" + str(value).replace("'", "''") + "'"


@unittest.skipUnless(os.name == "nt", "Windows PowerShell and isolated registry required")
class WindowsBuildEnvironmentTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.shell = Path(os.environ["SystemRoot"]) / "System32/WindowsPowerShell/v1.0/powershell.exe"
        cls.shared = tempfile.TemporaryDirectory(prefix="build command launcher ")
        cls.addClassCleanup(cls.shared.cleanup)
        cls.launcher = Path(cls.shared.name) / "fixture.exe"
        source = Path(cls.shared.name) / "fixture.cs"
        source.write_text(LAUNCHER, encoding="utf-8")
        command = ("$ErrorActionPreference = 'Stop'; Add-Type -Path " + ps_quote(source) +
                   " -OutputAssembly " + ps_quote(cls.launcher) + " -OutputType ConsoleApplication")
        result = cls.powershell(command)
        if result.returncode:
            raise AssertionError(result.stdout + result.stderr)

    @classmethod
    def powershell(cls, command, env=None):
        command = "[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding; " + command
        encoded = base64.b64encode(command.encode("utf-16le")).decode("ascii")
        return subprocess.run(
            [str(cls.shell), "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
             "-EncodedCommand", encoded], env=env, capture_output=True, text=True,
            encoding="utf-8", errors="backslashreplace", timeout=60,
        )

    def setUp(self):
        self.repo = Path(__file__).resolve().parents[1]
        scratch = tempfile.TemporaryDirectory(prefix="build environment '")
        self.addCleanup(scratch.cleanup)
        # Canonicalize only fixture paths; raw registry strings remain exact below.
        self.root = Path(scratch.name).resolve() / "ユーザー tools"
        self.root.mkdir()
        self.registry = "Software\\dotfiles-build-test-" + uuid.uuid4().hex
        with winreg.CreateKey(winreg.HKEY_CURRENT_USER, self.registry) as key:
            winreg.SetValueEx(key, "Unrelated", 0, winreg.REG_EXPAND_SZ, "%KEEP%\\untouched")
        self.addCleanup(winreg.DeleteKey, winreg.HKEY_CURRENT_USER, self.registry)
        self.dotnet = self.root / "dotnet shared"
        self.cargo = self.root / "cargo"
        self.rustup = self.root / "rustup"
        self.vcpkg = self.root / "vcpkg managed"
        self.commands = self.root / "commands"
        for directory in (self.dotnet, self.cargo / "bin", self.rustup, self.commands):
            directory.mkdir(parents=True)
        for name, directory in (("dotnet", self.dotnet), ("git", self.commands),
                                ("rustup", self.cargo / "bin"), ("rustc", self.cargo / "bin"),
                                ("cargo", self.cargo / "bin")):
            shutil.copy2(self.launcher, directory / (name + ".exe"))
        self.fixture = self.root / "fixture.py"
        self.fixture.write_text(FIXTURE, encoding="utf-8")
        self.state_path = self.root / "state.json"
        self.log_path = self.root / "calls.jsonl"
        self.state = {
            "sdks": [8, 10], "targets": ["x86_64-pc-windows-msvc", "aarch64-pc-windows-msvc"],
            "default": None, "dirty": False, "commit": "a" * 40,
            "origin": "https://github.com/microsoft/vcpkg.git",
        }
        self.save_state()
        self.env = os.environ.copy()
        self.env.update({
            "PATH": str(self.commands), "DOTNET_ROOT": str(self.dotnet),
            "CARGO_HOME": str(self.cargo), "RUSTUP_HOME": str(self.rustup),
            "RUSTUP_TOOLCHAIN": "stable", "BUILD_FIXTURE_PYTHON": sys.executable,
            "BUILD_FIXTURE_SCRIPT": str(self.fixture), "BUILD_FIXTURE_STATE": str(self.state_path),
            "BUILD_FIXTURE_LOG": str(self.log_path), "BUILD_FIXTURE_VCPKG": str(self.vcpkg),
            "BUILD_FIXTURE_LAUNCHER": str(self.launcher), "PYTHONIOENCODING": "utf-8",
        })

    def save_state(self):
        self.state_path.write_text(json.dumps(self.state), encoding="utf-8")

    def stored_state(self):
        return json.loads(self.state_path.read_text(encoding="utf-8"))

    def calls(self):
        if not self.log_path.exists():
            return []
        return [json.loads(line) for line in self.log_path.read_text(encoding="utf-8").splitlines()]

    def set_value(self, name, value, kind=None):
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, self.registry, 0, winreg.KEY_SET_VALUE) as key:
            winreg.SetValueEx(key, name, 0, kind or winreg.REG_SZ, value)

    def value(self, name):
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, self.registry) as key:
            return winreg.QueryValueEx(key, name)

    def run_operation(self, operation, check=True):
        script = self.repo / "scripts/windows-build-environment.ps1"
        command = (
            "$ErrorActionPreference = 'Stop'; . " + ps_quote(script) + "; "
            "$key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey(" + ps_quote(self.registry) + ", $true); "
            "try { " + operation + " } finally { $key.Dispose() }"
        )
        result = self.powershell(command, self.env)
        if check:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.value("Unrelated"), ("%KEEP%\\untouched", winreg.REG_EXPAND_SZ))
        return result

    def apply_phase(self, phase, check=True, revision=None):
        if phase == "Dotnet":
            expression = "Get-BuildDotnetEnvironment 10"
        elif phase == "Rust":
            expression = "Get-BuildRustEnvironment"
        else:
            expression = ("Get-BuildVcpkgEnvironment -Repository 'https://github.com/microsoft/vcpkg.git' "
                          "-Revision " + ps_quote(revision or "a" * 40) + " -Root " + ps_quote(self.vcpkg))
        return self.run_operation("$values = " + expression + "; Set-BuildUserEnvironment -Key $key -Values $values", check)

    def test_preserves_raw_environment_and_places_managed_paths_first(self):
        old = self.root / "old vcpkg"
        self.set_value("DOTNET_ROOT", str(self.dotnet), winreg.REG_EXPAND_SZ)
        self.set_value("CARGO_HOME", str(self.cargo))
        self.set_value("VCPKG_ROOT", str(old), winreg.REG_EXPAND_SZ)
        raw = ';'.join([r'%KEEP%\compiler', str(old), '"' + str(self.dotnet) + '"',
                        str(self.cargo / "bin") + "\\", r'C:\other compiler', '', str(self.dotnet)])
        self.set_value("Path", raw, winreg.REG_EXPAND_SZ)
        self.apply_phase("Vcpkg")
        expected = ';'.join([str(self.dotnet), str(self.cargo / "bin"), str(self.vcpkg),
                             r'%KEEP%\compiler', r'C:\other compiler', ''])
        self.assertEqual(self.value("Path"), (expected, winreg.REG_EXPAND_SZ))
        self.assertEqual(self.value("VCPKG_ROOT"), (str(self.vcpkg), winreg.REG_EXPAND_SZ))
        self.assertEqual(self.value("DOTNET_ROOT"), (str(self.dotnet), winreg.REG_EXPAND_SZ))
        self.apply_phase("Vcpkg")
        self.assertEqual(self.value("Path"), (expected, winreg.REG_EXPAND_SZ))
        self.set_value("Path", r'C:\other compiler', winreg.REG_EXPAND_SZ)
        self.apply_phase("Vcpkg")
        self.assertEqual(self.value("Path")[0], ';'.join(
            [str(self.dotnet), str(self.cargo / "bin"), str(self.vcpkg), r'C:\other compiler']))
        self.assertEqual(self.stored_state()["integration"], str(self.vcpkg))

    def test_sdk_major_is_checked_in_shared_root(self):
        result = self.apply_phase("Dotnet")
        self.assertIn(str(self.dotnet), result.stdout)
        self.assertEqual(self.value("DOTNET_ROOT"), (str(self.dotnet), winreg.REG_SZ))
        self.state["sdks"] = [8]
        self.save_state()
        result = self.apply_phase("Dotnet", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("SDK 10 is missing", result.stdout + result.stderr)

    def test_fresh_rust_default_is_usable_without_persistent_override(self):
        self.apply_phase("Rust")
        self.assertEqual(self.stored_state()["default"], "stable")
        self.assertEqual(self.value("CARGO_HOME"), (str(self.cargo), winreg.REG_SZ))
        self.assertEqual(self.value("RUSTUP_HOME"), (str(self.rustup), winreg.REG_SZ))
        with self.assertRaises(FileNotFoundError):
            self.value("RUSTUP_TOOLCHAIN")
        self.apply_phase("Rust")
        self.assertEqual(sum(name == "rustup" and args[:1] == ["default"] for name, args in self.calls()), 1)

    def test_existing_rust_default_and_project_selection_survive(self):
        self.state["default"] = "nightly"
        self.save_state()
        project = self.root / "rust-toolchain.toml"
        project.write_text('[toolchain]\nchannel = "nightly"\n', encoding="utf-8")
        self.set_value("RUSTUP_TOOLCHAIN", "user-existing-selection")
        self.apply_phase("Rust")
        self.assertEqual(self.stored_state()["default"], "nightly")
        self.assertEqual(self.value("RUSTUP_TOOLCHAIN")[0], "user-existing-selection")
        self.assertEqual(project.read_text(encoding="utf-8"), '[toolchain]\nchannel = "nightly"\n')

    def test_missing_rust_target_stops_before_default_and_environment_changes(self):
        self.state["targets"] = ["x86_64-pc-windows-msvc"]
        self.save_state()
        result = self.apply_phase("Rust", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("aarch64-pc-windows-msvc", result.stdout + result.stderr)
        self.assertIsNone(self.stored_state()["default"])
        with self.assertRaises(FileNotFoundError):
            self.value("CARGO_HOME")

    def test_dirty_vcpkg_checkout_is_never_reset(self):
        self.apply_phase("Vcpkg")
        keep = self.vcpkg / "ports/keep.txt"
        keep.write_text("local changes", encoding="utf-8")
        self.state = self.stored_state()
        self.state["dirty"] = True
        self.save_state()
        previous_calls = len(self.calls())
        result = self.apply_phase("Vcpkg", check=False, revision="b" * 40)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("dirty vcpkg", result.stdout + result.stderr)
        self.assertEqual(keep.read_text(encoding="utf-8"), "local changes")
        self.assertFalse(any(name == "git" and args[2:3] in (["fetch"], ["checkout"])
                             for name, args in self.calls()[previous_calls:]))
        self.assertEqual(self.stored_state()["checkout"], "a" * 40)

    def test_clean_existing_microsoft_checkout_is_adopted(self):
        self.run_operation("Invoke-BuildNative 'git' @('clone', "
                           "'https://github.com/microsoft/vcpkg.git', " + ps_quote(self.vcpkg) + ")")
        self.apply_phase("Vcpkg")
        self.assertEqual(self.stored_state()["integration"], str(self.vcpkg))
        self.assertEqual(sum(name == "git" and args[0] == "clone" for name, args in self.calls()), 1)

    def test_checkout_from_other_origin_is_refused(self):
        self.run_operation("Invoke-BuildNative 'git' @('clone', "
                           "'https://github.com/microsoft/vcpkg.git', " + ps_quote(self.vcpkg) + ")")
        self.state["origin"] = "https://example.invalid/unrelated.git"
        self.save_state()
        result = self.apply_phase("Vcpkg", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("origin is not the Microsoft upstream", result.stdout + result.stderr)
        self.assertNotIn("checkout", self.stored_state())

    def test_unrelated_checkout_is_left_untouched(self):
        self.vcpkg.mkdir()
        keep = self.vcpkg / "keep.txt"
        keep.write_text("not owned", encoding="utf-8")
        result = self.apply_phase("Vcpkg", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unrelated directory", result.stdout + result.stderr)
        self.assertEqual(keep.read_text(encoding="utf-8"), "not owned")
        self.assertEqual(self.calls(), [])

    def test_native_failures_cannot_publish_environment_success(self):
        for operation, phase in (("dotnet", "Dotnet"), ("cargo", "Rust"),
                                 ("git:clone", "Vcpkg"), ("git:fetch", "Vcpkg"),
                                 ("git:checkout", "Vcpkg"), ("bootstrap", "Vcpkg"),
                                 ("vcpkg", "Vcpkg")):
            with self.subTest(operation=operation):
                self.state = self.stored_state()
                self.state["fail"] = operation
                self.save_state()
                self.set_value("Path", r'C:\untouched', winreg.REG_SZ)
                result = self.apply_phase(phase, check=False)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("exit code 23", result.stdout + result.stderr)
                self.assertEqual(self.value("Path"), (r'C:\untouched', winreg.REG_SZ))
                with self.assertRaises(FileNotFoundError):
                    self.value("VCPKG_ROOT")

    def test_tag_pin_and_changed_commit_update_owned_tree(self):
        self.apply_phase("Vcpkg", revision="2026.10.29")
        self.assertEqual(self.stored_state()["fetched"], "refs/tags/2026.10.29")
        self.state = self.stored_state()
        self.state["commit"] = "b" * 40
        self.save_state()
        self.apply_phase("Vcpkg", revision="b" * 40)
        self.assertEqual(self.stored_state()["checkout"], "b" * 40)
        self.assertEqual(sum(name == "git" and args[0] == "clone" for name, args in self.calls()), 1)


if __name__ == "__main__":
    unittest.main()
