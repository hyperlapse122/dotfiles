import ctypes
from ctypes import wintypes
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import uuid

if os.name == 'nt':
    import winreg


REPO = Path(__file__).resolve().parents[1]
SHELL = Path(os.environ.get('SystemRoot', 'C:/Windows')) / 'System32/WindowsPowerShell/v1.0/powershell.exe'
VERB = 'Open WezTerm here'


@unittest.skipUnless(os.name == 'nt', 'Windows Explorer integration')
class WindowsWezTermTest(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory(prefix='wezterm ')
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name)
        self.subkey = 'Software\\dotfiles-wezterm-test-' + uuid.uuid4().hex
        self.addCleanup(self.remove_keys, self.subkey)
        self.executable = self.root / 'WezTerm 한글 space' / 'wezterm-gui.exe'
        self.executable.parent.mkdir()
        self.executable.touch()

    def remove_keys(self, path):
        try:
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, path, 0, winreg.KEY_ALL_ACCESS) as key:
                while winreg.QueryInfoKey(key)[0]:
                    self.remove_keys(path + '\\' + winreg.EnumKey(key, 0))
            winreg.DeleteKey(winreg.HKEY_CURRENT_USER, path)
        except FileNotFoundError:
            pass

    def apply(self, executable=None, check=True, discover=False, env=None):
        arguments = [
            str(SHELL), '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
            '-File', str(REPO / 'scripts/windows-wezterm.ps1'),
            '-ClassesRoot', self.subkey,
        ]
        if not discover:
            arguments.extend(['-WezTermPath', str(executable or self.executable)])
        result = subprocess.run(arguments, env=env, capture_output=True, text=True,
                                encoding='utf-8', errors='replace', timeout=30)
        if check:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def read(self, path, name=''):
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, self.subkey + '\\' + path) as key:
            return winreg.QueryValueEx(key, name)[0]

    def test_registers_and_repairs_both_verbs_without_touching_other_settings(self):
        sibling = 'Directory\\shell\\Other terminal'
        with winreg.CreateKey(winreg.HKEY_CURRENT_USER, self.subkey + '\\' + sibling) as key:
            winreg.SetValueEx(key, '', 0, winreg.REG_SZ, 'retain me')
        self.apply()
        verb = 'Directory\\shell\\' + VERB
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, self.subkey + '\\' + verb, 0, winreg.KEY_SET_VALUE) as key:
            winreg.SetValueEx(key, 'Unrelated', 0, winreg.REG_SZ, 'keep')
            winreg.SetValueEx(key, '', 0, winreg.REG_SZ, 'stale label')
        self.apply()
        self.assertEqual(self.read(sibling), 'retain me')
        self.assertEqual(self.read(verb, 'Unrelated'), 'keep')
        self.assertEqual(self.read(verb), 'Open WezTerm Here')
        self.assertEqual(self.read(verb, 'Icon'), '"' + str(self.executable) + '"')
        for location in ('Directory', 'Directory\\Background'):
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, self.subkey + '\\' + location + '\\shell') as key:
                names = [winreg.EnumKey(key, i) for i in range(winreg.QueryInfoKey(key)[0])]
                self.assertEqual(names.count(VERB), 1)

    def test_explorer_command_preserves_directory_arguments(self):
        self.apply()
        parse = ctypes.windll.shell32.CommandLineToArgvW
        parse.argtypes = [wintypes.LPCWSTR, ctypes.POINTER(ctypes.c_int)]
        parse.restype = ctypes.POINTER(wintypes.LPWSTR)
        free = ctypes.windll.kernel32.LocalFree
        free.argtypes = [ctypes.c_void_p]
        free.restype = ctypes.c_void_p
        for location, token in (('Directory', '%1'), ('Directory\\Background', '%V')):
            command = self.read(location + '\\shell\\' + VERB + '\\command')
            for directory in ('C:\\', 'C:\\folder with spaces\\한글', 'C:\\trailing slash\\'):
                count = ctypes.c_int()
                argv = parse(command.replace(token, directory), ctypes.byref(count))
                try:
                    args = [argv[i] for i in range(count.value)]
                finally:
                    free(argv)
                self.assertEqual(args[:4], [str(self.executable), 'start', '--no-auto-connect', '--cwd'])
                self.assertEqual(Path(args[4]), Path(directory))
                self.assertEqual(len(args), 5)

    def test_missing_executable_fails_before_registration(self):
        result = self.apply(self.root / 'missing.exe', check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('WezTerm', result.stdout + result.stderr)
        with self.assertRaises(FileNotFoundError):
            winreg.OpenKey(winreg.HKEY_CURRENT_USER, self.subkey)

    def test_first_apply_discovers_install_without_refreshed_path(self):
        installation = self.root / 'Program Files' / 'WezTerm' / 'wezterm-gui.exe'
        installation.parent.mkdir(parents=True)
        installation.touch()
        env = os.environ.copy()
        env.update(PATH=str(self.root), ProgramW6432=str(installation.parent.parent),
                   ProgramFiles=str(installation.parent.parent), LOCALAPPDATA=str(self.root))
        env['ProgramFiles(x86)'] = str(self.root)
        self.apply(discover=True, env=env)
        self.assertEqual(self.read('Directory\\shell\\' + VERB, 'Icon'), '"' + str(installation) + '"')

    @unittest.skipUnless(shutil.which('chezmoi'), 'chezmoi required')
    def test_configuration_applies_only_to_windows(self):
        source = self.root / 'source'
        source.mkdir()
        for name in ('dot_wezterm.lua', '.chezmoiignore'):
            shutil.copy2(REPO / 'home' / name, source / name)
        home = self.root / 'home'
        home.mkdir()
        config = self.root / 'chezmoi.toml'
        config.write_text('', encoding='utf-8')
        args = ['chezmoi', '--config', str(config), '--source', str(source),
                '--destination', str(home), '--persistent-state', str(self.root / 'state.boltdb')]
        result = subprocess.run([*args, 'apply'], capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((home / '.wezterm.lua').read_bytes(), (source / 'dot_wezterm.lua').read_bytes())
        ignore = (source / '.chezmoiignore').read_text(encoding='utf-8')
        for platform in ('linux', 'darwin'):
            template = '{{ $_ := set .chezmoi "os" "' + platform + '" }}' + ignore
            rendered = subprocess.run([*args, 'execute-template', template], capture_output=True, text=True, timeout=30)
            self.assertEqual(rendered.returncode, 0, rendered.stderr)
            self.assertIn('.wezterm.lua', rendered.stdout.splitlines())


if __name__ == '__main__':
    unittest.main()
