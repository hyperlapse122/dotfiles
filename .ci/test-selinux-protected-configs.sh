#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cil_file="$repo_root/system/linux/selinux/dotfiles_protected_agent_configs.cil"
script_tmpl="$repo_root/.chezmoiscripts/30-linux/run_onchange_after_selinux-policies.sh.tmpl"

fail() { printf 'test-selinux-protected-configs: %s\n' "$*" >&2; exit 1; }

[[ -f "$cil_file" ]] || fail "missing CIL policy file at $cil_file"
[[ -f "$script_tmpl" ]] || fail "missing script template at $script_tmpl"

for token in \
  "(type protected_agent_config_t)" \
  "(roletype object_r protected_agent_config_t)" \
  "(typeattributeset file_type (protected_agent_config_t))" \
  "(type chezmoi_t)" \
  "(roletype unconfined_r chezmoi_t)" \
  "(type chezmoi_exec_t)" \
  "(roletype object_r chezmoi_exec_t)" \
  "(typeattributeset file_type (chezmoi_exec_t))" \
  "(typeattributeset exec_type (chezmoi_exec_t))" \
  "(typetransition unconfined_t chezmoi_exec_t process chezmoi_t)" \
  "(typeattributeset domain (chezmoi_t))" \
  "(typeattributeset unconfined_domain_type (chezmoi_t))" \
  "(typeattributeset files_unconfined_type (chezmoi_t))" \
  "(allow chezmoi_t protected_agent_config_t" \
  "(allow unconfined_t protected_agent_config_t" \
  "(filecon \"HOME_DIR/\\.codex/config\\.toml\"" \
  "(filecon \"HOME_DIR/\\.claude\\.json.*\"" \
  "(filecon \"HOME_DIR/\\.mcp\\.json\"" \
  "(filecon \"HOME_DIR/\\.claude/settings\\.json\"" \
  "(filecon \"HOME_DIR/\\.claude/skills\"" \
  "(filecon \"HOME_DIR/\\.gemini/antigravity-cli/mcp\\.json\"" \
  "(filecon \"HOME_DIR/\\.gemini/config/mcp_config\\.json\"" \
  "(filecon \"HOME_DIR/\\.gemini/skills\"" \
  "(filecon \"HOME_DIR/\\.agents/skills(/.*)?\"" \
  "(filecon \"HOME_DIR/\\.agents/plugins(/.*)?\"" \
  "(filecon \"HOME_DIR/\\.codex/skills(/.*)?\"" \
  "(filecon \"/usr/bin/chezmoi\"" \
  "(filecon \"HOME_DIR/\\.local/bin/chezmoi\""; do
  grep -qF -- "$token" "$cil_file" || fail "CIL policy missing expected declaration: $token"
done

grep -qF -- "secilc" "$repo_root/.chezmoiscripts/30-components/run_onchange_before_80-devtools.sh.tmpl" || fail "devtools missing secilc package"
scratch=$(mktemp -d "${TMPDIR:-/tmp}/selinux-test.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT

mkdir -p "$scratch/bin" "$scratch/target"
printf '#!/usr/bin/env bash\nprintf dummy-secret;\n' > "$scratch/bin/op"
chmod 700 "$scratch/bin/op"
printf '[data]\n' > "$scratch/empty.toml"

rendered="$scratch/rendered.sh"
env PATH="$scratch/bin:$PATH" chezmoi --config "$scratch/empty.toml" \
  --source "$repo_root" --destination "$scratch/target" \
  execute-template < "$script_tmpl" > "$rendered"

[[ -s "$rendered" ]] || fail "rendered script is empty"
bash -n "$rendered" || fail "rendered script failed bash syntax check"

grep -qF "semodule -X 400 -i" "$rendered" || fail "rendered script missing semodule invocation"
grep -qF "restorecon -RFv" "$rendered" || fail "rendered script missing restorecon invocation"
if command -v secilc >/dev/null 2>&1; then
  base_stub="$scratch/base_stub.cil"
  cat <<'EOF' > "$base_stub"
(role object_r)
(role unconfined_r)
(type unconfined_t)
(type user_devpts_t)
(typeattribute file_type)
(typeattribute exec_type)
(typeattribute domain)
(typeattribute application_domain_type)
(typeattribute unconfined_domain_type)
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
(class file (create read write getattr setattr unlink rename open append lock map entrypoint execute relabelto relabelfrom))
(class dir (create read write getattr setattr unlink rename open search add_name remove_name reparent rmdir lock relabelto relabelfrom))
(class lnk_file (create read getattr setattr unlink rename relabelto relabelfrom))
(class process (transition sigchld signull sigkill sigstop signal siginh fork getattr getsched setsched execmem getsession getpgid setpgid setrlimit))
(class fd (use))
(class chr_file (read write ioctl getattr append open))
(classorder (file dir lnk_file process fd chr_file))
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
EOF
  secilc -N -o "$scratch/policy" -f "$scratch/file_contexts" "$base_stub" "$cil_file" || fail "secilc failed to compile CIL policy"
fi

printf 'test-selinux-protected-configs: all assertions passed.\n'
