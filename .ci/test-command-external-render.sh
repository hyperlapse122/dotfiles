#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
scratch_root="${XDG_RUNTIME_DIR:-$HOME/.cache}/agent-scratch"
mkdir -p "$scratch_root"
scratch=$(mktemp -d "$scratch_root/command-external-render.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
mkdir -p "$scratch/bin" "$scratch/target"
printf '#!/usr/bin/env bash\nprintf dummy-secret\n' >"$scratch/bin/op"
chmod 700 "$scratch/bin/op"
printf '[data]\n' >"$scratch/empty.toml"

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

rendered_flutter="$scratch/flutter.sh"

env PATH="$scratch/bin:$PATH" chezmoi --config "$scratch/empty.toml" --source "$repo_root" --destination "$scratch/target" \
  --override-data '{"chezmoi":{"os":"linux","arch":"amd64"}}' \
  execute-template <"$repo_root/.chezmoiscripts/00-tools/run_onchange_after_flutter.sh.tmpl" >"$rendered_flutter"

if grep -E '\$BIN_DIR|pruned=' "$rendered_flutter"; then
  fail "flutter script still contains public link or prune operations"
fi


printf '%s\n' 'command external render validation passed'
