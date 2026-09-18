#!/usr/bin/env bash
set -euo pipefail

# The record job of .github/workflows/rebase-ce-overlays.yml: it maps the outcome
# of every upstream job to a failure class and to the inputs of the marker write
# and the tracking issue. `.ci/test-ce-overlay-classify-run.sh` covers it.
#
# ENVIRONMENT (set by the workflow step; an unset value counts as empty)
#   PF_RESULT PF_CLASS PF_MISSING MANUAL     preflight result, class, missing
#                                            prerequisites, and manual trigger
#   PREP_RESULT PREP_STATE TARGET            prepare result, state, and target tag
#   CLAUDE_RESULT CLAUDE_CLASS               claude result and class
#   PUB_RESULT PUB_CLASS PUB_MISSING         publish result, class, and missing
#   GITHUB_OUTPUT                            file that receives the lines below
#   GITHUB_TOKEN                             passed to the release resolver
#
# OUTPUT (GITHUB_OUTPUT)
#   action=none|failure class=<class> missing=<P1,...> reached=true|false
# and, for a failure, before those four lines:
#   existing_issue=<number|empty> target=<tag> now=<time> needs_issue=true|false
# A cancelled job records nothing. stdout logs the transition event and the marker
# status it produces.

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=.ci/lib/source-root.sh
source "$repo_root/.ci/lib/source-root.sh"
# shellcheck source=.ci/lib/ce-overlay.sh
source "$repo_root/.ci/lib/ce-overlay.sh"
# shellcheck source=.ci/lib/bun.sh
source "$repo_root/.ci/lib/bun.sh"

pf_result=${PF_RESULT-}
pf_class=${PF_CLASS-}
pf_missing=${PF_MISSING-}
manual=${MANUAL-}
prep_result=${PREP_RESULT-}
prep_state=${PREP_STATE-}
target=${TARGET-}
claude_result=${CLAUDE_RESULT-}
claude_class=${CLAUDE_CLASS-}
pub_result=${PUB_RESULT-}
pub_class=${PUB_CLASS-}
pub_missing=${PUB_MISSING-}
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT must name the step output file}"

resolve_bun
[[ -n $BUN_BIN ]] || {
  printf 'ce-overlay-classify-run: bun is required\n' >&2
  exit 1
}
package_cli="$repo_root/packages/ce-overlay-rebase/src/cli.ts"

action=none
class=''
missing=''
reached=false
if [ "$pf_result" = cancelled ] || [ "$prep_result" = cancelled ] || [ "$claude_result" = cancelled ] || [ "$pub_result" = cancelled ]; then
  echo '::notice::The run was cancelled. Nothing is recorded.'
elif [ "$pf_result" != success ]; then
  action=failure
  class=unknown
  if [ "$pf_class" = configuration ]; then
    class=configuration
    missing=$pf_missing
  fi
elif [ "$prep_result" != success ]; then
  action=failure
  case "$prep_state" in
    genuine) class=genuine ;;
    unavailable) class=outage ;;
    *) class=unknown ;;
  esac
elif [ "$claude_result" = failure ]; then
  action=failure
  class=$claude_class
  reached=true
elif [ "$pub_result" = failure ]; then
  action=failure
  class=$pub_class
  missing=$pub_missing
  if [ "$claude_result" = success ]; then
    reached=true
  fi
fi

if [ "$action" = failure ]; then
  "$BUN_BIN" "$package_cli" validate-class "$class" >/dev/null 2>&1 || class=unknown
  if [[ ! $missing =~ ^P[1-4](,P[1-4])*$ ]]; then
    missing=''
  fi
  marker_file=$(join_source_state "$repo_root" .chezmoidata/ce-overlay-rebase.json)
  current=$(jq -c '.ceOverlayRebase' "$marker_file")
  if ! ceo_tag_valid "$target"; then
    target=$("$repo_root/.ci/ce-overlay-lock-hold.sh" resolve-latest) || target=''
    if ! ceo_tag_valid "$target"; then
      target=$(jq -r '.target' <<<"$current")
    fi
  fi
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  event=$(jq -n -c --arg t "$target" --arg c "$class" --arg r "$reached" --arg m "$missing" --arg now "$now" --arg manual "$manual" '
    {type: "failure", target: $t, failureClass: $c, reachedClaude: ($r == "true"), now: $now}
    + (if $m == "" then {} else {missing: ($m | split(","))} end)
    + (if $manual == "true" then {manualTrigger: true} else {} end)')
  status=$(jq -n -c --argjson c "$current" --argjson e "$event" '{currentMarker: $c, event: $e}' |
    "$BUN_BIN" "$package_cli" transition | jq -r '.status')
  needs_issue=false
  case "$status" in
    escalated | blocked-config) needs_issue=true ;;
  esac
  printf 'transition event: %s\nmarker status after the event: %s\n' "$event" "$status"
  printf 'existing_issue=%s\n' "$(jq -r '.issue // ""' <<<"$current")" >>"$GITHUB_OUTPUT"
  printf 'target=%s\nnow=%s\nneeds_issue=%s\n' "$target" "$now" "$needs_issue" >>"$GITHUB_OUTPUT"
fi
printf 'action=%s\nclass=%s\nmissing=%s\nreached=%s\n' "$action" "$class" "$missing" "$reached" >>"$GITHUB_OUTPUT"
