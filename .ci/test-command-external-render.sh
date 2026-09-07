#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=.ci/lib/render-scratch.sh
source "$repo_root/.ci/lib/render-scratch.sh"
setup_render_scratch command-external-render

fail() { printf 'command external render: %s\n' "$*" >&2; exit 1; }

[[ ! -f "$repo_root/.chezmoiscripts/00-tools/run_onchange_after_codegraph.sh.tmpl" ]] || {
  fail "run_onchange_after_codegraph.sh.tmpl should be deleted"
}

# Stanzas whose archive-internal `path` is composed from the platform: a drift
# between the asset name in `url` and the directory or filename inside it makes
# the extraction miss. These are checked by assert_url_path_agreement below.
platform_composed_units=(
  aoe bun bunx codex garden helm minikube uv uvx wakatime-cli wasm-pack
)

# Every other stanza that declares `path` is an explicit exemption: its `path`
# carries no platform token at all, so the agreement rule does not apply.
#   agy                       archive member 'antigravity'
#   ast-grep, sg              flat archive, bare binary names
#   buf, protoc-gen-buf-*     'buf/bin/<name>', version- and platform-free
#   buf-zsh-completion        'buf/share/zsh/site-functions/_buf'
#   gh, glab                  'bin/gh', 'bin/glab'
#   the shellcheck unit       'shellcheck-<version>/shellcheck', version token only
#   winbox, winbox-icon       'WinBox', 'assets/img/winbox.png' (linux-only asset)
path_exempt_units=(
  agy ast-grep buf buf-zsh-completion gh glab
  protoc-gen-buf-breaking protoc-gen-buf-lint sg shellcheck winbox winbox-icon
)

# Platform token vocabulary, per (os, arch), longest match first.
#
# The two vocabularies differ. A `url` speaks the upstream asset name; a `path`
# may repeat it, use a Rust target triple, or put the token in the filename
# instead of the leading directory. All three forms are listed here so the
# check compares like with like:
#
#   <os>-<arch>          aoe-linux-amd64, helm .../linux-amd64/helm
#   <os>-<altarch>       bun-linux-x64, bun-darwin-aarch64
#   <os>-<altarch>-musl  bun-linux-x64-musl (musl leg only in practice)
#   Rust target triple   codex/uv/wasm-pack x86_64-unknown-linux-musl,
#                        garden x86_64-unknown-linux-gnu, *-apple-darwin
#
# The linux musl tokens stay in the vocabulary on the glibc legs too. The
# vocabulary is what a token may look like, not what a leg must select, so a
# `path` that carries '-musl' while its `url` does not is caught as a
# disagreement rather than silently matching the shorter glibc token.
platform_tokens() {
  case "$1:$2" in
  linux:amd64)
    printf '%s\n' x86_64-unknown-linux-musl x86_64-unknown-linux-gnu \
      linux-x64-musl linux-amd64 linux-x64
    ;;
  linux:arm64)
    printf '%s\n' aarch64-unknown-linux-musl aarch64-unknown-linux-gnu \
      linux-aarch64-musl linux-aarch64 linux-arm64
    ;;
  darwin:amd64)
    printf '%s\n' x86_64-apple-darwin darwin-amd64 darwin-x64
    ;;
  darwin:arm64)
    printf '%s\n' aarch64-apple-darwin darwin-aarch64 darwin-arm64
    ;;
  *)
    fail "no platform token vocabulary for $1/$2"
    ;;
  esac
}

# First vocabulary token that occurs in "$1", in the order platform_tokens
# emits them. Prints nothing and returns 1 when none matches.
first_token() {
  local haystack=$1 token
  shift
  for token in "$@"; do
    case "$haystack" in
    *"$token"*)
      printf '%s' "$token"
      return 0
      ;;
    esac
  done
  return 1
}

in_list() {
  local needle=$1 item
  shift
  for item in "$@"; do
    [[ "$item" != "$needle" ]] || return 0
  done
  return 1
}

# Emits "<unit>\t<url>\t<path>" for every rendered stanza that declares both.
stanza_records() {
  awk '
    function flush() {
      if (unit != "" && url != "" && path != "") printf "%s\t%s\t%s\n", unit, url, path
      url = ""; path = ""
    }
    function value(line,   v) {
      v = line
      sub(/^[a-zA-Z]+[ \t]*=[ \t]*/, "", v)
      sub(/[ \t\r]+$/, "", v)
      return substr(v, 2, length(v) - 2)
    }
    /^\[/ { flush(); unit = $0; sub(/^\[/, "", unit); sub(/\].*$/, "", unit); next }
    /^url[ \t]*=/  { url  = value($0); next }
    /^path[ \t]*=/ { path = value($0); next }
    END { flush() }
  ' "$1"
}

# Vacuity guard for the assertions built on stanza_records. A broken extractor
# emits nothing, and every loop below it then completes without testing a single
# stanza. Every platform-composed unit renders on every leg, so demand them all:
# the floor moves with the unit list instead of being a number that rots.
assert_stanza_coverage() {
  local rendered=$1 label=$2 unit
  local -a seen
  mapfile -t seen < <(stanza_records "$rendered" | cut -f1)
  for unit in "${platform_composed_units[@]}"; do
    in_list "$unit" "${seen[@]}" || {
      fail "$label: stanza_records yielded no record for platform-composed unit
  '$unit' (${#seen[@]} records in total). The extractor is broken, so every
  assertion over its output is passing vacuously."
    }
  done
}

assert_url_path_agreement() {
  local rendered=$1 os=$2 arch=$3 label=$4
  local -a tokens
  mapfile -t tokens < <(platform_tokens "$os" "$arch")
  [[ ${#tokens[@]} -gt 0 ]] || fail "$label: empty platform token vocabulary"

  local unit url path basename url_token path_token
  while IFS=$'\t' read -r unit url path; do
    [[ -n "$unit" ]] || continue
    if in_list "$unit" "${path_exempt_units[@]}"; then
      continue
    fi
    if ! in_list "$unit" "${platform_composed_units[@]}"; then
      fail "$label: stanza '$unit' declares path '$path' but is in neither
  platform_composed_units nor path_exempt_units in $0. Classify it: does its
  archive-internal path carry a platform token, or not?"
    fi

    basename=${url##*/}
    url_token=$(first_token "$basename" "${tokens[@]}") || {
      fail "$label: stanza '$unit' url asset '$basename' carries no known
  platform token for $os/$arch. Extend platform_tokens in $0."
    }
    path_token=$(first_token "$path" "${tokens[@]}") || {
      fail "$label: stanza '$unit' path '$path' carries no known platform token
  for $os/$arch, but '$unit' is declared platform-composed."
    }
    [[ "$url_token" == "$path_token" ]] || {
      fail "$label: stanza '$unit' disagrees — url asset '$basename' implies
  '$url_token' but path '$path' implies '$path_token'."
    }
  done < <(stanza_records "$rendered")
}

# os:arch:muslLinux. The musl legs use renderOverrides.muslLinux, which
# .chezmoitemplates/musl-probe.tmpl honors ahead of its `ldd` probe, so CI
# renders the musl branch with no musl runner.
platforms=(
  "linux:amd64:false"
  "linux:arm64:false"
  "linux:amd64:true"
  "linux:arm64:true"
  "darwin:amd64:false"
  "darwin:arm64:false"
)

for plat in "${platforms[@]}"; do
  IFS=":" read -r os arch musl <<<"$plat"
  label="$os/$arch musl=$musl"
  out="$scratch/externals-$os-$arch-musl-$musl.toml"
  : >"$out"
  for ext in "$repo_root/.chezmoiexternals"/*.toml; do
    env PATH="$scratch/bin:$PATH" chezmoi --config "$scratch/empty.toml" --source "$repo_root" --destination "$scratch/target" \
      --override-data "{\"chezmoi\":{\"os\":\"$os\",\"arch\":\"$arch\"},\"renderOverrides\":{\"muslLinux\":$musl}}" \
      execute-template <"$ext" >>"$out"
    # Not every external renders with a trailing newline (dev-tools.toml does
    # not), so separate them or the next file's first line — a stanza header —
    # is glued onto the previous one and its stanza escapes the checks below.
    printf '\n' >>"$out"
  done

  if grep -E 'targetPath\s*=\s*.*\.local/bin/' "$out"; then
    fail "found targetPath starting with .local/bin/ in $out"
  fi

  grep -F '.local/share/chezmoi-commands/incomplete/' "$out" >/dev/null || {
    fail "missing .local/share/chezmoi-commands/incomplete/ targets in $out"
  }

  assert_stanza_coverage "$out" "$label"
  assert_url_path_agreement "$out" "$os" "$arch" "$label"

  # Leg sanity: the musl override must actually select the musl assets, and
  # darwin must never reach for one.
  if [[ "$os" == "linux" && "$musl" == "true" ]]; then
    while IFS=$'\t' read -r unit url path; do
      [[ "$unit" == bun || "$unit" == bunx ]] || continue
      [[ "$url" == *-musl.* && "$path" == *-musl/* ]] || {
        fail "$label: expected a musl url and path for '$unit', got url '$url' path '$path'"
      }
    done < <(stanza_records "$out")
  fi
  if [[ "$os" == "darwin" ]]; then
    if grep -E "^url\s*=.*-musl" "$out"; then
      fail "$label: darwin renders a -musl url"
    fi
  fi
done

# --- negative fixtures ------------------------------------------------------
#
# Everything above runs over genuine renders, which agree by construction, so a
# hollowed-out assertion would pass just as quietly as a correct one. The cases
# below feed deliberately broken input to the same functions and require each to
# reject it, which is what makes the checks above evidence rather than decor.
#
# The genuine linux/amd64 render is the baseline: the loop already accepted it,
# so any rejection below comes from the mutation and nothing else.

negative_case() {
  local label=$1 fixture=$2 os=$3 arch=$4 want=$5
  local report="$scratch/negative-report" status=0
  (assert_url_path_agreement "$fixture" "$os" "$arch" "negative") >"$report" 2>&1 || status=$?
  [[ $status -ne 0 ]] || {
    fail "negative fixture '$label' was accepted; assert_url_path_agreement no
  longer detects it and the whole check is decoration."
  }
  grep -qF "$want" "$report" || {
    fail "negative fixture '$label' was rejected, but not for '$want': $(tr '\n' ' ' <"$report")"
  }
  printf 'negative fixture bites: %s\n' "$label"
}

genuine="$scratch/externals-linux-amd64-musl-false.toml"
[[ -f "$genuine" ]] || fail "the linux/amd64 render is missing; the negative fixtures have nothing to mutate"

bun_path=$(stanza_records "$genuine" | awk -F'\t' '$1 == "bun" { print $3; exit }')
[[ "$bun_path" == *linux-x64* ]] || {
  fail "expected the linux/amd64 bun path to carry 'linux-x64', got '$bun_path'.
  Retarget the mutations below at whatever token it carries now."
}

# 1. A path whose platform token is a *different* token from the same leg's
#    vocabulary: the asset-name/archive-path drift this gate exists to catch.
mismatch="$scratch/negative-token-mismatch.toml"
sed "s|^path = '$bun_path'\$|path = '${bun_path/linux-x64/linux-amd64}'|" "$genuine" >"$mismatch"
grep -qF "path = '${bun_path/linux-x64/linux-amd64}'" "$mismatch" || fail 'the token-mismatch mutation did not apply'
negative_case 'a path token disagreeing with the url asset' "$mismatch" linux amd64 'disagrees'

# 2. A path carrying another platform's token entirely, which is not in this
#    leg's vocabulary at all.
foreign="$scratch/negative-foreign-token.toml"
sed "s|^path = '$bun_path'\$|path = '${bun_path/linux-x64/linux-aarch64}'|" "$genuine" >"$foreign"
grep -qF "path = '${bun_path/linux-x64/linux-aarch64}'" "$foreign" || fail 'the foreign-token mutation did not apply'
negative_case 'a path token from another platform' "$foreign" linux amd64 'carries no known platform token'

# 3. A stanza that declares `path` but is classified neither way, which is how a
#    newly added external slips past the agreement rule unnoticed.
unclassified="$scratch/negative-unclassified.toml"
cat >"$unclassified" <<'TOML'
[not-a-declared-unit]
type = 'archive-file'
url = 'https://example.invalid/tool-linux-x64.zip'
path = 'tool-linux-x64/tool'
TOML
negative_case 'a stanza in neither classification list' "$unclassified" linux amd64 'but is in neither'

# 4. The vacuity guard itself: an extractor that yields nothing must fail rather
#    than let the empty stream satisfy every assertion downstream.
empty_records="$scratch/negative-empty.toml"
: >"$empty_records"
coverage_status=0
(assert_stanza_coverage "$empty_records" negative) >"$scratch/negative-report" 2>&1 || coverage_status=$?
[[ $coverage_status -ne 0 ]] || fail 'assert_stanza_coverage accepted a render with no stanzas at all'
grep -qF 'passing vacuously' "$scratch/negative-report" ||
  fail "the empty-render rejection came from somewhere else: $(tr '\n' ' ' <"$scratch/negative-report")"
printf 'negative fixture bites: %s\n' 'a render yielding no stanza records'

rendered_flutter="$scratch/flutter.sh"

env PATH="$scratch/bin:$PATH" chezmoi --config "$scratch/empty.toml" --source "$repo_root" --destination "$scratch/target" \
  --override-data '{"chezmoi":{"os":"linux","arch":"amd64"}}' \
  execute-template <"$repo_root/.chezmoiscripts/00-tools/run_onchange_after_flutter.sh.tmpl" >"$rendered_flutter"

if grep -E '\$BIN_DIR|pruned=' "$rendered_flutter"; then
  fail "flutter script still contains public link or prune operations"
fi


printf '%s\n' 'command external render validation passed'
