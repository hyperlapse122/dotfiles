"""Assertions shared by Linux profile and Darwin materialization checks."""
import configparser
import pathlib
import re
import sys


def check(mode, root):
    if mode == 'git':
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
