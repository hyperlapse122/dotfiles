import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


BEGIN = b"# >>> dotfiles native system CA >>>"
END = b"# <<< dotfiles native system CA <<<"
STARTUP_FILES = (".profile", ".bashrc", ".bash_profile", ".bash_login", ".zshenv")


def find_bash():
    if os.name != "nt":
        return shutil.which("bash")
    # Do not accidentally invoke the Windows WSL launcher against a real home.
    git = shutil.which("git")
    candidates = []
    if git:
        installation = Path(git).resolve().parent.parent
        candidates.extend((installation / "bin/bash.exe", installation / "usr/bin/bash.exe"))
    for variable in ("ProgramFiles", "ProgramFiles(x86)", "LOCALAPPDATA"):
        if os.environ.get(variable):
            base = Path(os.environ[variable])
            candidates.extend((base / "Git/bin/bash.exe", base / "Programs/Git/bin/bash.exe"))
    return next((str(path) for path in candidates if path.is_file()), None)


@unittest.skipUnless(shutil.which("chezmoi"), "Real chezmoi executable required")
class NativeCaShellTest(unittest.TestCase):
    def setUp(self):
        self.repo = Path(__file__).resolve().parents[1]
        scratch = tempfile.TemporaryDirectory(prefix="native ca shell ")
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name)
        self.home = self.root / "user home"
        self.home.mkdir()
        self.outside = self.root / "unrelated directory"
        self.outside.mkdir()
        self.source = self.root / "source"
        self.source.mkdir()
        (self.source / ".chezmoitemplates").mkdir()
        shutil.copy2(self.repo / "home/.chezmoitemplates/native-ca-shell",
                     self.source / ".chezmoitemplates/native-ca-shell")
        for name in ("zsh-settings", "zsh-redirect"):
            shutil.copy2(self.repo / "home/.chezmoitemplates" / name,
                         self.source / ".chezmoitemplates" / name)
        shutil.copy2(self.repo / "home/.chezmoitemplates/cli-completions-shell",
                     self.source / ".chezmoitemplates/cli-completions-shell")
        for name in STARTUP_FILES:
            source_name = "modify_dot_" + name[1:]
            shutil.copy2(self.repo / "home" / source_name, self.source / source_name)
        environment = Path("dot_config/environment.d/60-native-system-ca.conf.tmpl")
        (self.source / environment).parent.mkdir(parents=True)
        shutil.copy2(self.repo / "home" / environment, self.source / environment)
        self.config = self.root / "chezmoi.toml"
        self.config.write_text("", encoding="utf-8")
        self.env = os.environ.copy()
        for key in list(self.env):
            if key.upper() in ("NODE_USE_SYSTEM_CA", "CUSTOM_STARTUP", "BASH_ENV", "ENV", "ZDOTDIR"):
                del self.env[key]
        self.env.update({
            "HOME": str(self.home), "USERPROFILE": str(self.home),
            "APPDATA": str(self.root / "appdata"),
            "LOCALAPPDATA": str(self.root / "local"),
            "XDG_CONFIG_HOME": str(self.home / ".config"),
            "XDG_CONFIG_DIRS": str(self.root / "system config"),
            "XDG_CACHE_HOME": str(self.root / "cache"),
            "XDG_DATA_HOME": str(self.root / "data"),
            "XDG_STATE_HOME": str(self.root / "state"),
            "GIT_CONFIG_GLOBAL": str(self.home / ".gitconfig"),
            "GIT_CONFIG_NOSYSTEM": "1",
        })

    def run_command(self, *args, check=True, env=None):
        result = subprocess.run(args, cwd=self.outside, env=self.env if env is None else env,
                                capture_output=True, text=True, encoding="utf-8",
                                errors="backslashreplace", timeout=60)
        if check:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def chezmoi(self, *args, check=True):
        return self.run_command(
            "chezmoi", "--source", str(self.source), "--destination", str(self.home),
            "--config", str(self.config), "--cache", str(self.root / "chezmoi cache"),
            "--persistent-state", str(self.root / "state.boltdb"), "--no-tty",
            *args, check=check,
        )

    def apply(self, *names, check=True):
        return self.chezmoi("apply", "--force", "--exclude=scripts",
                            *(str(self.home / name) for name in names), check=check)

    def use_platform_selection(self):
        shutil.copy2(self.repo / "home/.chezmoiignore", self.source / ".chezmoiignore")

    def bash_startup(self, name, *, interactive=True, expected_custom="preserved"):
        bash = find_bash()
        if not bash:
            self.skipTest("Real Bash unavailable (Git for Windows Bash is supported)")
        # --rcfile reads the actual startup file without host /etc/profile or
        # personal rc files. Login-file selection is checked independently below.
        startup = self.home / name
        probe = 'printf "native-ca=%s|custom=%s\\n" "${NODE_USE_SYSTEM_CA-unset}" "${CUSTOM_STARTUP-unset}"'
        probe += '; "$BASH" --noprofile --norc -c \'printf "native-ca-child=%s\\\\n" "${NODE_USE_SYSTEM_CA-unset}"\''
        if interactive:
            result = self.run_command(bash, "--noprofile", "--rcfile", startup.as_posix(), "-ic", probe)
        else:
            # Source a file with an early noninteractive return, as Bash does
            # when a login profile sources .bashrc for a noninteractive command.
            result = self.run_command(bash, "--noprofile", "--norc", "-c",
                                      '. "$1"; ' + probe, "native-ca-test", startup.as_posix())
        self.assertIn("native-ca=1|custom=" + expected_custom, result.stdout)
        self.assertIn("native-ca-child=1", result.stdout)
        return result

    def test_missing_startup_file_is_created_and_exports_to_child_shells(self):
        for _ in range(2):
            self.apply(".bashrc")
            self.bash_startup(".bashrc", expected_custom="unset")

    def test_unowned_unicode_and_line_endings_survive_repeated_apply(self):
        custom = b"# custom startup \xe2\x98\x83\r\nexport CUSTOM_STARTUP=preserved\r\n# no trailing newline"
        startup = self.home / ".bashrc"
        startup.write_bytes(custom)
        self.apply(".bashrc")
        expected = startup.read_bytes()
        self.assertTrue(expected.endswith(custom), expected)
        self.apply(".bashrc")
        self.assertEqual(startup.read_bytes(), expected)

    def test_bash_startup_preserves_side_effects_after_repeated_apply(self):
        custom = b"export CUSTOM_STARTUP=preserved\nprintf 'custom side effect\\n'\n"
        (self.home / ".bashrc").write_bytes(custom)
        for _ in range(2):
            self.apply(".bashrc")
            result = self.bash_startup(".bashrc")
            self.assertEqual(result.stdout.count("custom side effect\n"), 1)
        self.assertTrue((self.home / ".bashrc").read_bytes().endswith(custom))

    def test_export_precedes_noninteractive_return(self):
        (self.home / ".bashrc").write_bytes(
            b"export CUSTOM_STARTUP=preserved\ncase $- in *i*) ;; *) return ;; esac\n"
            b"export CUSTOM_STARTUP=should-not-run\n")
        self.apply(".bashrc")
        self.bash_startup(".bashrc", interactive=False)

    def test_replaces_owned_block_without_changing_surrounding_bytes(self):
        prefix = b"# custom prefix\r\n"
        suffix = b"export CUSTOM_STARTUP=preserved\n# custom suffix"
        drift = BEGIN + b"\r\nexport NODE_USE_SYSTEM_CA=0\r\n" + END + b"\r\n"
        (self.home / ".profile").write_bytes(prefix + drift + suffix)
        self.apply(".profile")
        first = (self.home / ".profile").read_bytes()
        self.assertTrue(first.endswith(prefix + suffix), first)
        self.apply(".profile")
        self.assertEqual((self.home / ".profile").read_bytes(), first)
        self.bash_startup(".profile")

    def test_malformed_delimiters_fail_without_changing_original_file(self):
        valid = BEGIN + b"\nexport NODE_USE_SYSTEM_CA=0\n" + END + b"\n"
        malformed = (
            BEGIN + b"\nexport CUSTOM_STARTUP=preserved\n",
            END + b"\nexport CUSTOM_STARTUP=preserved\n",
            END + b"\n" + BEGIN + b"\n",
            valid + valid,
            BEGIN + b"\n" + BEGIN + b"\n" + END + b"\n",
            BEGIN + b" trailing text\nexport CUSTOM_STARTUP=preserved\n" + END + b"\n",
            BEGIN[:-1] + b"\nexport CUSTOM_STARTUP=preserved\n" + END + b"\n",
            BEGIN + b"\nexport CUSTOM_STARTUP=preserved\n" + END + b" trailing text\n",
        )
        for content in malformed:
            with self.subTest(content=content):
                original = b"# keep before\r\n" + content + b"# keep after without newline"
                (self.home / ".profile").write_bytes(original)
                result = self.apply(".profile", check=False)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual((self.home / ".profile").read_bytes(), original)

    @unittest.skipIf(os.name == "nt", "Unix source selection requires a native Unix host")
    def test_profile_is_not_shadowed_by_created_bash_login_files(self):
        self.use_platform_selection()
        custom = b"export CUSTOM_STARTUP=preserved\n"
        (self.home / ".profile").write_bytes(custom)
        for _ in range(2):
            self.apply()
            self.assertFalse((self.home / ".bash_profile").exists())
            self.assertFalse((self.home / ".bash_login").exists())
            self.bash_startup(".profile")
        self.assertTrue((self.home / ".profile").read_bytes().endswith(custom))

    @unittest.skipIf(os.name == "nt", "Unix source selection requires a native Unix host")
    def test_existing_bash_login_precedence_and_content_are_preserved(self):
        self.use_platform_selection()
        for selected in (".bash_login", ".bash_profile"):
            with self.subTest(selected=selected):
                custom = b"export CUSTOM_STARTUP=preserved\n"
                (self.home / selected).write_bytes(custom)
                for _ in range(2):
                    self.apply()
                    self.assertTrue((self.home / selected).read_bytes().endswith(custom))
                    self.bash_startup(selected)
                if selected == ".bash_login":
                    self.assertFalse((self.home / ".bash_profile").exists())

    @unittest.skipUnless(shutil.which("zsh"), "Real zsh unavailable")
    def test_zshenv_applies_to_noninteractive_shells(self):
        custom = b"export CUSTOM_STARTUP=preserved\n"
        (self.home / ".zshenv").write_bytes(custom)
        for _ in range(2):
            self.apply(".zshenv")
            result = self.run_command(
                shutil.which("zsh"), "-d", "-c",
                'printf "native-ca=%s|custom=%s\\n" "${NODE_USE_SYSTEM_CA-unset}" "${CUSTOM_STARTUP-unset}"',
            )
            self.assertIn("native-ca=1|custom=preserved", result.stdout)
        self.assertTrue((self.home / ".zshenv").read_bytes().endswith(custom))


if __name__ == "__main__":
    unittest.main()
