#!/usr/bin/env bash
# CI guard: verify the chezmoi source tree under home/ renders and applies
# cleanly, so a broken template, an un-renderable source file, or a
# non-idempotent apply cannot ship silently. This replaces the older
# dotbot link-source guard (scripts/ci/check-dotbot-links.mjs) now that the
# repo applies dotfiles with chezmoi instead of dotbot.
#
# Invoked by .github/workflows/tooling.yml; also runnable manually:
#   bash scripts/ci/check-chezmoi-apply.sh
#
# What it checks (equivalent coverage to the old dotbot guard, which asserted
# every link source resolved):
#   1. `chezmoi apply --dry-run` against a TEMP destination exits 0 — every
#      source file and Go template renders without error.
#   2. A real `chezmoi apply` into the same TEMP destination materializes the
#      computed target state, then `chezmoi diff` is empty — the source is
#      internally consistent and applies idempotently.
#
# Safety: the destination is always a throwaway `mktemp -d` dir, NEVER the
# runner's real $HOME, so nothing the user owns is touched. The pinned
# chezmoi version (2.70.5) matches the canonical bootstrap invocation.
#
# Single-platform parity exception: this is a CI-only shell guard with no host
# runtime behavior, so it intentionally has no `.ps1` mate (same pattern as the
# Node-only scripts/ci/check-dotbot-links.mjs it replaces) — it runs on the
# Linux CI runner and anywhere bash + mise are available.
set -euo pipefail

CHEZMOI_VERSION="2.70.5"

if ! command -v mise >/dev/null 2>&1; then
  echo "error: mise not found on PATH; this guard invokes chezmoi via 'mise exec chezmoi@${CHEZMOI_VERSION}'" >&2
  exit 1
fi

REPO="$(git rev-parse --show-toplevel)"
DEST="$(mktemp -d)"
cleanup() { rm -rf "$DEST"; }
trap cleanup EXIT

chezmoi() { mise exec "chezmoi@${CHEZMOI_VERSION}" -- chezmoi "$@"; }

# 1. Dry-run apply: render the whole source tree without writing anything.
#    A template error or unreadable source file fails here with a non-zero exit.
if ! chezmoi apply --dry-run --destination "$DEST" --source "$REPO" --no-tty; then
  echo "error: 'chezmoi apply --dry-run' failed — the source tree does not render cleanly" >&2
  exit 1
fi

# 2. Real apply into the temp destination, then assert the diff is empty.
#    The empty diff proves the source applies idempotently and is consistent.
if ! chezmoi apply --destination "$DEST" --source "$REPO" --no-tty; then
  echo "error: 'chezmoi apply' into the temp destination failed" >&2
  exit 1
fi

DIFF="$(chezmoi diff --source "$REPO" --destination "$DEST" --no-tty)"
if [ -n "$DIFF" ]; then
  echo "error: 'chezmoi diff' is non-empty after apply — source is not idempotent:" >&2
  printf '%s\n' "$DIFF" >&2
  exit 1
fi

echo "chezmoi-apply-ok"
