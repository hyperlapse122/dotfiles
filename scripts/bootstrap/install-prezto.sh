#!/usr/bin/env bash

# install-prezto.sh - One-time manual setup: clones Prezto (the zsh framework
# this repo's zsh config is based on) into ${ZDOTDIR}/.zprezto.
#
# Single-platform by design: Prezto is zsh-only and zsh is not a Windows
# shell, so there is no .ps1 counterpart (see scripts/README.md conventions).
# Not idempotent: git clone fails if .zprezto already exists — that is the
# "already installed" signal; remove the directory to reinstall.

set -euo pipefail

git clone --recursive https://github.com/sorin-ionescu/prezto.git "${ZDOTDIR:-${XDG_CONFIG_HOME:-$HOME/.config}/zsh}/.zprezto"
