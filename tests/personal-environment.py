"""Assertions shared by Linux profile and Darwin materialization checks."""
import configparser
import pathlib
import re
import sys


def check(mode, root):
    if mode == 'shell':
        assert 'bash-completion' in (root / '.bashrc').read_text()
        rc = (root / '.config/zsh/.zshrc').read_text()
        assert len(re.findall(r'^source .*zsh-prezto/runcoms/zshrc$', rc, re.M)) == 1
        assert 'zsh-autosuggestions.zsh' not in rc
        assert 'zsh-syntax-highlighting.zsh' not in rc
        assert 'compinit' not in rc
        assert (root / '.zshenv').read_text().count('.config/zsh/.zshenv') == 1
        for name in ['.zprofile', '.zshenv', '.zlogin', '.zlogout', '.zpreztorc']:
            assert (root / '.config/zsh' / name).is_file(), name
        match = re.search(r'(/nix/store/[^\s]+/share/zsh/site-functions)', rc)
        assert match, 'missing completion directory on fpath'
        for command in ['codex', 'gh', 'glab', 'ghq', 'mise', 'usage']:
            assert (pathlib.Path(sys.argv[3] if len(sys.argv) > 3 else match[1]) / ('_' + command)).stat().st_size > 0, command
    elif mode == 'git':
        git = configparser.ConfigParser(strict=False)
        git.read(root / '.config/git/config')
        assert git['user']['signingkey'] == '"621512777E6933FEB4458FDC4945855D4F283F05"'
        assert git['commit']['gpgsign'] == 'true'
        assert git['gpg']['format'] == '"openpgp"'
        assert re.fullmatch(r'"/nix/store/[^/]+/bin/gpg(?:-git)?"', git['gpg']['program'])
        assert git['core']['autocrlf'] == '"input"'
    elif mode == 'terminal':
        text = (root / '.config/ghostty/config').read_text()
        fonts = re.findall(r'^font-family = (.*)$', text, re.M)
        assert fonts[0] == 'Jetendard'
        assert fonts[-1] == 'Twitter Color Emoji'
        assert fonts.count('Twitter Color Emoji') == 1
    elif mode == 'gpg':
        text = (root / '.gnupg/gpg-agent.conf').read_text()
        assert re.search(r'^pinentry-program /nix/store/[^/]+-dotfiles-pinentry-[^/]+/bin/(dotfiles-pinentry|pinentry)$', text, re.M)
        assert re.search(r'^default-cache-ttl 0$', text, re.M)
        assert re.search(r'^max-cache-ttl 0$', text, re.M)
    else:
        raise ValueError(mode)


if __name__ == '__main__':
    check(sys.argv[1], pathlib.Path(sys.argv[2]))
