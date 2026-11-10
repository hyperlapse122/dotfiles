"""Read-only Ubuntu Studio host inspection, shared by workstation actions.

inspect_host accepts injected OS metadata, session environment and a subprocess.run
compatible runner. The CLI prints the same JSON report and exits 0 for a supported
host, 1 otherwise. Desktop acceptance is reported separately and never changes
host eligibility. VERSION_ID identifies the validated 26.04 release line; install
media point releases are not reliably recorded in that field.
"""

import json
import os
import platform
import subprocess


STUDIO_PACKAGES = ('ubuntustudio-desktop', 'ubuntustudio-desktop-core')


def inspect_host(*, system=None, os_release=None, environ=None, run=subprocess.run):
    """Return supported, blockers, evidence, and separate desktop status/detail."""
    system = platform.system() if system is None else system
    if os_release is None:
        try:
            os_release = platform.freedesktop_os_release() if system == 'Linux' else {}
        except OSError:
            os_release = {}
    environ = os.environ if environ is None else environ

    def output(args):
        try:
            result = run(args, capture_output=True, text=True, timeout=15, check=False)
        except (OSError, subprocess.SubprocessError):
            return ''
        return result.stdout.strip() if result.returncode == 0 else ''

    architecture = output(['dpkg', '--print-architecture']) if system == 'Linux' else ''
    packages = [package for package in STUDIO_PACKAGES
                if system == 'Linux' and output(['dpkg-query', '-W', '-f=${Status}', package]) == 'install ok installed']
    blockers = []
    if system != 'Linux':
        blockers.append('Requires Linux on an Ubuntu Studio workstation.')
    if os_release.get('ID') != 'ubuntu' or os_release.get('VERSION_ID') != '26.04':
        blockers.append('Requires the validated Ubuntu Studio 26.04 LTS release line; install Ubuntu Studio 26.04.1 or a later 26.04 point release manually.')
    if architecture != 'amd64':
        blockers.append('Requires native dpkg architecture amd64.')
    if not packages:
        blockers.append('Requires installed ubuntustudio-desktop or ubuntustudio-desktop-core metapackage evidence; other Linux desktops are unsupported.')
    desktops = environ.get('XDG_CURRENT_DESKTOP', '').upper().split(':')
    session_type = environ.get('XDG_SESSION_TYPE', '').lower()
    kde = 'KDE' in desktops and session_type in ('wayland', 'x11')
    return {
        'supported': not blockers,
        'blockers': blockers,
        'evidence': {'system': system, 'id': os_release.get('ID', ''),
                     'version_id': os_release.get('VERSION_ID', ''),
                     'architecture': architecture, 'studio_packages': packages},
        'desktop': {'status': 'passed' if kde else 'pending',
                    'detail': 'KDE graphical session evidence is present.' if kde else
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
