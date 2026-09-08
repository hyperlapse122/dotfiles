#!/usr/bin/env bash
set -euo pipefail

# Keeps the android-cli skill chezmoi's, not the Android CLI's.
#
# WHY A GATE. `android init` reads as environment setup, but installing the
# android-cli skill is its whole effect: it walks every coding agent it can
# detect and writes the skill into that agent's GLOBAL skills directory,
# overwriting what is already there without asking. On this host
# `~/.claude/skills`, `~/.codex/skills` and `~/.gemini/skills` are all symlinks
# to the chezmoi-managed `~/.agents/skills` tree (dot_claude/symlink_skills and
# its peers), so one `android init` lands three times in that tree and replaces
# `~/.agents/skills/android-cli` with unpinned bytes from whatever CLI bundle is
# current. None of it is visible in a green apply — chezmoi does not report a
# file it no longer owns — and the SDK script used to call it on every version
# bump. The skill is a pinned external now; this keeps it that way.
#
# TWO CHECKS.
#   1. The rendered SDK script invokes no skill-writing subcommand. Asserted by
#      RUNNING the render against a stub `android` that logs its argv, because
#      the check is about what the script does: the script's own comment names
#      `android init` to explain why it is absent, so a text scan over the render
#      would have to special-case the very words it is looking for, and would
#      still miss `android skills add`, a wrapper, or a reworded call.
#   2. The externals carry the skill instead: `.agents/skills/android-cli` is an
#      exact archive external anchored on the subtree android/skills actually
#      files it under. Check 1 alone would pass just as well with the skill gone.

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

fail() { printf 'android-skill-ownership: FAIL: %s\n' "$*" >&2; exit 1; }

command -v chezmoi >/dev/null 2>&1 || fail 'chezmoi is required on PATH'
chezmoi_bin=$(type -P chezmoi)

# tomllib is stdlib from 3.11; a mise or pyenv python earlier on PATH is fine as
# long as it has it, so probe both the way the other TOML-reading gates do.
toml_python=''
for candidate in /usr/bin/python3 python3; do
  command -v "$candidate" >/dev/null 2>&1 || continue
  if "$candidate" -c 'import tomllib' >/dev/null 2>&1; then
    toml_python=$candidate
    break
  fi
done
[[ -n $toml_python ]] || fail 'no python3 with tomllib (3.11+) found'

# shellcheck source=.ci/lib/render-scratch.sh
source "$repo_root/.ci/lib/render-scratch.sh"
# shellcheck source=.ci/lib/render-gate-helpers.sh
source "$repo_root/.ci/lib/render-gate-helpers.sh"
setup_render_scratch android-skill-ownership

sdk_script=.chezmoiscripts/00-tools/run_onchange_after_android-sdk.sh.tmpl
externals=.chezmoiexternals/ai-agents.toml
[[ -f "$repo_root/$sdk_script" ]] || fail "missing source surface $sdk_script"
[[ -f "$repo_root/$externals" ]] || fail "missing source surface $externals"

# --- Check 1: the SDK script drives the CLI, and never its skill installer ----

# container=false, because the script is gated out of containers entirely and a
# render that produced nothing would satisfy every assertion below vacuously.
rendered="$scratch/android-sdk.sh"
render_reconciler "$repo_root" "$scratch" "$chezmoi_bin" linux false "$sdk_script" "$rendered"
[[ -s $rendered ]] || fail 'the SDK script rendered empty with container=false'
bash -n "$rendered" || fail 'the rendered SDK script is not valid shell'
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -S warning "$rendered" || fail 'the rendered SDK script fails shellcheck'
fi

home="$scratch/home"
log="$scratch/android-argv.log"
mkdir -p "$home/.local/bin"
: >"$log"
# The script prefers ~/.local/bin/android and falls back to PATH; the stub sits
# at the preferred path so the run cannot reach a real CLI. It exits 0 because
# every call site is `|| true` — a non-zero stub would prove nothing.
cat >"$home/.local/bin/android" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$log"
STUB
chmod 700 "$home/.local/bin/android"

env HOME="$home" PATH="$home/.local/bin:/usr/bin:/bin" bash "$rendered" \
  || fail 'the rendered SDK script exited non-zero against the stub CLI'

# A stub nothing called would make every assertion below vacuous, exactly as an
# empty render would.
[[ -s $log ]] || fail 'the rendered SDK script never invoked the android CLI'

while IFS= read -r invocation; do
  # Flags come first (`--sdk=...`); the subcommand is the first bare word.
  read -r -a argv <<<"$invocation"
  subcommand=''
  for word in "${argv[@]}"; do
    [[ $word == -* ]] && continue
    subcommand=$word
    break
  done
  case $subcommand in
    # `sdk` installs components; `emulator` lists and creates AVDs. Neither
    # touches a skills directory. Every subcommand is allowlisted one at a time
    # on purpose: adding one is a reviewed edit here, not a silent change in
    # the SDK script.
    sdk | emulator) ;;
    init | skills)
      fail "the SDK script invokes \`android $subcommand\`, which writes into ~/.agents/skills: $invocation"
      ;;
    *) fail "the SDK script invokes an unreviewed subcommand \`android $subcommand\`: $invocation" ;;
  esac
done <"$log"

# --- Check 2: the skill is a pinned external -------------------------------

rendered_externals="$scratch/ai-agents.toml"
env HOME="$home" PATH="$scratch/bin:/usr/bin:/bin" "$chezmoi_bin" \
  --config "$scratch/empty.toml" --source "$repo_root" --destination "$scratch/target" \
  execute-template <"$repo_root/$externals" >"$rendered_externals" \
  || fail "$externals failed to render"

"$toml_python" - "$rendered_externals" <<'PY' || fail 'the android-cli external is not the pinned archive it must be'
import sys, tomllib

with open(sys.argv[1], "rb") as handle:
    externals = tomllib.load(handle)

target = ".agents/skills/android-cli"
stanza = externals.get(target)
if stanza is None:
    print(f"no [{target!r}] stanza: the skill is not chezmoi-managed", file=sys.stderr)
    raise SystemExit(1)

problems = []
if stanza.get("type") != "archive":
    problems.append(f"type is {stanza.get('type')!r}, want 'archive'")
if stanza.get("exact") is not True:
    problems.append("exact is not true, so an upstream deletion would survive")
url = stanza.get("url", "")
if not url.startswith("https://github.com/android/skills/archive/"):
    problems.append(f"url {url!r} is not an android/skills source archive")
if url.endswith("/latest.tar.gz") or "/latest/" in url:
    problems.append(f"url {url!r} is unpinned")
# The include anchors on the in-repo subtree and stripComponents drops the
# archive's own top directory plus every one of that subtree's segments, so the
# two must agree or the skill lands at the wrong depth.
include = stanza.get("include", [])
if include != ["*/devtools/android-cli/**"]:
    problems.append(f"include is {include!r}, want ['*/devtools/android-cli/**']")
if stanza.get("stripComponents") != 3:
    problems.append(f"stripComponents is {stanza.get('stripComponents')!r}, want 3")

if problems:
    for problem in problems:
        print(f"  {problem}", file=sys.stderr)
    raise SystemExit(1)
PY

printf 'android-skill-ownership: PASS\n'
