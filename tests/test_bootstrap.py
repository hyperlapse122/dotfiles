import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import unittest

from smoke_personal_apps import temporary_destination


class TemporaryDestinationTest(unittest.TestCase):
    def test_removes_ordinary_temporary_files(self):
        with temporary_destination() as scratch:
            root = Path(scratch)
            (root / "sentinel").write_bytes(b"temporary fixture")
        self.assertFalse(root.exists())

    @unittest.skipUnless(os.name == "nt", "Windows open-file deletion semantics required")
    def test_locked_file_cleanup_still_raises(self):
        root = None
        stream = None
        try:
            with self.assertRaises(PermissionError):
                with temporary_destination() as scratch:
                    root = Path(scratch)
                    packed = root / "locked.idx"
                    packed.write_bytes(b"open packed object index fixture")
                    packed.chmod(stat.S_IREAD)
                    stream = packed.open("rb")
        finally:
            if stream is not None:
                stream.close()
            if root is not None and root.exists():
                packed.chmod(stat.S_IWRITE)
                shutil.rmtree("\\\\?\\" + str(root))

    @unittest.skipUnless(os.name == "nt", "Windows read-only deletion semantics required")
    def test_removes_readonly_git_pack_file_under_long_unicode_path(self):
        root = None
        packed = None
        try:
            with temporary_destination() as scratch:
                root = Path(scratch)
                directory = root / ("native 한글 " * 8) / ("deep cache " * 8) / ".git/objects/pack"
                # Use the same extended-length prefix as the cleanup path.
                packed = Path("\\\\?\\" + str(directory)) / "pack-fixture.idx"
                packed.parent.mkdir(parents=True)
                packed.write_bytes(b"packed object index fixture")
                packed.chmod(stat.S_IREAD)
                self.assertGreater(len(str(packed)), 260)
            self.assertFalse(root.exists())
        finally:
            # A failing cleanup must not leave the regression's read-only file behind.
            if packed is not None and packed.exists():
                packed.chmod(stat.S_IWRITE)
                packed.unlink()
            if root is not None and root.exists():
                shutil.rmtree("\\\\?\\" + str(root))


class BootstrapIsolationTest(unittest.TestCase):
    def test_install_does_not_run_personal_chezmoi_hooks(self):
        repo = Path(__file__).resolve().parents[1]
        mise = shutil.which("mise")
        self.assertIsNotNone(mise, "Install mise before running bootstrap tests")

        with temporary_destination() as scratch:
            root = Path(scratch)
            home = root / "user home"
            home.mkdir()
            existing = home / "personal-setting"
            existing.write_text("unchanged", encoding="utf-8")
            marker = home / "unexpected-hook"
            install_marker = home / "unexpected-app-install"
            config_root = root / "config"
            config_dir = config_root / "chezmoi"
            config_dir.mkdir(parents=True)
            command = "from pathlib import Path; Path(" + repr(str(marker)) + ").write_text('ran')"
            hook = "command = " + json.dumps(sys.executable) + "\nargs = " + json.dumps(["-c", command]) + "\n"
            config_text = "[hooks.managed.pre]\n" + hook + "\n[hooks.read-source-state.pre]\n" + hook
            config = config_dir / "chezmoi.toml"
            config.write_text(config_text, encoding="utf-8")

            env = os.environ.copy()
            if os.name == "nt":
                data_dir = Path(env["LOCALAPPDATA"]) / "mise"
                cache_dir = data_dir / "cache"
            else:
                data_dir = Path(env.get("XDG_DATA_HOME", Path.home() / ".local/share")) / "mise"
                cache_dir = Path(env.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "mise"
            env.update({
                "MISE_DATA_DIR": env.get("MISE_DATA_DIR", str(data_dir)),
                "MISE_CACHE_DIR": env.get("MISE_CACHE_DIR", str(cache_dir)),
                "MISE_CONFIG_DIR": str(root / "mise-config"),
                "MISE_TRUSTED_CONFIG_PATHS": str(repo),
                "USERPROFILE": str(home),
                "HOME": str(home),
                "APPDATA": str(config_root),
                "XDG_CONFIG_HOME": str(config_root),
                "XDG_CACHE_HOME": str(root / "cache"),
                "XDG_DATA_HOME": str(root / "data"),
                "XDG_STATE_HOME": str(root / "state"),
                "MISE_DOTNET_ROOT": str(root / "native dotnet"),
                "MISE_CARGO_HOME": str(root / "native cargo"),
                "MISE_RUSTUP_HOME": str(root / "native rustup"),
            })
            if os.name == "nt":
                commands = root / "commands"
                commands.mkdir()
                (commands / "winget.cmd").write_text(
                    '@echo off\necho invoked> "%BOOTSTRAP_INSTALL_MARKER%"\nexit /b 89\n',
                    encoding="ascii",
                )
                env["PATH"] = str(commands) + os.pathsep + env["PATH"]
                env["BOOTSTRAP_INSTALL_MARKER"] = str(install_marker)

            for attempt in range(2):
                with self.subTest(attempt=attempt + 1):
                    result = subprocess.run(
                        [mise, "install"], cwd=repo, env=env,
                        capture_output=True, text=True, encoding="utf-8",
                        errors="backslashreplace", timeout=120,
                    )
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertFalse(marker.exists(), "Initialization ran a personal chezmoi hook")
                    self.assertFalse(install_marker.exists(), "Initialization invoked an app installer")
                    self.assertEqual(existing.read_text(encoding="utf-8"), "unchanged")
                    self.assertEqual(config.read_text(encoding="utf-8"), config_text)
                    for name in ("native dotnet", "native cargo", "native rustup"):
                        self.assertFalse((root / name).exists(),
                                         "Initialization installed task-only build tools")
                    self.assertFalse((home / ".local/share/dotfiles/vcpkg").exists(),
                                     "Initialization provisioned a native dependency checkout")


if __name__ == "__main__":
    unittest.main()
