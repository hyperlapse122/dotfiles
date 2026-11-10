import os
from pathlib import Path
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
class LinuxBuildEnvironmentTest(unittest.TestCase):
    def setUp(self):
        self.repo = Path(__file__).resolve().parents[1]
        self.scratch = tempfile.TemporaryDirectory(prefix="linux build ")
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        self.bin = self.root / "commands"
        self.bin.mkdir()
        self.home = self.root / "home"
        self.home.mkdir()
        self.env = os.environ.copy()
        self.env.update(HOME=shell_path(self.home), PATH=shell_path(self.bin) + ":/usr/bin:/bin")
        self.command("uname", "echo Linux")
        self.command("python3", "exit 0")
        self.command("cc", "echo x86_64-redhat-linux")
        self.command("c++", "echo x86_64-redhat-linux")

    def command(self, name, body):
        path = self.bin / name
        path.write_text("#!/bin/sh\n" + body + "\n", encoding="utf-8", newline="\n")
        path.chmod(0o755)
        return path

    def run_phase(self, *args):
        return subprocess.run([find_bash(), "-c", 'PATH="$1:/usr/bin:/bin"; export PATH; shift; exec /bin/sh "$@"',
                               "probe", getattr(self, "task_path", shell_path(self.bin)), self.repo.joinpath("scripts/linux-build-environment.sh").as_posix(), *args],
                              env=self.env, capture_output=True, text=True, timeout=30)

    def test_other_platform_does_not_publish_environment(self):
        self.command("uname", "echo Darwin")
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
        rustc.write_text("#!/bin/sh\necho 'host: aarch64-unknown-linux-gnu'\n", newline="\n")
        rustc.chmod(0o755)
        self.task_path = shell_path(cargo / "bin") + ":" + shell_path(self.bin)
        self.env.update(CARGO_HOME=shell_path(cargo), RUSTUP_HOME=shell_path(self.root / "rustup"), RUSTUP_TOOLCHAIN="stable-x86_64-unknown-linux-gnu")
        result = self.run_phase("rust")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("x86_64-unknown-linux-gnu", result.stderr)
        self.assertFalse((self.home / ".local/share/dotfiles/build/CARGO_HOME").exists())

    def test_external_rust_proxies_work_without_cargo_bin(self):
        cargo = self.root / "cargo data"
        cargo.mkdir()
        self.env.update(CARGO_HOME=shell_path(cargo), RUSTUP_HOME=shell_path(self.root / "rustup"),
                        RUSTUP_TOOLCHAIN="stable-x86_64-unknown-linux-gnu")
        self.command("rustc", "echo 'host: x86_64-unknown-linux-gnu'")
        self.command("cargo", "echo 'cargo external-proxy'")
        self.command("rustup", '''case "$1 $2" in
"target list") echo x86_64-unknown-linux-gnu;;
"toolchain list") echo 'stable-x86_64-unknown-linux-gnu (default)';;
*) exit 31;;
esac''')
        result = self.run_phase("rust")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((cargo / "bin").exists())
        fragment = self.repo / "home/dot_config/dotfiles/path.sh"
        probe = 'uname() { echo Linux; }; PATH=/usr/bin:/bin; export PATH; . "$1"; rustc --version --verbose; cargo --version; rustup target list --installed'
        result = subprocess.run([find_bash(), "-c", probe, "fresh-shell", fragment.as_posix()],
                                env=self.env, capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("host: x86_64-unknown-linux-gnu", result.stdout)
        self.assertIn("cargo external-proxy", result.stdout)

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
        # Keep the Linux identity fixture without exposing task binaries.
        probe = 'uname() { echo Linux; }; ' + probe
        result = subprocess.run([find_bash(), "-c", probe, "fresh-shell", fragment.as_posix()],
                                env=self.env, capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        for tool in ("cmake", "ninja", "python", "pwsh"):
            self.assertIn(f"{tool} managed-version", result.stdout)

    def test_fedora_compiler_targets_pass_preflight(self):
        result = self.run_phase("preflight")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_non_native_compiler_target_fails_naming_the_compiler(self):
        self.command("c++", "echo aarch64-redhat-linux")
        result = self.run_phase("preflight")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("c++", result.stderr)
        self.assertIn("x86_64-redhat-linux", result.stderr)

    def test_failed_compiler_preflight_does_not_publish(self):
        self.command("c++", "exit 23")
        result = self.run_phase("preflight")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(list(self.home.iterdir()), [])

    def test_unsupported_host_stops_before_publication(self):
        self.command("python3", "echo unsupported-host >&2; exit 23")
        result = self.run_phase("tools")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unsupported-host", result.stderr)
        self.assertIn("Fedora", result.stderr)
        self.assertEqual(list(self.home.iterdir()), [])

    def test_unrelated_vcpkg_directory_is_preserved(self):
        checkout = self.home / ".local/share/dotfiles/vcpkg"
        checkout.mkdir(parents=True)
        sentinel = checkout / "keep"
        sentinel.write_text("user data")
        self.command("git", "echo unexpected-git >&2; exit 31")
        result = self.run_phase("vcpkg", "https://github.com/microsoft/vcpkg.git", "2026.10.16")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unrelated vcpkg directory", result.stderr)
        self.assertNotIn("unexpected-git", result.stderr)
        self.assertEqual(sentinel.read_text(), "user data")

    def clean_vcpkg(self):
        checkout = self.home / ".local/share/dotfiles/vcpkg"
        (checkout / ".git").mkdir(parents=True)
        (checkout / "scripts/buildsystems").mkdir(parents=True)
        (checkout / "scripts/buildsystems/vcpkg.cmake").touch()
        (checkout / "bootstrap-vcpkg.sh").write_text("#!/bin/sh\nexit 0\n")
        executable = checkout / "vcpkg"
        executable.write_text("#!/bin/sh\necho vcpkg-managed\n")
        executable.chmod(0o755)
        self.command("git", '''case "$3" in
remote) echo https://github.com/microsoft/vcpkg.git;;
rev-parse) if [ "$4" = --show-toplevel ]; then printf '%s\\n' "$2"; else echo 9eec002df1cd109f8f104cd966a763daf9751489; fi;;
status) ;;
fetch) [ "$5" = refs/tags/2026.10.16 ] || exit 32;;
checkout) [ "$5" = 9eec002df1cd109f8f104cd966a763daf9751489 ] || exit 33;;
*) exit 31;;
esac''')
        return checkout

    def test_clean_vcpkg_reuses_pin_and_converges(self):
        checkout = self.clean_vcpkg()
        for _ in range(2):
            result = self.run_phase("vcpkg", "https://github.com/microsoft/vcpkg.git", "2026.10.16")
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.home / ".local/share/dotfiles/build/VCPKG_ROOT").read_text().strip(),
                         shell_path(checkout))

    def test_all_published_tools_in_external_shell_without_task_environment(self):
        sdk = self.root / "shared sdk"
        sdk.mkdir()
        dotnet = sdk / "dotnet"
        dotnet.write_text("#!/bin/sh\necho '8.0.100 [sdk]'\necho '10.0.100 [sdk]'\n")
        dotnet.chmod(0o755)
        self.env["DOTNET_ROOT"] = shell_path(sdk)
        self.env.update(CARGO_HOME=shell_path(self.root / "cargo data"),
                        RUSTUP_HOME=shell_path(self.root / "rustup data"),
                        RUSTUP_TOOLCHAIN="stable-x86_64-unknown-linux-gnu")
        self.command("rustc", '''[ -z "${RUSTUP_TOOLCHAIN-}" ] || [ "$RUSTUP_TOOLCHAIN" = stable-x86_64-unknown-linux-gnu ] || exit 41
echo 'host: x86_64-unknown-linux-gnu' ''')
        self.command("cargo", 'echo cargo-managed')
        self.command("rustup", '''case "$1 $2" in
"target list") echo x86_64-unknown-linux-gnu;;
"toolchain list") echo 'user-toolchain (default)';;
*) echo must-preserve-existing-default >&2; exit 31;;
esac''')
        for tool in ("cmake", "ninja", "python", "pwsh", "minikube", "kubectl"):
            self.command(tool, f"echo {tool}-managed")
        self.clean_vcpkg()
        for phase in (("dotnet", "8"), ("dotnet", "10"), ("rust",), ("tools",), ("kubernetes",),
                      ("vcpkg", "https://github.com/microsoft/vcpkg.git", "2026.10.16")):
            result = self.run_phase(*phase)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        clean = self.env.copy()
        for name in ("DOTNET_ROOT", "CARGO_HOME", "RUSTUP_HOME", "RUSTUP_TOOLCHAIN", "VCPKG_ROOT"):
            clean.pop(name, None)
        probe = '''set -eu
uname() { echo Linux; }
PATH=/usr/bin:/bin
export PATH
. "$1"
[ -z "${RUSTUP_TOOLCHAIN-}" ]
dotnet --list-sdks
rustc --version --verbose
cargo --version
rustup toolchain list
for tool in cmake ninja python pwsh minikube kubectl vcpkg; do "$tool" --version; done
'''
        result = subprocess.run([find_bash(), "-c", probe, "external-shell",
                                 str(self.repo / "home/dot_config/dotfiles/path.sh")],
                                cwd=self.root, env=clean, capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        for value in ("8.0.100", "10.0.100", "user-toolchain (default)", "vcpkg-managed",
                      "cmake-managed", "ninja-managed", "python-managed", "pwsh-managed",
                      "minikube-managed", "kubectl-managed"):
            self.assertIn(value, result.stdout)

    def test_native_smoke_refuses_ineligible_host_before_reading_home(self):
        import importlib.util
        from unittest.mock import patch
        spec = importlib.util.spec_from_file_location("smoke_linux_build", self.repo / "tests/smoke_linux_build_environment.py")
        smoke = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(smoke)
        with patch("platform.system", return_value="Darwin"), patch.object(smoke.tempfile, "TemporaryDirectory") as temporary:
            with self.assertRaisesRegex(RuntimeError, "Requires Linux"):
                smoke.verify(self.root / "does not exist")
            temporary.assert_not_called()
