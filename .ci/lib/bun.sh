# shellcheck shell=bash
# .ci/lib/bun.sh — bun resolution ladder for .ci scripts, sourced (never
# executed directly).
#
# This mirrors .chezmoitemplates/bun-resolve.sh.tmpl rung-for-rung: a CI script
# runs outside chezmoi's templating, so it cannot include that partial, but the
# two must stay the same ladder in the same order. If you change one, change
# the other.
#
# THE LADDER, in order:
#
#   1  bun already on PATH
#   2  $HOME/.local/bin/bun                                    public link
#   3  $HOME/.local/lib/commands/current/bun/bun               current generation
#   4  $HOME/.local/share/chezmoi-commands/incomplete/bun/bun  staging
#
# CONTRACT. resolve_bun sets BUN_BIN to the resolved absolute path and BUN_DIR
# to that binary's directory, then PREPENDS BUN_DIR to PATH. When no rung
# matches it leaves BUN_BIN and BUN_DIR empty and leaves PATH untouched — the
# caller decides whether an absent bun is fatal, a skip, or a fallback. This
# function never exits, prints, or fails on its own.
#
# EVERY CANDIDATE MUST BE ABSOLUTE. Rung 1 is the only candidate the ladder does
# not spell out itself, so it is the only one that can arrive relative: a PATH
# element that is empty or `.` makes `command -v bun` answer `./bun`, and
# prepending that directory would put the working directory on PATH for every
# command the caller runs afterwards. A non-absolute hit is rejected and the
# next rung answers.
#
# WHY IT PREPENDS PATH INSTEAD OF ONLY SETTING BUN_BIN. Some callers spawn bun
# as a subprocess (for example a workflow audit script invoking `bun
# "$audit"`), and that subprocess resolves `bun` from PATH, not from a variable
# this function sets. See KTD3 in docs/plans/.
#
# The PATH guard is the repo's `case ":$PATH:"` idiom, so a directory already
# on PATH (rung 1, in particular) is not appended a second time.

resolve_bun() {
  BUN_BIN=""
  BUN_DIR=""
  local bun_candidate
  for bun_candidate in \
    "$(command -v bun 2>/dev/null || true)" \
    "$HOME/.local/bin/bun" \
    "$HOME/.local/lib/commands/current/bun/bun" \
    "$HOME/.local/share/chezmoi-commands/incomplete/bun/bun"; do
    if [[ "$bun_candidate" == /* && -x "$bun_candidate" ]]; then
      BUN_BIN="$bun_candidate"
      break
    fi
  done
  if [[ -n "$BUN_BIN" ]]; then
    case "$BUN_BIN" in
      */*) BUN_DIR="${BUN_BIN%/*}" ;;
      *) BUN_DIR="" ;;
    esac
    if [[ -n "$BUN_DIR" ]]; then
      case ":$PATH:" in
        *":$BUN_DIR:"*) ;;
        *) PATH="$BUN_DIR:$PATH" ;;
      esac
      export PATH
    fi
  fi
}
