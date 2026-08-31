#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cil_file="$repo_root/system/linux/etc/selinux/dotfiles_protected_agent_configs.cil"
script_tmpl="$repo_root/.chezmoiscripts/30-linux/run_after_selinux-policies.sh.tmpl"

fail() { printf 'test-selinux-protected-configs: %s\n' "$*" >&2; exit 1; }

[[ -f "$cil_file" ]] || fail "missing CIL policy file at $cil_file"
[[ -f "$script_tmpl" ]] || fail "missing script template at $script_tmpl"

for token in \
  "(type protected_agent_config_t)" \
  "(roletype object_r protected_agent_config_t)" \
  "(type chezmoi_t)" \
  "(roletype unconfined_r chezmoi_t)" \
  "(type chezmoi_exec_t)" \
  "(roletype object_r chezmoi_exec_t)" \
  "(typetransition unconfined_t chezmoi_exec_t process chezmoi_t)" \
  "(typeattributeset unconfined_domain_type (chezmoi_t))" \
  "(allow chezmoi_t protected_agent_config_t" \
  "(allow unconfined_t protected_agent_config_t" \
  "(filecon \"/home/[^/]+/\\.codex/config\\.toml\"" \
  "(filecon \"/home/[^/]+/\\.claude\\.json.*\"" \
  "(filecon \"/home/[^/]+/\\.mcp\\.json\"" \
  "(filecon \"/home/[^/]+/\\.claude/settings\\.json\"" \
  "(filecon \"/home/[^/]+/\\.codex/skills(/.*)?\"" \
  "(filecon \"/usr/bin/chezmoi\"" \
  "(filecon \"/home/[^/]+/\\.local/bin/chezmoi\""; do
  grep -qF -- "$token" "$cil_file" || fail "CIL policy missing expected declaration: $token"
done

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

grep -qF "semodule -X 400 -i" "$rendered" || fail "rendered script missing semodule invocation"
grep -qF "restorecon -RFv" "$rendered" || fail "rendered script missing restorecon invocation"

printf 'test-selinux-protected-configs: all assertions passed.\n'
