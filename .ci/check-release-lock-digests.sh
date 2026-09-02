#!/usr/bin/env bash
set -euo pipefail

# Validates the generated release lock's platform vocabulary and artifact
# integrity fields. `refresh-release-lock.yml` runs it between the resolver and
# the commit, so a lock the gate rejects is never committed; `ci.yml` runs it on
# every pull request, so a lock change is checked before merge instead of by the
# next scheduled refresh.
#
# TWO CHECKS.
#   1. Every `artifacts` key is in the canonical support matrix. A tool with no
#      `artifacts` key contributes none and is not a violation.
#   2. Every artifact has an https source URL and a usable digest.
#
# DIGESTS. Upstreams do not agree on one hash. The GitHub release API supplies a
# sha256 per asset, and that is what most tools carry. The `antigravity` vendor
# manifest publishes only a sha512, so `agy` records a sha512 with a null
# sha256; chezmoi verifies it natively through `[agy.checksum] sha512` in
# `.chezmoiexternals/ai-agents.toml`. Either digest therefore satisfies this
# gate, and an artifact carrying neither still fails.
#
# THE ONE EXEMPTION. 1Password's linux-arm64 tarball is the only artifact source
# that publishes no digest at all. Its integrity is established out of band: the
# Jetson provisioning script verifies a GPG detached signature instead. Every
# clause of the exemption binds — tool key, resolver kind, vendor source,
# platform key, and an explicitly null sha256 — so it cannot widen to another
# platform of the same tool or to another tool of the same name.
#
# The walk is `to_entries[]` rather than `.tools[]` because a violation has to
# name the tool it belongs to. A bare value stream cannot: the failure would say
# which platform is wrong without saying whose it is.

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
lock=${1:-$repo_root/.chezmoidata/releases.json}

supported='["linux-amd64","linux-arm64","linux-amd64-musl","linux-arm64-musl","darwin-amd64","darwin-arm64"]'

# fail <summary> [detail]. Every failure path goes through here so each one also
# emits the GitHub Actions annotation.
fail() {
  printf 'check-release-lock-digests: %s\n' "$1" >&2
  [ -z "${2:-}" ] || printf '%s\n' "$2" >&2
  printf '::error::%s\n' "$1"
  exit 1
}

[ -f "$lock" ] || fail "lock not found: $lock"
jq empty "$lock" 2>/dev/null || fail "lock is not valid JSON: $lock"

# A lock with no tools has nothing to violate either check, so both walks would
# report clean and the gate would green a file that says nothing. Refuse it up
# front: an empty `.releases.tools` is a broken generator run, never a valid
# lock. The per-tool `// {}` below stays — a version-only tool such as winbox
# legitimately has no artifacts.
jq -e '(.releases.tools | type) == "object" and ((.releases.tools | length) > 0)' \
  "$lock" >/dev/null 2>&1 || fail "lock carries no releases.tools entries: $lock"

bad_keys=$(jq -r --argjson supported "$supported" '
  .releases.tools | to_entries[]
  | .key as $tool
  | (.value.artifacts // {}) | keys[]
  | select(. as $key | $supported | index($key) == null)
  | "  \($tool) \(.)"
' "$lock")

if [ -n "$bad_keys" ]; then
  fail 'lock carries platform keys outside the canonical support matrix' "$bad_keys"
fi

bad_artifacts=$(jq -r '
  # `\z`, not `$`: Oniguruma treats `$` as a line anchor, so `$` would accept a
  # digest with a trailing newline — a string chezmoi would then compare
  # literally and never match.
  def has_sha256: .sha256 | type == "string" and test("^[0-9a-f]{64}\\z");
  def has_sha512: .sha512 | type == "string" and test("^[0-9a-f]{128}\\z");

  .releases.tools | to_entries[] as $entry
  | $entry.value as $tool
  | ($tool.artifacts // {}) | to_entries[] as $artifact
  | $artifact.value as $a
  | ($entry.key == "1password"
     and $tool.kind == "vendorManifest"
     and $tool.source == "https://releases.1password.com/linux/stable/index.xml"
     and $artifact.key == "linux-arm64"
     and ($a | has("sha256"))
     and $a.sha256 == null) as $exempt
  | [ (if ($a.url | type == "string" and startswith("https://")) then empty
       else "url is not an https:// string" end),
      (if (($a | has_sha256) or ($a | has_sha512) or $exempt) then empty
       else "no valid sha256 or sha512" end) ] as $reasons
  | select($reasons | length > 0)
  | "  \($entry.key) \($artifact.key): \($reasons | join("; "))"
' "$lock")

if [ -n "$bad_artifacts" ]; then
  fail 'lock carries an artifact without an https source URL or a valid digest' "$bad_artifacts"
fi

printf 'check-release-lock-digests: ok - %s\n' "$lock"
