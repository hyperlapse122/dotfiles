#!/usr/bin/env bash

set -euo pipefail

sudo dnf install fprintd fprintd-pam
sudo authselect enable-feature with-fingerprint
sudo authselect apply-changes
