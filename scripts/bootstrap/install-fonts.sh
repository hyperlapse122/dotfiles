#!/usr/bin/env bash
# scripts/bootstrap/install-fonts.sh
#
# Installs desktop fonts user-wide (no sudo) on macOS and Linux by downloading
# release archives from GitHub. Add new fonts by appending entries to the FONTS
# array near the top of this file.
#
# Defaults: skips a font when its marker file already exists in the user font
# directory. Pass --force to reinstall everything.
#
# Windows counterpart: install-fonts.ps1 (see scripts/README.md). Together they
# satisfy the script-parity rule in ../AGENTS.md.

set -euo pipefail

# ---------------------------------------------------------------------------
# Font registry. To add a font, append one pipe-delimited record:
#
#   name|repo|asset_pattern|marker_glob|src_dirs
#
# - name           Human-readable label used in log lines.
# - repo           GitHub <owner>/<repo>. Latest release is queried.
# - asset_pattern  Glob handed to `gh release download --pattern`. Must match
#                  exactly one asset in the latest release.
# - marker_glob    Filename or glob pattern (e.g. `Foo-Ver*.ttf`) that matches
#                  at least one file installed by this entry. If any file in
#                  the user font directory matches the glob, the entry is
#                  treated as already installed (re-run with --force to
#                  override). Pick a marker distinct from other registry
#                  entries' markers to avoid false positives.
# - src_dirs       Comma-separated list of directories *inside the unzipped
#                  archive* whose .ttf, .otf, and .ttc files should be
#                  installed. Use "." for the archive root. Other files are
#                  ignored.
# ---------------------------------------------------------------------------
FONTS=(
  "Pretendard|orioncactus/pretendard|Pretendard-*.zip|PretendardVariable.ttf|public/variable,public/static,public/static/alternative"
  "PretendardJP|orioncactus/pretendard|PretendardJP-*.zip|PretendardJPVariable.ttf|public/variable,public/static,public/static/alternative"
  "D2Coding|naver/d2codingfont|D2Coding-*.zip|D2Coding-Ver*.ttf|D2Coding,D2CodingAll,D2CodingLigature"
  "JetBrainsMono|JetBrains/JetBrainsMono|JetBrainsMono-*.zip|JetBrainsMono-Regular.ttf|fonts/variable,fonts/ttf"
  "D2CodingNerd|ryanoasis/nerd-fonts|D2Coding.zip|D2CodingLigatureNerdFont-Regular.ttf|."
  "JetBrainsMonoNerd|ryanoasis/nerd-fonts|JetBrainsMono.zip|JetBrainsMonoNerdFont-Regular.ttf|."
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

usage() {
  cat <<'EOF'
Usage: install-fonts.sh [--force] [--help]

  -f, --force   Reinstall fonts even when the marker file is already present.
  -h, --help    Show this message and exit.

Add new fonts by editing the FONTS array near the top of this script.
EOF
}

log() { printf 'install-fonts.sh: %s\n' "$*"; }
err() { printf 'install-fonts.sh: %s\n' "$*" >&2; }

# Resolve user font directory per OS (XDG-compliant on Linux, ~/Library/Fonts
# on macOS). Both paths are picked up automatically by the OS font subsystem.
detect_os() {
  case "$(uname -s)" in
    Darwin) USER_FONT_DIR="$HOME/Library/Fonts" ;;
    Linux)  USER_FONT_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/fonts" ;;
    *)
      err "unsupported OS: $(uname -s); use install-fonts.ps1 on Windows."
      exit 1
      ;;
  esac
}

# Pick a `gh` invocation, mirroring auth-gh.sh: prefer system gh, fall back to
# mise-managed `gh@latest`, error otherwise.
detect_gh() {
  if command -v gh >/dev/null 2>&1; then
    GH=(gh)
  elif command -v mise >/dev/null 2>&1; then
    GH=(mise exec gh@latest -- gh)
  else
    err "gh not found and mise unavailable as fallback."
    err "install GitHub CLI (https://cli.github.com/) or mise (https://mise.jdx.dev/)."
    exit 1
  fi
}

require_cmd() {
  for cmd in "$@"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      err "required command not found: $cmd"
      exit 1
    fi
  done
}

# Install all .ttf, .otf, and .ttc files from listed src_dirs into
# USER_FONT_DIR. Skipped when a file matching marker_glob already exists.
install_font() {
  local name="$1" repo="$2" pattern="$3" marker="$4" src_dirs="$5"

  # `find -iname` accepts shell-style globs (and is case-insensitive), so the
  # same code path handles exact-match markers and patterns like `Foo-Ver*.ttf`.
  local marker_match
  marker_match="$(find "$USER_FONT_DIR" -maxdepth 1 -type f -iname "$marker" -print -quit 2>/dev/null || true)"
  if [[ -n "$marker_match" && "$FORCE" -eq 0 ]]; then
    log "$name: already installed (matched: $(basename "$marker_match")) — use --force to reinstall"
    return 0
  fi

  log "$name: downloading from github.com/$repo (pattern: $pattern)"

  local work="$TMP_ROOT/$name"
  mkdir -p "$work"

  "${GH[@]}" release download \
    --repo "$repo" \
    --pattern "$pattern" \
    --dir "$work" \
    --clobber

  local zip
  zip="$(find "$work" -maxdepth 1 -name '*.zip' -print -quit)"
  if [[ -z "$zip" ]]; then
    err "$name: no archive downloaded for pattern $pattern"
    return 1
  fi

  log "$name: extracting $(basename "$zip")"
  local extracted="$work/extracted"
  mkdir -p "$extracted"
  unzip -q -o "$zip" -d "$extracted"

  mkdir -p "$USER_FONT_DIR"

  local count=0
  IFS=',' read -ra dirs <<<"$src_dirs"
  for dir in "${dirs[@]}"; do
    local src="$extracted/$dir"
    [[ -d "$src" ]] || continue

    while IFS= read -r -d '' file; do
      install -m 644 "$file" "$USER_FONT_DIR/"
      count=$((count + 1))
    done < <(find "$src" -maxdepth 1 -type f \( -iname '*.ttf' -o -iname '*.otf' -o -iname '*.ttc' \) -print0)
  done

  if [[ $count -eq 0 ]]; then
    err "$name: no .ttf/.otf/.ttc files found under: $src_dirs"
    return 1
  fi

  log "$name: installed $count font file(s) to $USER_FONT_DIR"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

FORCE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -f|--force) FORCE=1 ;;
    -h|--help)  usage; exit 0 ;;
    *)          err "unknown argument: $1"; usage >&2; exit 2 ;;
  esac
  shift
done

detect_os
detect_gh
require_cmd unzip find install mktemp

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

mkdir -p "$USER_FONT_DIR"

for entry in "${FONTS[@]}"; do
  IFS='|' read -r name repo pattern marker src_dirs <<<"$entry"
  install_font "$name" "$repo" "$pattern" "$marker" "$src_dirs"
done

# Refresh fontconfig cache on Linux so just-installed fonts become visible
# without re-login. macOS picks them up automatically; CoreText scans on demand.
if [[ "$(uname -s)" == "Linux" ]] && command -v fc-cache >/dev/null 2>&1; then
  log "refreshing font cache (fc-cache -f)"
  fc-cache -f "$USER_FONT_DIR" >/dev/null
fi

log "done"
