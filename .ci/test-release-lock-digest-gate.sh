#!/usr/bin/env bash
set -euo pipefail

# Gates `.ci/check-release-lock-digests.sh`, which decides whether the generated
# release lock may be committed.
#
# It exists because the rule it covers used to live inline in
# `refresh-release-lock.yml` and therefore ran only on the hourly schedule,
# against `main`, after a merge. That is how a lock entry carrying only a sha512
# reached the default branch and froze the refresh: nothing could run the rule
# before the merge, and nothing could run it locally at all. Each case below
# pins one accept or reject decision so a change to the predicate has to be
# deliberate.
#
# Fixtures are hand-written minimal locks, not copies of the real one, so a
# scheduled lock refresh never rewrites this suite's inputs. The committed lock
# is exercised separately as its own case: the fixtures prove the rule, and that
# case proves the rule still admits the repository we actually have.

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
gate="$repo_root/.ci/check-release-lock-digests.sh"
fixtures="$repo_root/.ci/fixtures/release-lock-digests"
lock="$repo_root/.chezmoidata/releases.json"

[ -x "$gate" ] || {
  printf 'release-lock digest gate: missing or non-executable %s\n' "$gate" >&2
  exit 1
}

case_name=
out=

fail() {
  printf 'release-lock digest gate [%s]: %s\n' "$case_name" "$*" >&2
  [ -z "$out" ] || printf -- '--- gate output ---\n%s\n-------------------\n' "$out" >&2
  exit 1
}

pass() {
  printf 'release-lock digest gate: ok - %s\n' "$1"
}

run_gate() {
  out=$("$gate" "$1" 2>&1) && return 0 || return $?
}

# accepts <fixture-basename> <what it proves>
accepts() {
  case_name=$1
  out=
  local rc=0
  run_gate "$fixtures/$1" || rc=$?
  [ "$rc" -eq 0 ] || fail "expected exit 0, got exit $rc"
  pass "$2"
}

# rejects <fixture-basename> <expected substring> <what it proves>
rejects() {
  case_name=$1
  out=
  local rc=0
  run_gate "$fixtures/$1" || rc=$?
  [ "$rc" -eq 1 ] || fail "expected exit 1, got exit $rc"
  case $out in
  *"$2"*) ;;
  *) fail "output does not name '$2'" ;;
  esac
  pass "$3"
}

# A sha256 is still the ordinary case and still passes on its own.
accepts accept-sha256.json 'a valid sha256 alone is accepted'

# Either digest satisfies the rule by itself, so a malformed sibling field does
# not make a well-formed digest unusable. These two pin the predicate as an OR.
accepts accept-sha512-with-malformed-sha256.json 'a valid sha512 carries an artifact whose sha256 is malformed'
accepts accept-sha256-with-malformed-sha512.json 'a valid sha256 carries an artifact whose sha512 is malformed'

# The retained antigravity vendor resolver publishes only SHA-512.
accepts accept-sha512-only.json 'a valid sha512 with a null sha256 is accepted'

# 1Password's arm64 tarball genuinely publishes no digest; its integrity comes
# from a GPG signature checked at install time.
accepts accept-1password-exemption.json 'the 1password linux-arm64 exemption is accepted'

# Twelve tools in the real lock resolve to a version with no downloadable
# artifact. They must not read as violations.
accepts accept-no-artifacts.json 'a tool with no artifacts key is accepted'

# An artifact nothing can verify is the case the gate exists to stop.
rejects reject-no-digest.json 'toolx linux-amd64: no valid sha256 or sha512' 'an artifact with neither digest is rejected'

# A digest that is not in the recorded shape is not a digest. chezmoi compares
# the literal string, so a near-miss verifies nothing. Both digest fields get
# the same shapes, or a regex mutation in one survives while the other is
# pinned. The trailing-newline case is why the pattern anchors on `\z`.
rejects reject-sha512-uppercase.json 'no valid sha256 or sha512' 'an uppercase sha512 is rejected'
rejects reject-sha512-short.json 'no valid sha256 or sha512' 'a 127-character sha512 is rejected'
rejects reject-sha512-prefixed.json 'no valid sha256 or sha512' 'a sha512: -prefixed digest is rejected'
rejects reject-sha256-uppercase.json 'no valid sha256 or sha512' 'an uppercase sha256 is rejected'
rejects reject-sha256-short.json 'no valid sha256 or sha512' 'a 63-character sha256 is rejected'
rejects reject-sha256-trailing-newline.json 'no valid sha256 or sha512' 'a sha256 with a trailing newline is rejected'

# Each clause of the exemption binds on its own. A tool named 1password does not
# inherit it for another platform, source, kind, or a name that merely starts
# the same way, and the explicit null sha256 is part of the match.
rejects reject-1password-other-platform.json '1password linux-amd64' 'the exemption does not widen to another platform'
rejects reject-1password-wrong-source.json '1password linux-arm64' 'the exemption does not widen to another source'
rejects reject-1password-wrong-kind.json '1password linux-arm64' 'the exemption does not widen to another resolver kind'
rejects reject-1password-wrong-tool-key.json '1password-beta linux-arm64' 'the exemption does not widen to another tool key'
rejects reject-1password-absent-sha256.json '1password linux-arm64' 'the exemption requires an explicitly null sha256, not an absent one'

# A URL is only as good as the bytes it keeps addressing. The `android` entry
# once locked a `/latest/` path whose body changed underneath the digest beside
# it, which no cache could recover from; the rule rejects that shape wherever it
# comes back. It binds on the path segment, so `latest` inside a filename — the
# version is elsewhere in the URL — still passes.
rejects reject-url-latest-segment.json 'url carries a moving /latest path segment' 'a url with a /latest/ path segment is rejected'
accepts accept-url-latest-in-filename.json 'a url with latest inside the filename is accepted'

# The transport check is unchanged by the digest work.
rejects reject-url-http.json 'url is not an https:// string' 'a plain http url is rejected'
rejects reject-url-missing.json 'url is not an https:// string' 'a missing url is rejected'
rejects reject-url-nonstring.json 'url is not an https:// string' 'a non-string url is rejected'

# The platform-key check names the tool as well as the key, so a failure says
# whose entry to look at.
rejects reject-bad-platform-key.json 'toolx windows-amd64' 'an unsupported platform key is rejected, naming its tool'

# A lock with nothing in it violates neither check, so without an explicit
# refusal the gate would green a file that says nothing at all. Same for a lock
# that is not JSON: it must fail as a lock defect, not as a jq crash.
rejects reject-empty-lock.json 'carries no releases.tools entries' 'a lock with no tools is rejected'
rejects reject-malformed-json.json 'is not valid JSON' 'a lock that is not JSON is rejected'

# The gate hardcodes the platform vocabulary that `packages/release-lock` owns,
# because a validation gate that imported the TypeScript would fail whenever the
# TypeScript did — the wrong coupling for the thing that decides whether a lock
# may be committed. The copy is safe only while something notices it drifting,
# so this case is that something. The test may depend on bun; the gate may not.
case_name=platform-vocabulary-drift
out=
gate_keys=$(sed -n "s/^supported='\(.*\)'\$/\1/p" "$gate" | jq -r '.[]' | sort)
[ -n "$gate_keys" ] || fail 'could not read the supported platform list out of the gate'
# shellcheck source=.ci/lib/bun.sh
source "$repo_root/.ci/lib/bun.sh"
resolve_bun
if [ -n "$BUN_BIN" ]; then
  source_keys=$(cd "$repo_root/packages/release-lock" &&
    "$BUN_BIN" -e 'const m = await import("./src/platforms.ts"); console.log(m.ALL_PLATFORMS_WITH_MUSL.map(m.platformKey).join("\n"))' |
    sort)
  [ "$gate_keys" = "$source_keys" ] || {
    out=$(printf 'gate:\n%s\nplatforms.ts:\n%s\n' "$gate_keys" "$source_keys")
    fail 'the gate support matrix has drifted from ALL_PLATFORMS_WITH_MUSL'
  }
  pass 'the gate support matrix matches platforms.ts'
else
  # A check that skips itself is a check that passes forever. CI provisions bun
  # for this job, so absence there is a broken job, not a local convenience.
  [ -z "${CI:-}" ] || fail 'bun is required in CI; the support-matrix drift case cannot be skipped'
  printf 'release-lock digest gate: skipped - bun is not found on PATH or anywhere in the resolution ladder, cannot compare the support matrix against platforms.ts\n'
fi

# The rule has to admit the repository we actually have, not only the fixtures.
case_name=committed-lock
out=
run_gate "$lock" || fail 'the committed release lock does not pass the gate'
pass 'the committed .chezmoidata/releases.json passes'

case_name=agy-exact-pin
jq -e '
  .releases.tools.agy
  | .kind == "githubRelease"
    and .source == "google-antigravity/antigravity-cli"
    and .version == "1.1.28"
    and (.artifacts | keys == ["darwin-amd64", "darwin-arm64", "linux-amd64", "linux-arm64"])
' "$lock" >/dev/null || fail 'the committed lock does not contain the reviewed official 1.1.28 pin'

scratch_parent=${XDG_RUNTIME_DIR:-${HOME:?HOME is required}/.cache}
mkdir -p "$scratch_parent"
scratch=$(mktemp -d "$scratch_parent/release-lock-render.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
mkdir -p "$scratch/home" "$scratch/bin" "$scratch/target"
printf '[data]\n' >"$scratch/empty.toml"
printf '#!/usr/bin/env bash\nprintf dummy-secret\n' >"$scratch/bin/op"
chmod 0700 "$scratch/bin/op"
chezmoi_bin=$(command -v chezmoi)
# shellcheck source=.ci/lib/render-gate-helpers.sh
source "$repo_root/.ci/lib/render-gate-helpers.sh"

for os in linux darwin; do
  for arch in amd64 arm64; do
    case_name="agy-render-$os-$arch"
    printf '{{- $_ := set .chezmoi "arch" "%s" -}}\n' "$arch" >"$scratch/external.tmpl"
    cat "$repo_root/.chezmoiexternals/ai-agents.toml" >>"$scratch/external.tmpl"
    render "$repo_root" "$scratch" "$chezmoi_bin" "$os" "$scratch/external.tmpl" "$scratch/external.toml"
    rendered=$(sed -n '/^\[agy\]$/,/^\[agent-browser\]$/p' "$scratch/external.toml")
    url=$(jq -r --arg key "$os-$arch" '.releases.tools.agy.artifacts[$key].url' "$lock")
    digest=$(jq -r --arg key "$os-$arch" '.releases.tools.agy.artifacts[$key].sha256' "$lock")
    asset_os=$os
    [ "$os" != darwin ] || asset_os=mac
    asset_arch=$arch
    [ "$arch" != amd64 ] || asset_arch=x64
    [ "$url" = "https://github.com/google-antigravity/antigravity-cli/releases/download/1.1.28/agy_cli_${asset_os}_${asset_arch}.tar.gz" ] || fail 'unexpected official archive URL'
    [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || fail 'missing or invalid SHA-256'
    [[ "$rendered" == *"url = '$url'"* ]] || fail 'external URL differs from lock'
    [[ "$rendered" == *"sha256 = '$digest'"* ]] || fail 'external does not consume the locked SHA-256'
    [[ "$rendered" != *sha512* ]] || fail 'external still consumes SHA-512'
    pass "$case_name consumes the official archive and SHA-256"
  done
done

case_name=agy-native-updater-control
[[ $(grep -cx 'AGY_CLI_DISABLE_AUTO_UPDATE=true' "$repo_root/dot_config/environment.d/60-development.conf") == 1 ]] || fail 'Linux desktop environment must disable the native updater'
for inherited in unset false; do
  env -u AGY_CLI_DISABLE_AUTO_UPDATE ZDOTDIR="$scratch/home" zsh -dfc '
    mise() { printf ":"; }
    if [[ "$2" != unset ]]; then export AGY_CLI_DISABLE_AUTO_UPDATE="$2"; fi
    source "$1"
    [[ "$AGY_CLI_DISABLE_AUTO_UPDATE" == true ]]
    [[ "${(t)AGY_CLI_DISABLE_AUTO_UPDATE}" == *export* ]]
  ' -- "$repo_root/dot_config/zsh/dot_zshenv" "$inherited" || fail "shell updater control failed with inherited $inherited"
done
pass 'desktop and shell environments disable the native updater'

printf 'release-lock digest gate: all cases passed\n'
