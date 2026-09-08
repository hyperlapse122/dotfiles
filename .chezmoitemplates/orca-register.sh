# orca-register.sh — registers every declared ~/src tree into Orca, shared by
# the apply-time script .chezmoiscripts/90-src/run_after_orca-register.sh.tmpl
# (which inlines it) and .ci/test-orca-register.sh (which drives it against a
# stubbed CLI). The product rules are owned by the R-IDs of
# docs/plans/2026-09-08-1326-feat-orca-owns-projects-and-emulator-plan.md; this
# file only carries them out.
#
# NOT A TEMPLATE and not a deployed target: it lives in .chezmoitemplates
# because that is the only directory includeTemplate can read. It is rendered as
# a Go template on the way in, so it must contain no brace-brace sequence.
# Keep it POSIX sh.
#
# WHY A STREAM AND NOT THE REGISTRY. Same reason as
# garden-path-mirror-check.sh: the registry is GPG-encrypted and no CI runner
# holds the key. The caller supplies already-parsed
# `name<TAB>abspath<TAB>relpath<TAB>url` records — the apply script reads them
# from `garden ls -v` through that checker's record producer, the CI test
# writes them as literals.
#
# ADDITIVE ONLY. A tree that already has a local project setup is left exactly
# as the operator left it: no rename, no re-point, no removal. Only a tree Orca
# does not know about is registered. That is the same contract the garden
# reconciler states, and it is what makes Orca's Electron-held registry an
# acceptable home for this state.
#
# RUNTIME. The CLI needs a reachable runtime. An already-reachable one is used
# as-is and never restarted, because `orca-ide serve` refuses to start while the
# desktop app holds the userData single-instance lock and raises that window as
# a side effect — so a running app with an unreachable runtime is a hard failure
# here, never a reason to call serve. Only when no app and no runtime are up
# does this script start one, and then it stops exactly the process it started.

# Environment overrides exist for the CI stub. Apply-time callers set none of
# them and get the real paths.
orca_register_cli() {
  if [ -n "${ORCA_REGISTER_CLI:-}" ]; then
    printf '%s\n' "$ORCA_REGISTER_CLI"
    return 0
  fi
  orca_home_cli=${ORCA_REGISTER_HOME_CLI:-$HOME/.local/bin/orca-ide}
  orca_rpm_cli=${ORCA_REGISTER_RPM_CLI:-/opt/Orca/resources/bin/orca-ide}
  if [ -x "$orca_home_cli" ]; then
    printf '%s\n' "$orca_home_cli"
    return 0
  fi
  # The home symlink is created by the application on first launch, so a host
  # that has never opened Orca does not have it. The RPM path always does.
  if [ -x "$orca_rpm_cli" ]; then
    printf '%s\n' "$orca_rpm_cli"
    return 0
  fi
  echo "orca-register: no executable Orca CLI at $orca_home_cli or $orca_rpm_cli" >&2
  return 1
}

# The human-readable short form of a declared path: its last two segments.
# `github.com/hyperlapse122/dotfiles` gives "hyperlapse122 / dotfiles";
# `git.jpi.app/products/365flow/pacs-scp` gives "365flow / pacs-scp". Both come
# from the same declared path the identity derivation reads, so neither value is
# a second source of truth.
orca_register_display_name() {
  orca_dn_path=$1
  orca_dn_leaf=${orca_dn_path##*/}
  orca_dn_rest=${orca_dn_path%/*}
  if [ "$orca_dn_rest" = "$orca_dn_path" ] || [ -z "$orca_dn_rest" ]; then
    printf '%s\n' "$orca_dn_leaf"
    return 0
  fi
  orca_dn_parent=${orca_dn_rest##*/}
  printf '%s / %s\n' "$orca_dn_parent" "$orca_dn_leaf"
}

# Whitespace-insensitive lookups over the CLI's JSON. Deliberately not jq: this
# file must stay runnable in CI with no dependency beyond a POSIX shell, and
# every lookup here is an exact key/value match.
#
# TWO SPELLINGS, ON PURPOSE. `status --json` nests its answer as
# `app.running` / `runtime.reachable`, while the human-readable `status` prints
# the flat `appRunning` / `runtimeReachable`. Matching only the flat names — the
# ones the non-JSON output shows — silently reports every runtime as
# unreachable, which sends a host with a running desktop app down the start-serve
# path this file exists to avoid. Both spellings are accepted so neither output
# shape can reintroduce that.
orca_register_json_bool() {
  orca_jb_blob=$(printf '%s' "$1" | tr -d ' \n\t')
  shift
  for orca_jb_key in "$@"; do
    case "$orca_jb_blob" in
      *"\"$orca_jb_key\":true"*) return 0 ;;
    esac
  done
  return 1
}

orca_register_json_has_path() {
  printf '%s' "$1" | tr -d ' \n\t' | grep -qF "\"path\":\"$2\""
}

# The setup id of the entry whose path matches, or empty. The list is flattened
# to one entry per line first so a match cannot borrow a neighbour's id.
#
# The selector `project setup-update --setup` accepts is the setup's own `id`
# from `project setups` — verified against the CLI, which rejects the
# `<projectId>::<hostId>` form its own help example shows. The `[{,]` anchor is
# what keeps the match off the sibling `projectId` and `repoId` keys, whose
# names end in the same three characters.
orca_register_setup_id() {
  printf '%s' "$1" | tr -d ' \n\t' | tr '{' '\n,' | grep -F "\"path\":\"$2\"" |
    sed 's/^/,/' | grep -o ',"id":"[^"]*"' | head -n 1 |
    sed 's/^,"id":"//; s/"$//'
}

# Every endpoint the runtime advertises must be loopback. A runtime this script
# started is one nobody is watching, so a listener reachable from the LAN is a
# failure rather than a warning.
orca_register_is_loopback_bound() {
  orca_lb_file=${ORCA_REGISTER_RUNTIME_FILE:-$HOME/.config/orca/orca-runtime.json}
  [ -f "$orca_lb_file" ] || return 1
  orca_lb_endpoints=$(tr -d ' \n\t' <"$orca_lb_file" |
    tr ',' '\n' | sed -n 's/.*"endpoint":"\([^"]*\)".*/\1/p')
  [ -n "$orca_lb_endpoints" ] || return 1
  printf '%s\n' "$orca_lb_endpoints" | while IFS= read -r orca_lb_ep; do
    case "$orca_lb_ep" in
      ws://127.0.0.1:*|ws://localhost:*|ws://\[::1\]:*|wss://127.0.0.1:*|wss://localhost:*|wss://\[::1\]:*) ;;
      /*) ;;
      *) exit 1 ;;
    esac
  done
}

orca_register_stop_started_runtime() {
  [ -n "${orca_started_pid:-}" ] || return 0
  kill "$orca_started_pid" 2>/dev/null || true
  wait "$orca_started_pid" 2>/dev/null || true
  orca_started_pid=
}

# Leaves the runtime reachable, or returns non-zero having explained why not.
orca_register_acquire_runtime() {
  orca_ar_cli=$1
  orca_ar_status=$("$orca_ar_cli" status --json 2>/dev/null || true)
  if orca_register_json_bool "$orca_ar_status" runtimeReachable reachable; then
    return 0
  fi
  if orca_register_json_bool "$orca_ar_status" appRunning running; then
    echo "orca-register: the Orca desktop app is running but its runtime is unreachable; not starting a second one" >&2
    return 1
  fi

  # `serve` is foreground-only, so it is backgrounded and stopped by the trap
  # the caller installed on EXIT INT TERM. --no-pairing keeps the run from
  # advertising a pairing surface it has no operator to accept.
  "$orca_ar_cli" serve --no-pairing >/dev/null 2>&1 &
  orca_started_pid=$!

  orca_ar_timeout=${ORCA_REGISTER_SERVE_TIMEOUT:-60}
  orca_ar_waited=0
  while [ "$orca_ar_waited" -lt "$orca_ar_timeout" ]; do
    orca_ar_status=$("$orca_ar_cli" status --json 2>/dev/null || true)
    if orca_register_json_bool "$orca_ar_status" runtimeReachable reachable; then
      if orca_register_is_loopback_bound; then
        return 0
      fi
      echo "orca-register: the runtime this apply started is not loopback-bound; refusing to register through it" >&2
      return 1
    fi
    sleep 1
    orca_ar_waited=$((orca_ar_waited + 1))
  done
  echo "orca-register: timeout after ${orca_ar_timeout}s waiting for the runtime this apply started" >&2
  return 1
}

# One tree. $1 cli, $2 name, $3 abspath, $4 relpath.
orca_register_tree() {
  orca_rt_cli=$1
  orca_rt_name=$2
  orca_rt_abspath=$3
  orca_rt_relpath=$4

  # Additive-only: a tree Orca already has a local setup for is finished.
  if orca_register_json_has_path "$orca_setups_snapshot" "$orca_rt_abspath"; then
    return 0
  fi

  # The repo may exist without a local setup — a half-finished earlier run, or
  # an operator who added the folder by hand. Adding it again is not idempotent,
  # so only the missing half is completed.
  if ! orca_register_json_has_path "$orca_repos_snapshot" "$orca_rt_abspath"; then
    if ! "$orca_rt_cli" repo add --path "$orca_rt_abspath" --json >/dev/null 2>&1; then
      echo "orca-register: '$orca_rt_name' failed at 'repo add' ($orca_rt_abspath)" >&2
      return 1
    fi
  fi

  orca_rt_setups=$("$orca_rt_cli" project setups --host local --json 2>/dev/null || true)
  orca_rt_setup_id=$(orca_register_setup_id "$orca_rt_setups" "$orca_rt_abspath")
  if [ -z "$orca_rt_setup_id" ]; then
    echo "orca-register: '$orca_rt_name' failed at 'project setups': no local setup for $orca_rt_abspath after adding it" >&2
    return 1
  fi

  orca_rt_display=$(orca_register_display_name "$orca_rt_relpath")
  orca_rt_base=${ORCA_REGISTER_WORKTREE_BASE:-$HOME/.local/share/worktrees}
  if ! "$orca_rt_cli" project setup-update --setup "$orca_rt_setup_id" \
    --display-name "$orca_rt_display" --worktree-base-path "$orca_rt_base" --json >/dev/null 2>&1; then
    echo "orca-register: '$orca_rt_name' failed at 'project setup-update' ($orca_rt_setup_id)" >&2
    return 1
  fi
}

# Reads `name<TAB>abspath<TAB>relpath<TAB>url` records on stdin. Records are
# buffered before the first CLI call so that an empty stream costs nothing —
# not a runtime, not a process.
orca_register_main() {
  orca_records=$(cat)
  [ -n "$orca_records" ] || return 0

  orca_cli=$(orca_register_cli) || return 1

  orca_started_pid=
  trap 'orca_register_stop_started_runtime' EXIT INT TERM
  orca_register_acquire_runtime "$orca_cli" || return 1

  # Read once. Later reads resolve a setup id for a tree just added; the skip
  # decision stays anchored to the state this run started from, so a tree
  # registered by this same run is never mistaken for one the operator had.
  orca_setups_snapshot=$("$orca_cli" project setups --host local --json 2>/dev/null || true)
  orca_repos_snapshot=$("$orca_cli" repo list --json 2>/dev/null || true)

  orca_rc=0
  orca_sep=$(printf '\t')
  while IFS="$orca_sep" read -r orca_name orca_abspath orca_relpath _orca_url; do
    [ -n "$orca_name" ] || continue
    orca_register_tree "$orca_cli" "$orca_name" "$orca_abspath" "$orca_relpath" || orca_rc=1
    [ "$orca_rc" -eq 0 ] || break
  done <<ORCA_RECORDS
$orca_records
ORCA_RECORDS

  orca_register_stop_started_runtime
  trap - EXIT INT TERM
  return "$orca_rc"
}

# Sourced by the CI test and by the apply script, which call orca_register_main
# themselves. Run directly, it reads records on stdin like the checker does.
if [ -z "${ORCA_REGISTER_SOURCED:-}" ]; then
  orca_register_main
fi
