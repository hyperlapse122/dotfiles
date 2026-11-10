"""Inspect Fedora KDE Plasma Desktop prerequisites without changing personal or runtime state.

Exit 0 requires every check to pass, 1 reports blocking prerequisites, and 2
reports pending native proof. Inspection alone cannot certify daily work.
See docs/setup/fedora.md for separate acceptance procedures.
"""

import argparse
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess


spec = importlib.util.spec_from_file_location('linux_platform', Path(__file__).with_name('linux-platform.py'))
host = importlib.util.module_from_spec(spec)
spec.loader.exec_module(host)

COMMANDS = (
    'git', 'mise', 'chezmoi', 'gpg', 'gpgconf', 'pinentry-qt', 'ssh',
    'aria2c', 'curl', 'zsh', 'ghostty', 'fc-match', 'secret-tool',
    'bun', 'node', 'claude', 'codex', 'agy', 'pi', 'grok', 'gh', 'glab', 'ghq', 'op', 't3',
    'docker-credential-secretservice', 'cc', 'c++', 'pkg-config', 'python', 'pwsh',
    'dotnet', 'rustc', 'cargo', 'rustup', 'cmake', 'ninja', 'vcpkg',
    'podman', 'docker', 'newuidmap', 'newgidmap', 'slirp4netns', 'fuse-overlayfs',
    'systemd-run', 'systemctl', 'minikube', 'kubectl', 'kreadconfig6', 'kwriteconfig6',
)
PACKAGES = ('google-chrome-stable', '1password', '1password-cli', 'chatgpt', 'podman', 'podman-docker', 'ghostty')
MANAGED_FILES = {
    'Git configuration': '.gitconfig',
    'GPG agent configuration': '.gnupg/gpg-agent.conf',
    'Shell PATH fragment': '.config/dotfiles/path.sh',
    'zsh environment': '.zshenv',
    'zsh interactive configuration': '.zshrc',
    'Prezto': '.local/share/dotfiles/zsh/prezto/init.zsh',
    'Ghostty configuration': '.config/ghostty/config.ghostty',
    'Claude instructions': '.claude/CLAUDE.md',
    'Codex instructions': '.codex/AGENTS.md',
    'Antigravity instructions': '.gemini/GEMINI.md',
    'pi instructions': '.pi/agent/AGENTS.md',
    'Grok instructions': '.grok/AGENTS.md',
    'T3 server preferences': '.t3/userdata/settings.json',
    'T3 client preferences': '.t3/userdata/client-settings.json',
}
MISSING_TOOL = 'Missing; complete explicit application/build provisioning and open a fresh shell.'
DESKTOP_DETAIL = 'Session metadata only; complete the separate native KDE Plasma acceptance checklist.'
NATIVE_CHECKS = {
    'Hardware and install media': 'Verify the signed Fedora KDE Plasma Desktop amd64 media, drivers, Secure Boot, peripherals, reboot and native Plasma session.',
    'Terminal, shell and fonts': 'Verify zsh login, Prezto/completions, Jetendard rendering, Ghostty as the Plasma default terminal, the Dolphin terminal action and Terminal=true launchers.',
    'Native harness discovery': 'Verify Claude, Codex, Antigravity, pi and Grok instructions, pinned native CE and each shared skill exactly once.',
    'Authenticated harness and T3 work': 'Invoke CE through each harness; open a project and complete work through each configured T3 provider.',
    'Secret Service and credentials': 'Verify the existing provider/default collection, harmless roundtrip and deletion, GPG signing, SSH, GitHub/GitLab and enrolled registries without logging values.',
    '1Password integration': 'Unlock the GUI and verify CLI, browser and selected SSH-agent integration through native owner approval.',
    'Desktop applications and vendor limitations': 'Launch Chrome, 1Password, ChatGPT and T3; Claude Desktop is unavailable on Fedora and tracked as follow-up work; account for every capability in the migration inventory, including unavailable Linux computer use and Claude dictation.',
    'Native builds and execution': 'Run tests/smoke_linux_build_environment.py from a fresh external-directory shell; require native C++, Rust, .NET 8/10 and vcpkg execution.',
    'Minikube workload and cleanup': 'Run tests/smoke_linux_minikube.py separately on rootless Podman; require image build/run, workload host access, cluster deletion and zero owned disposable resources including volumes, or record the unresolved limitation.',
    'Optional organization CA': 'If required, install approved trust manually and verify TLS plus NODE_USE_SYSTEM_CA in a fresh desktop session; otherwise record not applicable.',
    'Reapply and checkout isolation': 'Verify repeat application preserves unrelated state; a new worktree must prepare without applying personal settings or starting services.',
    'Dock reference workflows': 'Accept browser/Linux mappings or record unresolved limitations for Apple services and organization-provisioned Microsoft 365; no enrollment is automated.',
}


def collect(home):
    checks = []

    def record(name, status, detail):
        checks.append({'name': name, 'status': status, 'detail': detail})

    report = host.inspect_host(run=subprocess.run)
    record('Supported host', 'passed' if report['supported'] else 'failed',
           'Requires native Fedora KDE Plasma Desktop on amd64, installed through dnf at the validated release or later; Ubuntu, atomic desktops, other editions and architectures are unsupported.')
    if not report['supported']:
        return {'ready': False, 'checks': checks}
    release = report['release']
    if release['status'] == 'validated':
        record('Fedora release', 'passed', f"Fedora {release['host']} is the validated release.")
    else:
        record('Fedora release', 'pending',
               f"Fedora {release['host']} is newer than the validated release {release['validated']}; "
               'validate it natively, then raise the validated release.')
    record('KDE session', report['desktop']['status'], DESKTOP_DETAIL)
    for command in COMMANDS:
        available = shutil.which(command)
        record('Command: ' + command, 'passed' if available else 'failed',
               'Found on PATH; presence does not prove native operation.' if available else MISSING_TOOL)
    for package in PACKAGES:
        try:
            result = subprocess.run(['rpm', '-q', package],
                                    capture_output=True, text=True, timeout=15, check=False)
            installed = result.returncode == 0
        except (OSError, subprocess.SubprocessError):
            installed = False
        record('Package: ' + package, 'passed' if installed else 'failed',
               'Package inventory only; launch and authentication remain separate.' if installed else 'Required package missing; run explicit application on the supported host.')
    for name, relative in MANAGED_FILES.items():
        record(name, 'passed' if (home / relative).is_file() else 'failed',
               'File presence only; native discovery remains separate.')
    for name, detail in NATIVE_CHECKS.items():
        record(name, 'pending', detail)
    return {'ready': all(check['status'] == 'passed' for check in checks), 'checks': checks}


def exit_code(result):
    statuses = [check['status'] for check in result['checks']]
    if 'failed' in statuses:
        return 1
    return 0 if statuses and all(status == 'passed' for status in statuses) else 2


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--json', action='store_true', help='Print the inspection as JSON')
    args = parser.parse_args()
    result = collect(Path.home())
    if args.json:
        print(json.dumps(result, indent=2))
    else:
        for check in result['checks']:
            print(f"{check['status'].upper():7} {check['name']}: {check['detail']}")
        print('Native evidence remains separate; follow docs/setup/fedora.md.')
    return exit_code(result)


if __name__ == '__main__':
    raise SystemExit(main())
