"""Read-only Fedora KDE Plasma Desktop host inspection, shared by workstation actions.

inspect_host accepts injected OS metadata, session environment, a subprocess.run
compatible runner and an ostree-boot marker. The CLI prints the same JSON report
and exits 0 for a supported host, 1 otherwise. Desktop acceptance is reported
separately and never changes host eligibility.

VALIDATED_RELEASE is the Fedora release the repository last validated. Older
releases are unsupported. Newer releases are supported and reported as
unvalidated until this value is raised.
"""

import json
import os
from pathlib import Path
import platform
import subprocess


VALIDATED_RELEASE = 45


def inspect_host(*, system=None, os_release=None, environ=None, run=subprocess.run, ostree_booted=None):
    """Return supported, blockers, evidence, release status, and separate desktop status/detail."""
    system = platform.system() if system is None else system
    if os_release is None:
        try:
            os_release = platform.freedesktop_os_release() if system == 'Linux' else {}
        except OSError:
            os_release = {}
    environ = os.environ if environ is None else environ
    if ostree_booted is None:
        ostree_booted = system == 'Linux' and Path('/run/ostree-booted').exists()

    architecture = ''
    if system == 'Linux':
        try:
            result = run(['rpm', '--eval', '%{_arch}'], capture_output=True, text=True, timeout=15, check=False)
            architecture = result.stdout.strip() if result.returncode == 0 else ''
        except (OSError, subprocess.SubprocessError):
            architecture = ''

    version = os_release.get('VERSION_ID', '')
    host_release = int(version) if version.isdigit() else None
    variant = os_release.get('VARIANT_ID', '')
    fedora = os_release.get('ID') == 'fedora'
    blockers = []
    if system != 'Linux':
        blockers.append('Requires Linux on a Fedora KDE Plasma Desktop workstation.')
    if not fedora:
        blockers.append('Requires Fedora; other distributions are unsupported.')
    if variant == 'kinoite' or ostree_booted:
        blockers.append('Fedora atomic desktops, including Kinoite, are unsupported; install the dnf-based '
                        'KDE Plasma Desktop edition.')
    elif variant != 'kde':
        blockers.append('Requires the Fedora KDE Plasma Desktop edition (VARIANT_ID=kde); other editions and '
                        'spins are unsupported.')
    if architecture != 'x86_64':
        blockers.append('Requires native RPM architecture x86_64.')
    if host_release is None:
        release_status = 'unsupported'
        if fedora:
            blockers.append('Cannot read a numeric Fedora release from VERSION_ID.')
    elif host_release < VALIDATED_RELEASE:
        release_status = 'unsupported'
        if fedora:
            blockers.append(f'Requires Fedora {VALIDATED_RELEASE} or later; upgrade the OS manually.')
    else:
        release_status = 'validated' if host_release == VALIDATED_RELEASE else 'unvalidated'
    desktops = environ.get('XDG_CURRENT_DESKTOP', '').upper().split(':')
    session_type = environ.get('XDG_SESSION_TYPE', '').lower()
    kde = 'KDE' in desktops and session_type in ('wayland', 'x11')
    return {
        'supported': not blockers,
        'blockers': blockers,
        'evidence': {'system': system, 'id': os_release.get('ID', ''), 'version_id': version,
                     'variant_id': variant, 'architecture': architecture, 'ostree_booted': bool(ostree_booted)},
        'release': {'host': host_release, 'validated': VALIDATED_RELEASE, 'status': release_status},
        'desktop': {'status': 'passed' if kde else 'pending',
                    'detail': 'KDE Plasma graphical session evidence is present.' if kde else
                    'Log into the native KDE Plasma desktop and repeat desktop acceptance checks.',
                    'current_desktop': environ.get('XDG_CURRENT_DESKTOP', ''),
                    'session_type': session_type},
    }


def main():
    report = inspect_host()
    print(json.dumps(report, indent=2))
    return 0 if report['supported'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
