import base64
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import uuid

if os.name == "nt":
    import winreg


@unittest.skipUnless(os.name == "nt", "Windows registry provider required")
class NativeCaWindowsTest(unittest.TestCase):
    def setUp(self):
        self.repo = Path(__file__).resolve().parents[1]
        self.shell = Path(os.environ["SystemRoot"]) / "System32/WindowsPowerShell/v1.0/powershell.exe"
        self.assertIsNotNone(shutil.which("chezmoi"), "Install chezmoi before running registry tests")
        scratch = tempfile.TemporaryDirectory(prefix="native ca registry ")
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name)
        self.home = self.root / "home"
        self.home.mkdir()
        self.config = self.root / "chezmoi.toml"
        self.config.write_text("", encoding="utf-8")
        self.registry_path = "Software\\dotfiles-native-ca-test-" + uuid.uuid4().hex
        self.addCleanup(self.remove_registry_tree, self.registry_path)
        with winreg.CreateKey(winreg.HKEY_CURRENT_USER, self.registry_path) as key:
            winreg.SetValueEx(key, "unrelated-root", 0, winreg.REG_SZ, "preserve root")
        self.body = self.root / "native-ca.ps1"
        rendered = subprocess.run(
            ["chezmoi", "--source", str(self.repo), "--destination", str(self.home),
             "--config", str(self.config), "--cache", str(self.root / "cache"),
             "--persistent-state", str(self.root / "state.boltdb"), "--no-tty",
             "execute-template", '{{ includeTemplate "native-ca-windows" . }}'],
            capture_output=True, text=True, encoding="utf-8", errors="backslashreplace", timeout=60,
        )
        self.assertEqual(rendered.returncode, 0, rendered.stdout + rendered.stderr)
        self.body.write_text(rendered.stdout, encoding="utf-8-sig")

    def remove_registry_tree(self, path):
        try:
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, path, 0, winreg.KEY_READ) as key:
                children = []
                while True:
                    try:
                        children.append(winreg.EnumKey(key, len(children)))
                    except OSError as error:
                        if error.winerror != 259:  # ERROR_NO_MORE_ITEMS
                            raise
                        break
            for child in children:
                self.remove_registry_tree(path + "\\" + child)
            winreg.DeleteKey(winreg.HKEY_CURRENT_USER, path)
        except FileNotFoundError:
            pass

    def run_body(self, deny_write=False):
        # Only this child process loses its normal HKCU drive. Stop before invoking
        # the production body if redirection or its root check fails.
        registry_root = "HKEY_CURRENT_USER\\" + self.registry_path
        quoted_root = registry_root.replace("'", "''")
        quoted_body = str(self.body).replace("'", "''")
        command = (
            "$ErrorActionPreference = 'Stop'; "
            "Remove-PSDrive -Name HKCU -Force -ErrorAction Stop; "
            f"$expectedRoot = '{quoted_root}'; "
            "New-PSDrive -Name HKCU -PSProvider Registry -Root $expectedRoot "
            "-Scope Global -ErrorAction Stop | Out-Null; "
            "$drive = Get-PSDrive -Name HKCU -ErrorAction Stop; "
            "if ($drive.Provider.Name -ne 'Registry' -or $drive.Root -ne $expectedRoot) "
            "{ throw 'Disposable HKCU redirection failed' }; "
        )
        if deny_write:
            ready = str(self.root / "denial-ready").replace("'", "''")
            acl_path = (self.registry_path + "\\Environment").replace("'", "''")
            # Retain a permissions-only handle so denying SetValue cannot stop
            # restoration by forcing the provider to reopen the key for writing.
            command += (
                "$aclKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey("
                f"'{acl_path}', [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree, "
                "([Security.AccessControl.RegistryRights]::ReadPermissions -bor "
                "[Security.AccessControl.RegistryRights]::ChangePermissions)); "
                "$originalAcl = $aclKey.GetAccessControl(); "
                "$deniedAcl = $aclKey.GetAccessControl(); "
                "$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User; "
                "$rule = New-Object Security.AccessControl.RegistryAccessRule "
                "($sid, [Security.AccessControl.RegistryRights]::SetValue, "
                "[Security.AccessControl.AccessControlType]::Deny); "
                "$deniedAcl.AddAccessRule($rule); "
                "try { "
                "$aclKey.SetAccessControl($deniedAcl); "
                f"[IO.File]::WriteAllText('{ready}', 'ready'); "
                f"& '{quoted_body}' "
                "} finally { "
                "try { $aclKey.SetAccessControl($originalAcl) } finally { $aclKey.Dispose() } "
                "}"
            )
        else:
            command += f"& '{quoted_body}'"
        encoded = base64.b64encode(command.encode("utf-16le")).decode("ascii")
        return subprocess.run(
            [str(self.shell), "-NoLogo", "-NoProfile", "-NonInteractive",
             "-ExecutionPolicy", "Bypass", "-EncodedCommand", encoded],
            capture_output=True, text=True, encoding="utf-8", errors="backslashreplace", timeout=60,
        )

    def assert_root_preserved(self):
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, self.registry_path) as key:
            self.assertEqual(winreg.QueryValueEx(key, "unrelated-root"), ("preserve root", winreg.REG_SZ))

    def test_creates_missing_environment_and_converges(self):
        for _ in range(2):
            result = self.run_body()
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, self.registry_path + "\\Environment") as key:
                self.assertEqual(winreg.QueryValueEx(key, "NODE_USE_SYSTEM_CA"), ("1", winreg.REG_SZ))
            self.assert_root_preserved()

    def test_reconciles_value_and_type_without_discarding_existing_content(self):
        environment = self.registry_path + "\\Environment"
        with winreg.CreateKey(winreg.HKEY_CURRENT_USER, environment) as key:
            winreg.SetValueEx(key, "unrelated-value", 0, winreg.REG_EXPAND_SZ, "%USERPROFILE%\\keep")
            winreg.SetValueEx(key, "NODE_USE_SYSTEM_CA", 0, winreg.REG_DWORD, 0)
        with winreg.CreateKey(winreg.HKEY_CURRENT_USER, environment + "\\unrelated-child") as key:
            winreg.SetValueEx(key, "sentinel", 0, winreg.REG_SZ, "preserve child")
        for _ in range(2):
            result = self.run_body()
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, environment) as key:
                self.assertEqual(winreg.QueryValueEx(key, "NODE_USE_SYSTEM_CA"), ("1", winreg.REG_SZ))
                self.assertEqual(winreg.QueryValueEx(key, "unrelated-value"),
                                 ("%USERPROFILE%\\keep", winreg.REG_EXPAND_SZ))
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, environment + "\\unrelated-child") as key:
                self.assertEqual(winreg.QueryValueEx(key, "sentinel"), ("preserve child", winreg.REG_SZ))
            self.assert_root_preserved()

    def test_registry_write_error_is_nonzero_and_preserves_existing_value(self):
        environment = self.registry_path + "\\Environment"
        with winreg.CreateKey(winreg.HKEY_CURRENT_USER, environment) as key:
            winreg.SetValueEx(key, "NODE_USE_SYSTEM_CA", 0, winreg.REG_SZ, "old")
            winreg.SetValueEx(key, "unrelated-value", 0, winreg.REG_SZ, "preserve value")
        result = self.run_body(deny_write=True)
        self.assertTrue((self.root / "denial-ready").exists(), result.stdout + result.stderr)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, environment) as key:
            self.assertEqual(winreg.QueryValueEx(key, "NODE_USE_SYSTEM_CA"), ("old", winreg.REG_SZ))
            self.assertEqual(winreg.QueryValueEx(key, "unrelated-value"), ("preserve value", winreg.REG_SZ))
        self.assert_root_preserved()

    def test_onchange_apply_skips_drift_and_runs_for_helper_change(self):
        import json

        source = self.root / "source"
        script_name = ".chezmoiscripts/run_onchange_after_20-native-system-ca.ps1.tmpl"
        helper_name = ".chezmoitemplates/native-ca-windows"
        for name in (script_name, helper_name):
            target = source / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(self.repo / "home" / name, target)
        wrapper = self.root / "isolated-interpreter.ps1"
        registry_root = ("HKEY_CURRENT_USER\\" + self.registry_path).replace("'", "''")
        wrapper.write_text(
            "param([string]$Script)\n$ErrorActionPreference = 'Stop'\n"
            "Remove-PSDrive HKCU -Force\n"
            f"New-PSDrive HKCU Registry '{registry_root}' -Scope Global | Out-Null\n"
            f"if ((Get-PSDrive HKCU).Root -ne '{registry_root}') {{ throw 'HKCU isolation failed' }}\n"
            "& $Script\n", encoding="utf-8-sig",
        )
        self.config.write_text(
            "[interpreters.ps1]\ncommand = " + json.dumps(str(self.shell)) +
            "\nargs = " + json.dumps(["-NoProfile", "-NonInteractive", "-ExecutionPolicy",
                                      "Bypass", "-File", str(wrapper)]) + "\n", encoding="utf-8",
        )
        def apply():
            result = subprocess.run(
                ["chezmoi", "--source", str(source), "--destination", str(self.home),
                 "--config", str(self.config), "--cache", str(self.root / "cache"),
                 "--persistent-state", str(self.root / "state.boltdb"), "--no-tty", "apply"],
                capture_output=True, text=True, encoding="utf-8", timeout=60,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

        environment = self.registry_path + "\\Environment"
        apply()
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, environment, 0, winreg.KEY_SET_VALUE) as key:
            winreg.SetValueEx(key, "NODE_USE_SYSTEM_CA", 0, winreg.REG_SZ, "external drift")
        apply()
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, environment) as key:
            self.assertEqual(winreg.QueryValueEx(key, "NODE_USE_SYSTEM_CA")[0], "external drift")
        with (source / helper_name).open("a", encoding="utf-8") as helper:
            helper.write("\n# consumed helper changed\n")
        apply()
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, environment) as key:
            self.assertEqual(winreg.QueryValueEx(key, "NODE_USE_SYSTEM_CA"), ("1", winreg.REG_SZ))
        self.assert_root_preserved()


if __name__ == "__main__":
    unittest.main()
