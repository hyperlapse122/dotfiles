#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
fail() { printf 'omp transition: %s\n' "$*" >&2; exit 1; }
chezmoi_bin=$(type -P chezmoi)
source "$repo_root/.ci/lib/render-scratch.sh"
source "$repo_root/.ci/lib/render-gate-helpers.sh"
# shellcheck source=.ci/lib/source-root.sh
source "$repo_root/.ci/lib/source-root.sh"
source_root=$(resolve_source_root "$repo_root")
setup_render_scratch omp-transition
mkdir -p "$scratch/home/.local/bin"

render "$repo_root" "$scratch" "$chezmoi_bin" linux "$source_root/.chezmoiremove" "$scratch/remove"
! grep -Fxq '.local/bin/agy' "$scratch/remove" || fail 'absent public command was selected'
printf 'personal executable\n' >"$scratch/home/.local/bin/agy"
ln -s /personal/antigravity "$scratch/home/.local/bin/antigravity"
render "$repo_root" "$scratch" "$chezmoi_bin" linux "$source_root/.chezmoiremove" "$scratch/remove"
for command in agy antigravity; do
  ! grep -Fxq ".local/bin/$command" "$scratch/remove" || fail "unmanaged $command selected for removal"
done
rm "$scratch/home/.local/bin/agy" "$scratch/home/.local/bin/antigravity"
ln -s ../lib/commands/current/agy/agy "$scratch/home/.local/bin/agy"
ln -s "$scratch/home/.local/lib/commands/current/agy/agy" "$scratch/home/.local/bin/antigravity"
render "$repo_root" "$scratch" "$chezmoi_bin" linux "$source_root/.chezmoiremove" "$scratch/remove"
for command in agy antigravity; do
  grep -Fxq ".local/bin/$command" "$scratch/remove" || fail "managed $command not selected"
done
for preserved in .gemini .gemini/antigravity-cli .gemini/antigravity-cli/settings.json .gemini/antigravity-cli/mcp_oauth_tokens.json .omp .omp/agent/agent.db .local/share/compound-engineering; do
  ! grep -Fxq "$preserved" "$scratch/remove" || fail "personal or shared state selected: $preserved"
done

mkdir -p "$scratch/removal-source" "$scratch/home/.gemini/antigravity-cli" \
  "$scratch/home/.gemini/config/plugins/dotfiles-agy" "$scratch/home/.omp/agent" \
  "$scratch/home/.local/share/compound-engineering"
cp "$scratch/remove" "$scratch/removal-source/.chezmoiremove"
for preserved in .gemini/antigravity-cli/settings.json .gemini/antigravity-cli/mcp_oauth_tokens.json .gemini/antigravity-cli/history .omp/agent/agent.db .local/share/compound-engineering/sentinel; do
  printf 'personal sentinel\n' >"$scratch/home/$preserved"
done
printf 'managed instructions\n' >"$scratch/home/.gemini/AGENTS.md"
printf 'managed plugin\n' >"$scratch/home/.gemini/config/plugins/dotfiles-agy/plugin.json"
apply_removal() {
  env HOME="$scratch/home" PATH="$scratch/bin:/usr/bin:/bin" \
    "$chezmoi_bin" --config "$scratch/empty.toml" --source "$scratch/removal-source" \
    --destination "$scratch/home" apply --force
}
for pass in first repeat; do
  apply_removal
  [[ ! -e "$scratch/home/.gemini/AGENTS.md" && ! -e "$scratch/home/.gemini/config/plugins/dotfiles-agy" ]] || fail "$pass apply retained managed Antigravity files"
  [[ ! -L "$scratch/home/.local/bin/agy" && ! -L "$scratch/home/.local/bin/antigravity" ]] || fail "$pass apply retained managed command links"
  for preserved in .gemini/antigravity-cli/settings.json .gemini/antigravity-cli/mcp_oauth_tokens.json .gemini/antigravity-cli/history .omp/agent/agent.db .local/share/compound-engineering/sentinel; do
    [[ $(cat "$scratch/home/$preserved") == 'personal sentinel' ]] || fail "$pass apply changed $preserved"
  done
done

sidecar_paths=(
  .config/systemd/user/antigravity-sidecar.service
  .config/systemd/user/default.target.wants/antigravity-sidecar.service
  Library/LaunchAgents/app.dotfiles.antigravity-sidecar.plist
  .local/bin/antigravity-sidecar
  .local/lib/commands/current/antigravity-sidecar
  .local/lib/commands/store/antigravity-sidecar
  .local/lib/commands/quarantine/antigravity-sidecar
  .local/share/chezmoi-commands/incomplete/antigravity-sidecar
  .local/state/dotfiles-antigravity-sidecar
)

mkdir -p "$scratch/home/.config/systemd/user/default.target.wants" \
  "$scratch/home/Library/LaunchAgents" \
  "$scratch/home/.local/bin" \
  "$scratch/home/.local/lib/commands/current/antigravity-sidecar" \
  "$scratch/home/.local/lib/commands/store/antigravity-sidecar" \
  "$scratch/home/.local/lib/commands/quarantine/antigravity-sidecar" \
  "$scratch/home/.local/share/chezmoi-commands/incomplete/antigravity-sidecar" \
  "$scratch/home/.local/state/dotfiles-antigravity-sidecar" \
  "$scratch/home/.omp/agent"

printf '[Unit]\nDescription=antigravity-sidecar\n' >"$scratch/home/.config/systemd/user/antigravity-sidecar.service"
ln -s ../antigravity-sidecar.service "$scratch/home/.config/systemd/user/default.target.wants/antigravity-sidecar.service"
printf '<plist version="1.0"></plist>\n' >"$scratch/home/Library/LaunchAgents/app.dotfiles.antigravity-sidecar.plist"
ln -s ../lib/commands/current/antigravity-sidecar/antigravity-sidecar "$scratch/home/.local/bin/antigravity-sidecar"
printf 'generation binary\n' >"$scratch/home/.local/lib/commands/current/antigravity-sidecar/antigravity-sidecar"
printf 'store binary\n' >"$scratch/home/.local/lib/commands/store/antigravity-sidecar/artifact"
printf 'quarantine binary\n' >"$scratch/home/.local/lib/commands/quarantine/antigravity-sidecar/artifact"
printf 'incomplete build\n' >"$scratch/home/.local/share/chezmoi-commands/incomplete/antigravity-sidecar/build"
printf '1\n' >"$scratch/home/.local/state/dotfiles-antigravity-sidecar/service-revision"
printf 'providers:\n  google-antigravity:\n    baseUrl: http://127.0.0.1:45123\n' >"$scratch/home/.omp/agent/models.yml"

ln -s ../orca-settings-reconcile.service "$scratch/home/.config/systemd/user/default.target.wants/orca-settings-reconcile.service"
printf 'sibling binary\n' >"$scratch/home/.local/bin/sibling-bin"
printf 'sqlite db\n' >"$scratch/home/.omp/agent/agent.db"

assert_siblings_preserved() {
  local pass=$1 context=${2:-}
  local suffix=${context:+" $context"}
  [[ -L "$scratch/home/.config/systemd/user/default.target.wants/orca-settings-reconcile.service" ]] || fail "$pass apply removed sibling symlink$suffix"
  [[ -f "$scratch/home/.local/bin/sibling-bin" && $(cat "$scratch/home/.local/bin/sibling-bin") == 'sibling binary' ]] || fail "$pass apply removed sibling bin$suffix"
  [[ -f "$scratch/home/.omp/agent/agent.db" && $(cat "$scratch/home/.omp/agent/agent.db") == 'sqlite db' ]] || fail "$pass apply removed sibling agent.db$suffix"
}

for os in linux darwin; do
  render "$repo_root" "$scratch" "$chezmoi_bin" "$os" "$source_root/.chezmoiremove" "$scratch/remove-$os"
  for entry in "${sidecar_paths[@]}" .omp/agent/models.yml; do
    grep -Fxq "$entry" "$scratch/remove-$os" || fail "$os render missing prune entry: $entry"
  done
done

cp "$scratch/remove-linux" "$scratch/removal-source/.chezmoiremove"
for pass in first repeat; do
  apply_removal
  for path in "${sidecar_paths[@]}" .omp/agent/models.yml; do
    [[ ! -e "$scratch/home/$path" && ! -L "$scratch/home/$path" ]] || fail "$pass apply retained $path"
  done
  assert_siblings_preserved "$pass"
done

printf 'providers:\n  custom:\n    baseUrl: https://api.example.com\n' >"$scratch/home/.omp/agent/models.yml"
custom_content=$(cat "$scratch/home/.omp/agent/models.yml")
render "$repo_root" "$scratch" "$chezmoi_bin" linux "$source_root/.chezmoiremove" "$scratch/remove-custom-models"
! grep -Fxq '.omp/agent/models.yml' "$scratch/remove-custom-models" || fail 'custom models.yml selected for removal'

cp "$scratch/remove-custom-models" "$scratch/removal-source/.chezmoiremove"
for pass in first repeat; do
  apply_removal
  [[ -f "$scratch/home/.omp/agent/models.yml" ]] || fail "$pass apply removed custom models.yml"
  [[ $(cat "$scratch/home/.omp/agent/models.yml") == "$custom_content" ]] || fail "$pass apply changed custom models.yml"
done

rm -f "$scratch/home/.omp/agent/models.yml"
render "$repo_root" "$scratch" "$chezmoi_bin" linux "$source_root/.chezmoiremove" "$scratch/remove-no-models"
! grep -Fxq '.omp/agent/models.yml' "$scratch/remove-no-models" || fail 'absent models.yml selected for removal'

cp "$scratch/remove-no-models" "$scratch/removal-source/.chezmoiremove"
for pass in first repeat; do
  apply_removal || fail "$pass apply failed with no paths present"
  assert_siblings_preserved "$pass" "when paths absent"
done
printf 'omp transition: all cases passed\n'
