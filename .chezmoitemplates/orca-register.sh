# orca-register.sh — registers every declared ~/src tree into Orca, shared by
# the apply-time script .chezmoiscripts/90-src/run_after_register-orca.sh.tmpl
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
  return 2
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

# Takes an ALREADY-NORMALIZED blob: both snapshots are stripped once in
# orca_register_main rather than re-stripped for each of the declared trees.
orca_register_json_has_path() {
  printf '%s' "$1" | grep -qF "\"path\":\"$2\""
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
  printf '%s' "$1" | tr -d ' \n\t' | sed 's/},{/}\n{/g' | grep -F "\"path\":\"$2\"" |
    sed 's/{/,/g' | grep -o ',"id":"[^"]*"' | head -n 1 |
    sed 's/^,"id":"//; s/"$//'
}

# Every endpoint the runtime advertises must be loopback. A runtime this script
# started is one nobody is watching, so a listener reachable from the LAN is a
# failure rather than a warning.
# Returns 0 loopback-bound, 1 definitely not, 2 cannot tell yet (the runtime
# has not published its transports). Only 1 is a refusal; 2 keeps polling.
orca_register_is_loopback_bound() {
  orca_lb_file=${ORCA_REGISTER_RUNTIME_FILE:-$HOME/.config/orca/orca-runtime.json}
  [ -f "$orca_lb_file" ] || return 2
  orca_lb_endpoints=$(tr -d ' \n\t' <"$orca_lb_file" |
    tr ',' '\n' | sed -n 's/.*"endpoint":"\([^"]*\)".*/\1/p')
  [ -n "$orca_lb_endpoints" ] || return 2
  # Heredoc, not a pipe: a piped `while` runs in a subshell, where a failure
  # signal would only end the subshell. This loop guards a safety check, so its
  # refusal must survive any statement a later edit adds after it.
  while IFS= read -r orca_lb_ep; do
    case "$orca_lb_ep" in
      ws://127.0.0.1:*|ws://localhost:*|ws://\[::1\]:*|wss://127.0.0.1:*|wss://localhost:*|wss://\[::1\]:*) ;;
      /*) ;;
      *) return 1 ;;
    esac
  done <<ORCA_ENDPOINTS
$orca_lb_endpoints
ORCA_ENDPOINTS
  return 0
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
  if [ -z "$orca_ar_status" ]; then
    echo "orca-register: 'orca-ide status' returned nothing; refusing to start a runtime blind" >&2
    return 1
  fi
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
      orca_register_is_loopback_bound
      orca_lb_rc=$?
      if [ "$orca_lb_rc" -eq 0 ]; then
        return 0
      fi
      if [ "$orca_lb_rc" -eq 1 ]; then
        echo "orca-register: the runtime this apply started is not loopback-bound; refusing to register through it" >&2
        return 1
      fi
      # rc 2: transports not published yet — keep waiting inside the timeout.
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

  if ! orca_rt_setups=$("$orca_rt_cli" project setups --host local --json 2>&1); then
    echo "orca-register: '$orca_rt_name' failed at 'project setups': $orca_rt_setups" >&2
    return 1
  fi
  # `|| true`, because the lookup is a pipeline and a no-match is an ordinary
  # answer here: under the apply script's errexit+pipefail an unguarded
  # substitution would abort before the diagnostic below could name the tree.
  orca_rt_setup_id=$(orca_register_setup_id "$orca_rt_setups" "$orca_rt_abspath" || true)
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

# --- project groups ---------------------------------------------------------
#
# Orca does model project groups — `projectGroups` in its own state, with every
# repo carrying a `projectGroupId` — but its CLI exposes no command for them.
# The three operations exist only as runtime RPC methods (`projectGroup.list`,
# `projectGroup.create`, `projectGroup.moveProject`), which the desktop app and
# the CLI both reach through the same client module. So this step talks to the
# already-acquired runtime through that module instead of through a subcommand
# that does not exist.
#
# BEST EFFORT, UNLIKE REGISTRATION. That RPC surface is internal to Orca: an
# upgrade may rename it or move the module. Registration failing must fail the
# apply, because a host without its projects cannot be worked in; grouping
# failing must not, because it only changes how the sidebar arranges projects
# that are all already there. Every failure below warns and returns 0.
#
# ADDITIVE ONLY, on the same terms as registration: a group with the declared
# name is reused rather than recreated, and a repo the operator has already
# filed under some group is left where they put it.

# Resolves the Orca install from the CLI path, the way the vendor's own
# `bin/orca-ide` wrapper does: follow the symlink chain to the real script under
# <install>/resources/bin, then read the install root above it. Sets
# orca_install_node and orca_install_module, or returns non-zero.
orca_register_resolve_install() {
  orca_ri_src=$1

  orca_install_node=${ORCA_REGISTER_NODE:-}
  orca_install_module=${ORCA_REGISTER_RPC_MODULE:-}
  if [ -n "$orca_install_node" ] && [ -n "$orca_install_module" ]; then
    return 0
  fi

  # `readlink` without -f: the flag is a GNU extension, and this file runs
  # wherever the apply script does.
  orca_ri_guard=0
  while [ -h "$orca_ri_src" ] && [ "$orca_ri_guard" -lt 16 ]; do
    orca_ri_dir=$(cd -P "$(dirname "$orca_ri_src")" 2>/dev/null && pwd) || return 1
    orca_ri_src=$(readlink "$orca_ri_src") || return 1
    case $orca_ri_src in
      /*) ;;
      *) orca_ri_src="$orca_ri_dir/$orca_ri_src" ;;
    esac
    orca_ri_guard=$((orca_ri_guard + 1))
  done

  orca_ri_bin=$(cd -P "$(dirname "$orca_ri_src")" 2>/dev/null && pwd) || return 1
  orca_ri_resources=$(cd -P "$orca_ri_bin/.." 2>/dev/null && pwd) || return 1
  orca_ri_root=$(cd -P "$orca_ri_resources/.." 2>/dev/null && pwd) || return 1

  [ -n "$orca_install_module" ] ||
    orca_install_module="$orca_ri_resources/app.asar.unpacked/out/cli/runtime-client.js"
  [ -f "$orca_install_module" ] || return 1

  if [ -z "$orca_install_node" ]; then
    # The same candidate list the vendor wrapper carries: the Linux executable
    # is `orca-ide` because Ubuntu GNOME already ships an `orca`.
    for orca_ri_candidate in orca-ide orca Orca; do
      if [ -f "$orca_ri_root/$orca_ri_candidate" ] && [ -x "$orca_ri_root/$orca_ri_candidate" ]; then
        orca_install_node="$orca_ri_root/$orca_ri_candidate"
        break
      fi
    done
  fi
  [ -n "$orca_install_node" ] || return 1
}

# The reconciler itself, in JavaScript because it must read Orca's own JSON.
# The shell helpers above match exact key/value pairs in whitespace-stripped
# blobs, which a group name cannot survive: "ExamVue 365 Flow" carries the very
# spaces that stripping removes. Node is already on the host — it is the Orca
# binary in ELECTRON_RUN_AS_NODE mode — so the parse is done where a parser
# exists rather than approximated with sed.
orca_register_group_program() {
  cat <<'ORCA_GROUP_JS'
const { RuntimeClient } = require(process.env.ORCA_GROUP_MODULE);
const fs = require('node:fs');

const client = new RuntimeClient();

async function call(method, params) {
  const res = await client.call(method, params);
  if (res && res.ok === false) {
    throw new Error(method + ' failed: ' + JSON.stringify(res.error || null));
  }
  return (res && res.result) || {};
}

function records() {
  return fs
    .readFileSync(0, 'utf8')
    .split('\n')
    .filter((line) => line.includes('\t'))
    .map((line) => {
      const at = line.indexOf('\t');
      return { group: line.slice(0, at), path: line.slice(at + 1) };
    })
    .filter((r) => r.group && r.path);
}

async function main() {
  const wanted = records();
  if (wanted.length === 0) return;

  const groups = (await call('projectGroup.list', null)).groups || [];
  const repos = (await call('repo.list', null)).repos || [];

  const byName = new Map(groups.map((g) => [g.name, g]));
  const byPath = new Map(repos.map((r) => [r.path, r]));

  // Where the next project lands inside a group: past the last position already
  // taken there, so an operator's own ordering is appended to, not overwritten.
  // The highest order, not the member count — a group whose members were
  // reordered by hand has gaps, and counting would hand out a position that is
  // already occupied.
  const lastOrder = new Map();
  for (const repo of repos) {
    if (!repo.projectGroupId) continue;
    const at = typeof repo.projectGroupOrder === 'number' ? repo.projectGroupOrder : -1;
    const seen = lastOrder.has(repo.projectGroupId) ? lastOrder.get(repo.projectGroupId) : -1;
    lastOrder.set(repo.projectGroupId, Math.max(seen, at));
  }

  for (const want of wanted) {
    const repo = byPath.get(want.path);
    if (!repo) {
      console.warn("orca-register: no Orca project at " + want.path + "; not grouped");
      continue;
    }
    if (repo.projectGroupId) continue;

    let group = byName.get(want.group);
    if (!group) {
      group = (await call('projectGroup.create', { name: want.group, createdFrom: 'manual' })).group;
      byName.set(want.group, group);
    }

    const order = (lastOrder.has(group.id) ? lastOrder.get(group.id) : -1) + 1;
    await call('projectGroup.moveProject', { repo: repo.id, groupId: group.id, order });
    lastOrder.set(group.id, order);
    console.log("orca-register: grouped " + repo.displayName + " under '" + want.group + "'");
  }
}

main().catch((err) => {
  console.error('orca-register: ' + (err && err.message ? err.message : String(err)));
  process.exit(1);
});
ORCA_GROUP_JS
}

# Reads `group<TAB>abspath` records from ORCA_REGISTER_GROUP_RECORDS. Runs
# inside orca_register_main so it reuses the runtime that was acquired there.
orca_register_groups() {
  orca_gr_records=${ORCA_REGISTER_GROUP_RECORDS:-}
  [ -n "$orca_gr_records" ] || return 0

  if ! orca_register_resolve_install "$1"; then
    echo "orca-register: cannot locate the Orca runtime client module beside $1; projects are registered but not grouped" >&2
    return 0
  fi

  orca_gr_js=$(mktemp "${TMPDIR:-/tmp}/orca-group.XXXXXX") || return 0
  orca_register_group_program >"$orca_gr_js"

  orca_gr_out=$(printf '%s\n' "$orca_gr_records" |
    ORCA_GROUP_MODULE="$orca_install_module" ELECTRON_RUN_AS_NODE=1 \
      "$orca_install_node" "$orca_gr_js" 2>&1) || {
    echo "orca-register: project grouping failed; projects are registered but not grouped" >&2
    printf '%s\n' "$orca_gr_out" >&2
    rm -f "$orca_gr_js"
    return 0
  }
  rm -f "$orca_gr_js"
  [ -z "$orca_gr_out" ] || printf '%s\n' "$orca_gr_out"
}

# Reads `name<TAB>abspath<TAB>relpath<TAB>url` records on stdin. Records are
# buffered before the first CLI call so that an empty stream costs nothing —
# not a runtime, not a process.
orca_register_main() {
  orca_records=$(cat)
  [ -n "$orca_records" ] || return 0

  # A host with no Orca CLI is a host where Orca is not installed. This script
  # runs on every managed host and the desktop package is Fedora-only, so that
  # is a skip with a notice — failing the apply there would break provisioning
  # on every other platform for a tool that host does not have.
  # `|| orca_cli_rc=$?`, not a bare assignment: under errexit a substitution
  # that returns non-zero aborts the script before the status can be read.
  orca_cli_rc=0
  orca_cli=$(orca_register_cli) || orca_cli_rc=$?
  if [ "$orca_cli_rc" -eq 2 ]; then
    echo "orca-register: no Orca CLI on this host (${ORCA_REGISTER_HOME_CLI:-$HOME/.local/bin/orca-ide} or ${ORCA_REGISTER_RPM_CLI:-/opt/Orca/resources/bin/orca-ide}); skipping registration" >&2
    return 0
  fi
  [ "$orca_cli_rc" -eq 0 ] || return 1

  orca_started_pid=
  trap 'orca_register_stop_started_runtime' EXIT INT TERM
  orca_register_acquire_runtime "$orca_cli" || return 1

  # Read once. Later reads resolve a setup id for a tree just added; the skip
  # decision stays anchored to the state this run started from, so a tree
  # registered by this same run is never mistaken for one the operator had.
  # These two reads decide, for every tree, whether it is already Orca's. A
  # swallowed failure here reads as "Orca knows nothing" and would re-add every
  # declared tree — the additive-only contract inverted into its opposite. So
  # they abort with the CLI's own diagnostic instead of defaulting to empty.
  if ! orca_setups_snapshot=$("$orca_cli" project setups --host local --json 2>&1); then
    echo "orca-register: 'project setups' failed: $orca_setups_snapshot" >&2
    return 1
  fi
  if ! orca_repos_snapshot=$("$orca_cli" repo list --json 2>&1); then
    echo "orca-register: 'repo list' failed: $orca_repos_snapshot" >&2
    return 1
  fi
  orca_setups_snapshot=$(printf '%s' "$orca_setups_snapshot" | tr -d ' \n\t')
  orca_repos_snapshot=$(printf '%s' "$orca_repos_snapshot" | tr -d ' \n\t')

  orca_rc=0
  orca_sep=$(printf '\t')
  while IFS="$orca_sep" read -r orca_name orca_abspath orca_relpath _orca_url; do
    [ -n "$orca_name" ] || continue
    orca_register_tree "$orca_cli" "$orca_name" "$orca_abspath" "$orca_relpath" || orca_rc=1
    [ "$orca_rc" -eq 0 ] || break
  done <<ORCA_RECORDS
$orca_records
ORCA_RECORDS

  # Grouping runs only once every declared tree is registered, because it files
  # projects Orca must already know about, and only when registration succeeded,
  # because a half-registered host would be grouped half-way.
  [ "$orca_rc" -ne 0 ] || orca_register_groups "$orca_cli"

  orca_register_stop_started_runtime
  trap - EXIT INT TERM
  return "$orca_rc"
}

# Sourced by the CI test and by the apply script, which call orca_register_main
# themselves. Run directly, it reads records on stdin like the checker does.
if [ -z "${ORCA_REGISTER_SOURCED:-}" ]; then
  orca_register_main
fi
