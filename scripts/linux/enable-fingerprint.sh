#!/usr/bin/env bash

# enable-fingerprint.sh - One-time manual setup: installs fprintd and enables
# fingerprint auth in the PAM stack via authselect (Fedora).
#
# Single-platform by design: fprintd/authselect are Fedora/Linux components,
# so there is no .ps1 counterpart (see scripts/README.md conventions).
# Manual because it needs sudo and you must still enroll a finger afterwards
# (e.g. via GNOME/KDE settings or `fprintd-enroll`).

set -euo pipefail

sudo dnf install fprintd fprintd-pam
sudo authselect enable-feature with-fingerprint
sudo authselect apply-changes
