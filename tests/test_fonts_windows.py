import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import uuid

if os.name == "nt":
    import winreg


REPO = Path(__file__).resolve().parents[1]
FONT_KEY = r"Software\Microsoft\Windows NT\CurrentVersion\Fonts"


@unittest.skipUnless(os.name == "nt", "Windows font registration required")
class WindowsFontsTest(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory(prefix="native fonts ' ")
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name).resolve()
        self.assets = self.root / "assets"
        self.fonts = self.root / "user fonts"
        self.index = self.root / "index.tsv"
        self.state = self.root / "state.json"
        self.package = "fixture" + uuid.uuid4().hex
        self.name = "dotfiles-" + self.package + "-Example.ttf"
        self.label = "Dotfiles " + self.name + " (TrueType)"
        self.source = self.assets / self.package / "desktop/Example.ttf"
        self.source.parent.mkdir(parents=True)
        shutil.copy2(Path(os.environ["WINDIR"]) / "Fonts/segoeui.ttf", self.source)
        self.index.write_text(self.row(), encoding="utf-8")
        self.addCleanup(self.unregister)

    def row(self):
        return (self.package + "\tdesktop/Example.ttf\tExample.ttf\t" +
                hashlib.sha256(self.source.read_bytes()).hexdigest() + "\n")

    def run_installer(self, check=True):
        command = shutil.which("powershell.exe")
        result = subprocess.run([
            command, "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File",
            str(REPO / "scripts/install-fonts.ps1"), "-AssetRoot", str(self.assets),
            "-IndexPath", str(self.index), "-FontDirectory", str(self.fonts),
            "-StatePath", str(self.state),
        ], capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=60)
        if check:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def unregister(self):
        if (REPO / "scripts/install-fonts.ps1").exists():
            self.index.write_text("", encoding="utf-8")
            # Reconstruct only this fixture's ownership if a corruption test changed it.
            if (self.fonts / self.name).exists():
                self.state.write_text(json.dumps({"version": 1, "fonts": [{
                    "name": self.name, "sha256": hashlib.sha256(self.source.read_bytes()).hexdigest(),
                }]}), encoding="utf-8")
                self.run_installer()

    def registry_value(self):
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, FONT_KEY) as key:
            return winreg.QueryValueEx(key, self.label)[0]

    def test_install_repeat_and_missing_registration_repair(self):
        self.run_installer()
        installed = self.fonts / self.name
        self.assertEqual(installed.read_bytes(), self.source.read_bytes())
        self.assertEqual(self.registry_value(), str(installed))
        stamp = installed.stat().st_mtime_ns
        self.run_installer()
        self.assertEqual(installed.stat().st_mtime_ns, stamp)
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, FONT_KEY, 0, winreg.KEY_SET_VALUE) as key:
            winreg.DeleteValue(key, self.label)
        self.run_installer()
        self.assertEqual(self.registry_value(), str(installed))
        import ctypes
        remove = ctypes.windll.gdi32.RemoveFontResourceExW
        while remove(str(installed), 0, None):
            pass
        installed.unlink()
        self.run_installer()
        self.assertEqual(installed.read_bytes(), self.source.read_bytes())

    def test_changed_selection_preserves_unrelated_font(self):
        self.run_installer()
        sentinel = self.fonts / "unrelated.ttf"
        sentinel.write_bytes(b"keep")
        self.index.write_text("", encoding="utf-8")
        self.run_installer()
        self.assertFalse((self.fonts / self.name).exists())
        self.assertEqual(sentinel.read_bytes(), b"keep")
        with self.assertRaises(FileNotFoundError):
            self.registry_value()

    def test_hash_failure_happens_before_mutation(self):
        self.run_installer()
        before = self.state.read_bytes()
        installed = (self.fonts / self.name).read_bytes()
        self.source.write_bytes(b"corrupt font")
        result = self.run_installer(check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("checksum", result.stderr.lower())
        self.assertEqual(self.state.read_bytes(), before)
        self.assertEqual((self.fonts / self.name).read_bytes(), installed)

    def test_manifest_escape_is_rejected_before_cleanup(self):
        outside = self.root / "outside.ttf"
        outside.write_bytes(b"keep")
        self.state.write_text(json.dumps({"version": 1, "fonts": [{
            "name": "../outside.ttf", "sha256": "0" * 64,
        }]}), encoding="utf-8")
        result = self.run_installer(check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(outside.read_bytes(), b"keep")
        self.assertFalse(self.fonts.exists())

    def test_locked_replacement_reports_failure_and_keeps_manifest(self):
        self.run_installer()
        before = self.state.read_bytes()
        alternate = Path(os.environ["WINDIR"]) / "Fonts/segoeuib.ttf"
        shutil.copy2(alternate, self.source)
        self.index.write_text(self.row(), encoding="utf-8")
        # Python's Windows file handle prevents deleting/replacing the destination.
        with (self.fonts / self.name).open("rb"):
            result = self.run_installer(check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("close", result.stderr.lower())
        self.assertEqual(self.state.read_bytes(), before)

    def test_locked_cleanup_unpersists_all_owned_registrations(self):
        second = self.assets / self.package / "desktop/Second.ttf"
        shutil.copy2(self.source, second)
        self.index.write_text(self.row() + self.row().replace("Example.ttf", "Second.ttf"))
        self.run_installer()
        self.index.write_text("")
        labels = [self.label, self.label.replace("Example.ttf", "Second.ttf")]
        try:
            with (self.fonts / self.name).open("rb"):
                result = self.run_installer(check=False)
            self.assertNotEqual(result.returncode, 0)
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, FONT_KEY) as key:
                for label in labels:
                    with self.assertRaises(FileNotFoundError):
                        winreg.QueryValueEx(key, label)
        finally:
            self.run_installer()


if __name__ == "__main__":
    unittest.main()
