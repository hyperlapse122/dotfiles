#!/usr/bin/env bash
# Unit tests for .ci/lib/render-gate-helpers.sh (write_fact_stub).
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=.ci/lib/render-gate-helpers.sh
source "$repo_root/.ci/lib/render-gate-helpers.sh"
# shellcheck source=.ci/lib/render-scratch.sh
source "$repo_root/.ci/lib/render-scratch.sh"

setup_render_scratch test-render-gate-helpers
mkdir -p "$scratch/home"

fail() { printf 'test-render-gate-helpers: FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'test-render-gate-helpers: ok - %s\n' "$*"; }

chezmoi_bin=$(command -v chezmoi) || fail 'chezmoi is required on PATH'

# ---------------------------------------------------------------------------
# Scenario 1: Happy path with unpinned fact and pinned parameter
# ---------------------------------------------------------------------------
fixture_happy="$scratch/happy.tmpl"
cat << 'EOF' > "$fixture_happy"
{{- $f := includeTemplate "facts.tmpl" . | fromYaml -}}
sharedHost={{ $f.sharedHost }}
desktop={{ $f.desktop }}
EOF

stubbed_happy="$scratch/happy-stubbed.tmpl"
rendered_happy="$scratch/happy-rendered.txt"
write_fact_stub "$fixture_happy" "$stubbed_happy" false false kde
render "$repo_root" "$scratch" "$chezmoi_bin" linux "$stubbed_happy" "$rendered_happy"

[[ -f "$rendered_happy" ]] || fail 'happy path: rendered output file missing'
grep -q '^sharedHost=false$' "$rendered_happy" || fail "happy path: expected sharedHost=false in $(cat "$rendered_happy")"
grep -q '^desktop=kde$' "$rendered_happy" || fail "happy path: expected desktop=kde in $(cat "$rendered_happy")"
pass 'happy path: unpinned fact renders false and pinned desktop renders passed value'

# ---------------------------------------------------------------------------
# Scenario 2: Partial form binding $facts from .ctx
# ---------------------------------------------------------------------------
fixture_partial="$scratch/partial.tmpl"
cat << 'EOF' > "$fixture_partial"
{{- $facts := includeTemplate "facts.tmpl" .ctx | fromYaml -}}
battery={{ $facts.battery }}
container={{ $facts.container }}
EOF

stubbed_partial="$scratch/partial-stubbed.tmpl"
rendered_partial="$scratch/partial-rendered.txt"
write_fact_stub "$fixture_partial" "$stubbed_partial" true false gnome
render "$repo_root" "$scratch" "$chezmoi_bin" linux "$stubbed_partial" "$rendered_partial"

[[ -f "$rendered_partial" ]] || fail 'partial form: rendered output file missing'
grep -q '^battery=false$' "$rendered_partial" || fail "partial form: expected battery=false in $(cat "$rendered_partial")"
grep -q '^container=true$' "$rendered_partial" || fail "partial form: expected container=true in $(cat "$rendered_partial")"
pass 'partial form: fixture binding $facts from .ctx pins referenced facts'

# ---------------------------------------------------------------------------
# Scenario 3: No include passes through unchanged
# ---------------------------------------------------------------------------
fixture_no_include="$scratch/no-include.tmpl"
cat << 'EOF' > "$fixture_no_include"
# Static template with no facts include
literal content line 1
literal content line 2
EOF

stubbed_no_include="$scratch/no-include-stubbed.tmpl"
write_fact_stub "$fixture_no_include" "$stubbed_no_include" false false gnome

cmp -s "$fixture_no_include" "$stubbed_no_include" || fail 'no include: fixture with no facts include must be copied byte-for-byte'
pass 'no include: fixture with no facts include is copied byte-for-byte'

# ---------------------------------------------------------------------------
# Scenario 4: Error path with unrewritten facts include
# ---------------------------------------------------------------------------
fixture_error="$scratch/error.tmpl"
cat << 'EOF' > "$fixture_error"
{{- $f := includeTemplate "facts.tmpl" $ctx | fromYaml -}}
desktop={{ $f.desktop }}
EOF

stubbed_error="$scratch/error-stubbed.tmpl"
if ( write_fact_stub "$fixture_error" "$stubbed_error" false false gnome >/dev/null 2>&1 ); then
  fail 'error path: write_fact_stub unexpectedly succeeded on unrewritten facts include'
fi
pass 'error path: unrewritten facts include makes write_fact_stub fail'

printf 'test-render-gate-helpers: all tests passed\n'
