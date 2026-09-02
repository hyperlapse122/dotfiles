#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cil_file="$repo_root/system/linux/selinux/dotfiles_protected_agent_configs.cil"
tokscale_cil="$repo_root/system/linux/selinux/dotfiles_tokscale_gemini_access.cil"
script_tmpl="$repo_root/.chezmoiscripts/30-linux/run_onchange_after_selinux-policies.sh.tmpl"

fail() { printf 'test-selinux-protected-configs: %s\n' "$*" >&2; exit 1; }

[[ -f "$cil_file" ]] || fail "missing CIL policy file at $cil_file"
[[ ! -f "$tokscale_cil" ]] || fail "tokscale CIL policy file should be removed at $tokscale_cil"
[[ -f "$script_tmpl" ]] || fail "missing script template at $script_tmpl"

# --- declarations the module must carry ------------------------------------ #

for token in \
  "(type protected_agent_config_t)" \
  "(type claude_config_t)" \
  "(type gemini_config_t)" \
  "(roletype object_r protected_agent_config_t)" \
  "(typeattributeset protected_agent_config_type (protected_agent_config_t claude_config_t gemini_config_t))" \
  "(type chezmoi_t)" \
  "(type claude_t)" \
  "(type agy_t)" \
  "(roletype unconfined_r chezmoi_t)" \
  "(roletype unconfined_r claude_t)" \
  "(roletype unconfined_r agy_t)" \
  "(type chezmoi_exec_t)" \
  "(type claude_exec_t)" \
  "(type agy_exec_t)" \
  "(typeattributeset dotfiles_agent_domain (chezmoi_t claude_t agy_t))" \
  "(typeattributeset dotfiles_agent_exec (chezmoi_exec_t claude_exec_t agy_exec_t))" \
  "(typeattributeset file_type (dotfiles_agent_exec))" \
  "(typeattributeset exec_type (dotfiles_agent_exec))" \
  "(typetransition unconfined_domain_type chezmoi_exec_t process chezmoi_t)" \
  "(typetransition unconfined_domain_type claude_exec_t process claude_t)" \
  "(typetransition unconfined_domain_type agy_exec_t process agy_t)" \
  "(allow chezmoi_t chezmoi_exec_t (file (entrypoint" \
  "(allow claude_t claude_exec_t (file (entrypoint" \
  "(allow agy_t agy_exec_t (file (entrypoint" \
  "(typeattributeset domain (dotfiles_agent_domain))" \
  "(typeattributeset unconfined_domain_type (dotfiles_agent_domain))" \
  "(typeattributeset files_unconfined_type (dotfiles_agent_domain))" \
  "(allow chezmoi_t protected_agent_config_type" \
  "(allow claude_t claude_config_t" \
  "(allow agy_t gemini_config_t" \
  "(allow unconfined_domain_type protected_agent_config_type" \
  "(allow protected_agent_config_type fs_t (filesystem (associate)))" \
  "(allow protected_agent_config_type tmpfs_t (filesystem (associate)))" \
  "(allow protected_agent_config_type noxattrfs (filesystem (associate)))" \
  "(typetransition claude_t user_home_t file \".claude.json\" claude_config_t)" \
  "(typetransition claude_t user_home_t file \".mcp.json\" claude_config_t)" \
  "(filecon \"HOME_DIR/\\.codex/config\\.toml\"" \
  "(filecon \"HOME_DIR/\\.codex/skills(/.*)?\"" \
  "(filecon \"HOME_DIR/\\.agents/skills(/.*)?\"" \
  "(filecon \"HOME_DIR/\\.agents/plugins(/.*)?\"" \
  "(filecon \"HOME_DIR/\\.claude\\.json.*\" file (unconfined_u object_r claude_config_t" \
  "(filecon \"HOME_DIR/\\.mcp\\.json\" file (unconfined_u object_r claude_config_t" \
  "(filecon \"HOME_DIR/\\.claude/settings\\.json\" file (unconfined_u object_r claude_config_t" \
  "(filecon \"HOME_DIR/\\.claude/skills\" symlink (unconfined_u object_r claude_config_t" \
  "(filecon \"HOME_DIR/\\.claude/plugins/installed_plugins\\.json\" file (unconfined_u object_r claude_config_t" \
  "(filecon \"HOME_DIR/\\.claude/plugins/known_marketplaces\\.json\" file (unconfined_u object_r claude_config_t" \
  "(filecon \"HOME_DIR/\\.claude/plugins/marketplaces(/.*)?\" any (unconfined_u object_r claude_config_t" \
  "(filecon \"HOME_DIR/\\.gemini/config(/.*)?\" any (unconfined_u object_r gemini_config_t" \
  "(filecon \"HOME_DIR/\\.gemini/skills\" symlink (unconfined_u object_r gemini_config_t" \
  "(filecon \"/usr/bin/chezmoi\"" \
  "(filecon \"HOME_DIR/\\.local/bin/chezmoi\"" \
  "(filecon \"HOME_DIR/\\.local/lib/commands/store/claude/[^/]+/claude\" file (unconfined_u object_r claude_exec_t" \
  "(filecon \"HOME_DIR/\\.local/lib/commands/store/agy/[^/]+/agy\" file (unconfined_u object_r agy_exec_t"; do
  grep -qF -- "$token" "$cil_file" || fail "CIL policy missing expected declaration: $token"
done

# The whole-tree specs must NEVER return: they leak claude_config_t into the global Bun cache
# and break package manager hardlinks across user projects.
if grep -qE 'filecon "HOME_DIR/\\\.claude\(/\.\*\)\?"' "$cil_file"; then
  fail 'CIL policy must not claim whole ~/.claude tree: causes hardlink leaks into ~/.bun/install/cache'
fi
if grep -qE 'filecon "HOME_DIR/\\\.gemini\(/\.\*\)\?"' "$cil_file"; then
  fail 'CIL policy must not claim whole ~/.gemini tree: runtime sqlite databases belong on user_home_t'
fi

# An upgrade writes the binary into a directory restorecon has never seen, and a
# new file inherits its parent's type. The version-agnostic filecon only helps
# once restorecon runs, and restorecon runs when the POLICY changes — not when
# the harness does. These named transitions label the replacement at creation
# time, so losing them silently reverts every harness to unconfined_t on its
# next upgrade.
for token in \
  "(typetransition chezmoi_t gconf_home_t file \"claude\" claude_exec_t)" \
  "(typetransition chezmoi_t gconf_home_t file \"agy\" agy_exec_t)"; do
  grep -qF -- "$token" "$cil_file" || fail "CIL policy missing upgrade-durability transition: $token"
done

# --- the boundary itself: who may NOT write what --------------------------- #
#
# The split is only worth having if each harness is confined to its own tree and
# no user domain can write any of the three types. These are text assertions on
# the module, which is the whole allow-set for these types: nothing outside it
# grants access to a type the base policy has never heard of.

forbidden_writer() {
  local domain=$1 target=$2
  if grep -qE "^\(allow ${domain} ${target} " "$cil_file"; then
    fail "$domain must not be granted any access to $target"
  fi
}
forbidden_writer 'claude_t' 'gemini_config_t'
forbidden_writer 'claude_t' 'protected_agent_config_t'
forbidden_writer 'agy_t' 'claude_config_t'
forbidden_writer 'agy_t' 'protected_agent_config_t'

if grep -qF "tokscale_t" "$cil_file"; then
  fail "tokscale_t must not be declared in base CIL policy"
fi

# THE load-bearing assertion. Fedora's base policy ships
#   allow files_unconfined_type file_type:file { ... write create unlink ... };
# and unconfined_t holds files_unconfined_type, so a protected type that joins
# file_type is writable by every unconfined process and the read-only rule below
# it becomes decorative. An earlier revision of this module shipped exactly that
# and enforced nothing. The three protected types must carry NO attribute other
# than the module's own grouping attribute.
for protected in protected_agent_config_t claude_config_t gemini_config_t protected_agent_config_type; do
  if grep -qE "^\(typeattributeset (file_type|exec_type|domain|[a-z_]*unconfined[a-z_]*) \(${protected}\)" "$cil_file"; then
    fail "$protected must not join a base-policy attribute: that grants every unconfined domain write access"
  fi
done
if grep -qE '^\(typeattributeset [a-z_]+ \(.*\b(protected_agent_config_t|claude_config_t|gemini_config_t)\b.*\)\)' "$cil_file" |
  grep -qv 'protected_agent_config_type'; then
  fail 'a protected type was added to an attribute other than protected_agent_config_type'
fi

# The one rule every non-chezmoi domain does get must stay read-only.
while IFS= read -r line; do
  for verb in create write setattr unlink rename append add_name remove_name rmdir reparent relabelto relabelfrom; do
    case $line in
      *" $verb "* | *" $verb)"*)
        fail "read-only grant to unconfined_domain_type carries $verb: $line"
        ;;
    esac
  done
done < <(grep -E '^\(allow unconfined_domain_type protected_agent_config_type ' "$cil_file")

[[ $(grep -cE '^\(allow unconfined_domain_type protected_agent_config_type ' "$cil_file") -eq 3 ]] ||
  fail 'expected exactly one read-only grant per object class for unconfined_domain_type'

grep -qF -- "secilc" "$repo_root/.chezmoiscripts/30-components/run_onchange_before_80-devtools.sh.tmpl" || fail "devtools missing secilc package"
scratch=$(mktemp -d "${TMPDIR:-/tmp}/selinux-test.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT

mkdir -p "$scratch/bin" "$scratch/target"
printf '#!/usr/bin/env bash\nprintf dummy-secret;\n' > "$scratch/bin/op"
chmod 700 "$scratch/bin/op"
printf '[data]\n' > "$scratch/empty.toml"

rendered="$scratch/rendered.sh"
# The script template is gated on Fedora, so it renders to nothing on the ubuntu
# runner this test executes on and every assertion below would have nothing to
# read. Injecting the platform is the repo's established shape for exercising a
# host-gated template off-host (see test-fedora-fact-block-baseline.sh).
env PATH="$scratch/bin:$PATH" chezmoi --config "$scratch/empty.toml" \
  --source "$repo_root" --destination "$scratch/target" \
  --override-data '{"chezmoi":{"os":"linux","arch":"amd64","username":"fedora-fixture","osRelease":{"id":"fedora"}}}' \
  execute-template < "$script_tmpl" > "$rendered"

[[ -s "$rendered" ]] || fail "rendered script is empty"
bash -n "$rendered" || fail "rendered script failed bash syntax check"

grep -qF "semodule -X 400 -i" "$rendered" || fail "rendered script missing semodule invocation"
grep -qF "restorecon -RFv" "$rendered" || fail "rendered script missing restorecon invocation"

# A filecon nobody relabels is a label that never lands: every root the module
# declares must appear in the relabel list, including the entrypoint stores.
for relabel_path in \
  '"$HOME/.codex/config.toml"' \
  '"$HOME/.codex/skills"' \
  '"$HOME/.agents/skills"' \
  '"$HOME/.agents/plugins"' \
  '"$HOME/.claude.json"*' \
  '"$HOME/.mcp.json"' \
  '"$HOME/.claude/settings.json"' \
  '"$HOME/.claude/skills"' \
  '"$HOME/.claude/plugins/installed_plugins.json"' \
  '"$HOME/.claude/plugins/known_marketplaces.json"' \
  '"$HOME/.claude/plugins/marketplaces"' \
  '"$HOME/.gemini/config"' \
  '"$HOME/.gemini/skills"' \
  '"$HOME/.local/bin/chezmoi"' \
  '"$HOME/.local/bin/claude"' \
  '"$HOME/.local/bin/agy"' \
  '"$HOME/.local/lib/commands/store/claude"' \
  '"$HOME/.local/lib/commands/store/agy"'; do
  grep -qF -- "$relabel_path" "$rendered" || fail "rendered script does not relabel $relabel_path"
done

# The script MUST NOT relabel whole ~/.claude or ~/.gemini roots recursively.
if grep -qE '"\$HOME/\.claude"\b' "$rendered"; then
  fail 'rendered script must not pass recursive "$HOME/.claude" root to restorecon'
fi
if grep -qE '"\$HOME/\.gemini"\b' "$rendered"; then
  fail 'rendered script must not pass recursive "$HOME/.gemini" root to restorecon'
fi

# A policy change strands every agent session that is already running: SELinux
# assigns the domain at exec, so the old process keeps unconfined_t while its
# files have just been relabelled, and its writes start failing with EACCES.
# The script has to say so, because nothing else will.
grep -qF 'Restart any claude/agy process started earlier' "$rendered" ||
  fail 'rendered script does not tell the operator to restart running agent sessions'

# The warning is only actionable if it names the processes: a generic notice
# leaves the operator guessing which of several terminals holds the stale
# session. Assert the detection itself, not just the sentence.
grep -qF "pgrep -x -u \"\$(id -u)\" 'claude|agy'" "$rendered" ||
  fail 'rendered script does not enumerate domain-owning claude and agy processes'
grep -qF '/attr/current' "$rendered" ||
  fail 'rendered script does not read the domain of running agent processes'
grep -qF '*:claude_t:* | *:agy_t:* | *:chezmoi_t:*' "$rendered" ||
  fail 'rendered script does not treat an already-transitioned process as healthy'

if command -v secilc >/dev/null 2>&1; then
  base_stub="$scratch/base_stub.cil"
  cat <<'EOF' > "$base_stub"
(role object_r)
(role unconfined_r)
(type unconfined_t)
(type user_devpts_t)
(type user_home_t)
(type gconf_home_t)
(type data_home_t)
(type fs_t)
(type tmp_t)
(type tmpfs_t)
(type hugetlbfs_t)
(typeattribute noxattrfs)
(typeattribute file_type)
(typeattribute exec_type)
(typeattributeset file_type (user_home_t))
(typeattribute domain)
(typeattribute application_domain_type)
(typeattribute unconfined_domain_type)
(typeattributeset unconfined_domain_type (unconfined_t))
(typeattribute can_change_object_identity)
(typeattribute can_load_kernmodule)
(typeattribute can_load_policy)
(typeattribute can_read_shadow_passwords)
(typeattribute can_relabelto_binary_policy)
(typeattribute can_relabelto_shadow_passwords)
(typeattribute can_setbool)
(typeattribute can_setenforce)
(typeattribute can_setsecparam)
(typeattribute can_write_shadow_passwords)
(typeattribute corenet_unconfined_type)
(typeattribute corenet_unlabeled_type)
(typeattribute dbusd_unconfined)
(typeattribute devices_unconfined_type)
(typeattribute files_unconfined_type)
(typeattribute filesystem_unconfined_type)
(typeattribute initrc_transition_domain)
(typeattribute kern_unconfined)
(typeattribute kernel_system_state_reader)
(typeattribute named_filetrans_domain)
(typeattribute netlabel_peer_type)
(typeattribute nsswitch_domain)
(typeattribute process_uncond_exempt)
(typeattribute selinux_unconfined_type)
(typeattribute sepgsql_unconfined_type)
(typeattribute storage_unconfined_type)
(typeattribute syslog_client_type)
(typeattribute userdom_filetrans_type)
(typeattribute userdomain)
(typeattribute x_domain)
(typeattribute xserver_unconfined_type)
(class file (create read write getattr setattr unlink rename open append lock map ioctl link watch watch_reads entrypoint execute execute_no_trans relabelto relabelfrom))
(class dir (create read write getattr setattr unlink rename open search add_name remove_name reparent rmdir lock ioctl watch watch_reads relabelto relabelfrom))
(class lnk_file (create read getattr setattr unlink rename relabelto relabelfrom))
(class process (transition sigchld signull sigkill sigstop signal siginh fork getattr getsched setsched execmem getsession getpgid setpgid setrlimit))
(class fd (use))
(class chr_file (read write ioctl getattr append open))
(class filesystem (associate))
(classorder (file dir lnk_file process fd chr_file filesystem))
; The associate grant file_type confers in the real policy, reproduced so the
; fixture answers the same question the kernel does.
(allow file_type fs_t (filesystem (associate)))
(sid kernel)
(sidorder (kernel))
(user unconfined_u)
(user system_u)
(userrole unconfined_u object_r)
(userrole unconfined_u unconfined_r)
(userrole system_u object_r)
(userrole system_u unconfined_r)
(sensitivity s0)
(sensitivityorder (s0))
(userlevel unconfined_u (s0))
(userrange unconfined_u ((s0)(s0)))
(userlevel system_u (s0))
(userrange system_u ((s0)(s0)))
(sidcontext kernel (system_u object_r user_devpts_t ((s0)(s0))))
; The base-policy grant this module has to survive: every unconfined domain may
; write ANY file_type object. Reproduced here so the compiled fixture answers the
; question the module actually depends on.
(typeattributeset files_unconfined_type (unconfined_t))
(allow files_unconfined_type file_type (file (create read write getattr setattr unlink rename open append lock map ioctl link watch watch_reads execute execute_no_trans relabelto relabelfrom)))
(allow files_unconfined_type file_type (dir (create read write getattr setattr unlink rename open search add_name remove_name reparent rmdir lock ioctl watch watch_reads relabelto relabelfrom)))
(allow files_unconfined_type file_type (lnk_file (create read getattr setattr unlink rename relabelto relabelfrom)))
EOF
  secilc -N -o "$scratch/policy" -f "$scratch/file_contexts" "$base_stub" "$cil_file" ||
    fail "secilc failed to compile the CIL policy module"

  # The compiled file_contexts is the artifact restorecon consumes, so assert the
  # split there rather than only in the source text.
  # Compared in bash, not awk: an awk -v assignment resolves escape sequences,
  # so a spec like HOME_DIR/\.claude(/.*)? would arrive with its backslash gone
  # and match nothing.
  expect_context() {
    local spec=$1 want=$2 got='' line
    while IFS= read -r line; do
      [[ ${line%%$'\t'*} == "$spec" ]] || continue
      got=${line##*$'\t'}
      break
    done < "$scratch/file_contexts"
    [[ $got == "$want" ]] || fail "file_contexts maps $spec to ${got:-<nothing>}, expected $want"
  }
  expect_context 'HOME_DIR/\.claude/settings\.json' 'unconfined_u:object_r:claude_config_t'
  expect_context 'HOME_DIR/\.claude/skills' 'unconfined_u:object_r:claude_config_t'
  expect_context 'HOME_DIR/\.claude/plugins/installed_plugins\.json' 'unconfined_u:object_r:claude_config_t'
  expect_context 'HOME_DIR/\.claude/plugins/known_marketplaces\.json' 'unconfined_u:object_r:claude_config_t'
  expect_context 'HOME_DIR/\.claude/plugins/marketplaces(/.*)?' 'unconfined_u:object_r:claude_config_t'
  expect_context 'HOME_DIR/\.gemini/config(/.*)?' 'unconfined_u:object_r:gemini_config_t'
  expect_context 'HOME_DIR/\.gemini/skills' 'unconfined_u:object_r:gemini_config_t'
  expect_context 'HOME_DIR/\.mcp\.json' 'unconfined_u:object_r:claude_config_t'
  expect_context 'HOME_DIR/\.agents/skills(/.*)?' 'unconfined_u:object_r:protected_agent_config_t'

  # The strongest proof available offline: ask the COMPILED policy who may write
  # what. The stub reproduces Fedora's blanket files_unconfined_type grant, so a
  # protected type that regained file_type shows up here as an unconfined_t
  # write. Skipped where python3-setools is absent (CI runners); the text
  # assertions above still hold there.
  selinux_python=''
  for candidate in /usr/bin/python3 python3; do
    command -v "$candidate" >/dev/null 2>&1 || continue
    if "$candidate" -c 'import setools' >/dev/null 2>&1; then
      selinux_python=$candidate
      break
    fi
  done
  if [[ -n $selinux_python ]]; then
    policy_check="$scratch/policy_check.py"
    cat <<'SETOOLS' > "$policy_check"
import sys
import setools

policy = setools.SELinuxPolicy(sys.argv[1])
MUTATING = {'write', 'create', 'unlink', 'rename', 'setattr', 'append'}
EXPECTED = {
    ('chezmoi_t', 'protected_agent_config_t'): True,
    ('chezmoi_t', 'claude_config_t'): True,
    ('chezmoi_t', 'gemini_config_t'): True,
    ('claude_t', 'claude_config_t'): True,
    ('claude_t', 'gemini_config_t'): False,
    ('claude_t', 'protected_agent_config_t'): False,
    ('agy_t', 'gemini_config_t'): True,
    ('agy_t', 'claude_config_t'): False,
    ('agy_t', 'protected_agent_config_t'): False,
    ('unconfined_t', 'protected_agent_config_t'): False,
    ('unconfined_t', 'claude_config_t'): False,
    ('unconfined_t', 'gemini_config_t'): False,
}


def may_mutate(source, target):
    query = setools.TERuleQuery(policy, source=source, target=target, tclass=['file'])
    for rule in query.results():
        if str(rule.ruletype) != 'allow':
            continue
        if MUTATING & {str(perm) for perm in rule.perms}:
            return True
    return False


def may_associate(label):
    query = setools.TERuleQuery(policy, source=label, target='fs_t', tclass=['filesystem'])
    for rule in query.results():
        if str(rule.ruletype) != 'allow':
            continue
        if 'associate' in {str(perm) for perm in rule.perms}:
            return True
    return False


failures = []
for (source, target), want in sorted(EXPECTED.items()):
    got = may_mutate(source, target)
    if got != want:
        verb = 'may' if got else 'may not'
        failures.append(f'{source} {verb} write {target}, expected the opposite')
# A label that cannot associate with the filesystem cannot be set at all:
# restorecon fails with `avc: denied { associate } ... tcontext=...:fs_t`.
for label in ('protected_agent_config_t', 'claude_config_t', 'gemini_config_t'):
    if not may_associate(label):
        failures.append(f'{label} may not associate with fs_t, so restorecon cannot label it')
for line in failures:
    print(f'test-selinux-protected-configs: {line}', file=sys.stderr)
sys.exit(1 if failures else 0)
SETOOLS

    "$selinux_python" "$policy_check" "$scratch/policy" ||
      fail 'compiled policy does not enforce the declared write boundary'
    printf 'test-selinux-protected-configs: compiled-policy write boundary verified.\n'

    # A check that passes is only worth anything if it would fail on the defect it
    # exists for. The module shipped until 2026-09-02 carried
    # (typeattributeset file_type (protected_agent_config_t)), and Fedora's base
    # policy lets every unconfined domain write any file_type object, so the
    # read-only rule beside it granted nothing back and denied nothing. Rebuild
    # that exact defect and require the check above to catch it.
    mutant_cil="$scratch/mutant.cil"
    {
      cat -- "$cil_file"
      printf '\n(typeattributeset file_type (protected_agent_config_t))\n'
    } > "$mutant_cil"
    secilc -N -o "$scratch/policy_mutant" -f "$scratch/file_contexts_mutant" \
      "$base_stub" "$mutant_cil" ||
      fail 'secilc failed to compile the mutant CIL policy'

    mutant_report="$scratch/mutant_report"
    if "$selinux_python" "$policy_check" "$scratch/policy_mutant" >"$mutant_report" 2>&1; then
      fail 'the write-boundary check accepts a policy that regained file_type on protected_agent_config_t; it no longer detects the defect it exists for'
    fi
    # Fail for the right reason, not merely fail: any compile or query error would
    # also exit non-zero and would prove nothing about the boundary.
    grep -qF 'unconfined_t may write protected_agent_config_t' "$mutant_report" ||
      fail "mutant policy was rejected for the wrong reason: $(tr '\n' ';' <"$mutant_report")"
    printf 'test-selinux-protected-configs: write boundary proven against the file_type regression.\n'
  fi
fi

printf 'test-selinux-protected-configs: all assertions passed.\n'
