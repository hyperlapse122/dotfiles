import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[1]


@unittest.skipUnless(os.name != "nt" and shutil.which("zsh") and shutil.which("chezmoi"), "Native zsh and chezmoi required")
class ZshStartupTest(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="zsh fixture ' ")
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        self.home = self.root / "home"
        self.home.mkdir()
        self.source = self.root / "source"
        self.source.mkdir()
        for directory in (".chezmoitemplates", "dot_local/share/dotfiles/zsh"):
            shutil.copytree(REPO / "home" / directory, self.source / directory)
        for name in ("modify_dot_zshenv", ".chezmoiscripts/run_after_40-zsh.sh.tmpl",
                     ".chezmoiscripts/run_onchange_after_10-personal-app-path.sh.tmpl",
                     "dot_config/dotfiles/path.sh"):
            destination = self.source / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(REPO / "home" / name, destination)
        data = self.source / ".chezmoidata"
        data.mkdir()
        shutil.copy2(REPO / "home/.chezmoidata/zsh.json", data / "zsh.json")
        self.stage = self.home / ".local/share/dotfiles/zsh"
        (self.stage / "prezto").mkdir(parents=True)
        (self.stage / "prezto/init.zsh").write_text('export PREZTO_LOADED=yes\nsource "$ZDOTDIR/.zpreztorc"\n', encoding="utf-8")
        self.bin = self.root / "tools"
        self.bin.mkdir()
        self.usage = self.bin / "usage"
        self.usage.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        self.usage.chmod(0o755)
        self.mise = self.bin / "mise"
        self.mise.write_text("#!/bin/sh\ncase \"$*\" in\n *'which usage') printf '%s\\n' \"" + str(self.usage).replace('"', '\\"') + "\";;\n *'activate zsh') printf '%s\\n' 'export MISE_ACTIVATED=yes';;\n *) exit 2;;\nesac\n", encoding="utf-8")
        self.mise.chmod(0o755)
        self.config = self.root / "chezmoi.toml"
        self.config.write_text("", encoding="utf-8")
        self.env = os.environ.copy()
        for name in ("ZDOTDIR", "XDG_CONFIG_HOME", "NODE_USE_SYSTEM_CA", "PREZTO_LOADED", "MISE_ACTIVATED", "BASH_ENV", "ENV"):
            self.env.pop(name, None)
        self.env.update(HOME=str(self.home), USERPROFILE=str(self.home), PATH=str(self.bin) + os.pathsep + self.env["PATH"],
                        XDG_CACHE_HOME=str(self.root / "cache"), XDG_DATA_HOME=str(self.root / "data"),
                        XDG_STATE_HOME=str(self.root / "state"), TERM="xterm-256color")

    def apply(self, check=True):
        result = subprocess.run(["chezmoi", "--source", str(self.source), "--destination", str(self.home),
                                 "--config", str(self.config), "--cache", str(self.root / "chezmoi-cache"),
                                 "--persistent-state", str(self.root / "chezmoi-state"), "--no-tty", "apply", "--force"],
                                env=self.env, capture_output=True, text=True, timeout=60)
        if check:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def shell(self, *flags, env=None):
        script = 'printf "root=%s|ca=%s|prezto=%s|mise=%s|usage=%s\\n" "$ZDOTDIR" "$NODE_USE_SYSTEM_CA" "${PREZTO_LOADED-no}" "${MISE_ACTIVATED-no}" "$(command -v usage)"'
        return subprocess.run(["zsh", "-d", *flags, "-c", script], cwd=self.root, env=env or self.env,
                              capture_output=True, text=True, timeout=30)

    def test_fallback_xdg_and_noninteractive_ca_and_reapply(self):
        self.apply()
        target = self.home / ".config/zsh"
        before = {path.name: path.read_bytes() for path in target.glob(".z*") if path.is_file()}
        # Reapplication from a configured shell finds the already-published mise link.
        self.env["PATH"] = str(self.stage / "bin") + os.pathsep + self.env["PATH"]
        self.apply()
        self.assertEqual(before, {path.name: path.read_bytes() for path in target.glob(".z*") if path.is_file()})
        published_mise = subprocess.run([str(self.stage / "bin/mise"), "activate", "zsh"],
                                        capture_output=True, text=True, timeout=10)
        self.assertEqual(published_mise.returncode, 0, published_mise.stderr)
        for flags in (("-i",), ("-l", "-i")):
            result = self.shell(*flags)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(f"root={target}|ca=1|prezto=yes|mise=yes|usage={self.stage}/bin/usage", result.stdout)
        result = self.shell()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("|ca=1|prezto=no|mise=no|", result.stdout)
        nested = self.env | {"ZDOTDIR": str(target)}
        self.assertIn("|ca=1|", self.shell(env=nested).stdout)

    def test_custom_xdg_and_legacy_bridge_preserve_unmanaged_contents(self):
        self.env["XDG_CONFIG_HOME"] = str(self.root / "outside config ' directory")
        legacy = self.root / "old zsh ' directory"
        legacy.mkdir()
        self.env["ZDOTDIR"] = str(legacy)
        (legacy / ".zshenv").write_text("export LEGACY_CUSTOM=yes\n", encoding="utf-8")
        (self.home / ".zshenv").write_text("export HOME_CUSTOM=yes\n", encoding="utf-8")
        target = Path(self.env["XDG_CONFIG_HOME"]) / "zsh"
        target.mkdir(parents=True)
        (target / ".zshrc").write_text("export XDG_CUSTOM=yes\n", encoding="utf-8")
        self.apply()
        self.apply()
        self.assertIn("LEGACY_CUSTOM=yes", (legacy / ".zshenv").read_text())
        self.assertIn("HOME_CUSTOM=yes", (self.home / ".zshenv").read_text())
        self.assertIn("XDG_CUSTOM=yes", (target / ".zshrc").read_text())
        result = self.shell("-i")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"root={target}|ca=1|prezto=yes|mise=yes|usage={self.stage}/bin/usage", result.stdout)

    def test_reserved_directory_is_not_deleted(self):
        target = self.home / ".config/zsh/.zprezto"
        target.mkdir(parents=True)
        (target / "keep").write_text("unmanaged")
        result = self.apply(check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(".zprezto", result.stderr)
        self.assertEqual((target / "keep").read_text(), "unmanaged")

    def test_gpg_ssh_configuration_or_cached_exports_exclude_agent_module(self):
        agent = self.bin / "gpg-agent"
        agent.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        agent.chmod(0o755)
        self.env["SSH_AUTH_SOCK"] = "/existing/ssh-agent"
        self.apply()
        command = 'zstyle -L :prezto:load; print -r -- "agent=$SSH_AUTH_SOCK"'
        def modules():
            result = subprocess.run(["zsh", "-d", "-i", "-c", command], env=self.env,
                                    cwd=self.root, capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr)
            return result.stdout
        self.assertIn(" gpg ", modules())
        gnupg = self.home / ".gnupg"
        gnupg.mkdir()
        config = gnupg / "gpg-agent.conf"
        config.write_text("enable-ssh-support\n", encoding="utf-8")
        self.assertNotIn(" gpg ", modules())
        self.assertIn("agent=/existing/ssh-agent", modules())
        config.unlink()
        cache = Path(self.env["XDG_CACHE_HOME"]) / "prezto"
        cache.mkdir(parents=True)
        (cache / "gpg-agent.env").write_text("SSH_AUTH_SOCK=/other/agent; export SSH_AUTH_SOCK\n", encoding="utf-8")
        self.assertNotIn(" gpg ", modules())
        self.assertIn("agent=/existing/ssh-agent", modules())

    def test_inherited_alias_of_xdg_root_does_not_recurse(self):
        target = self.home / ".config/zsh"
        target.mkdir(parents=True)
        legacy = self.root / "alias"
        legacy.symlink_to(target, target_is_directory=True)
        self.env["ZDOTDIR"] = str(legacy)
        self.apply()
        result = self.shell("-i")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("|ca=1|prezto=yes|mise=yes|", result.stdout)
