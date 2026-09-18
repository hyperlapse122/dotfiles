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
mkdir -p "$scratch/home/.local/bin" "$scratch/home/.config/systemd/user" "$scratch/home/Library/LaunchAgents"

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
for pass in first repeat; do
  env HOME="$scratch/home" PATH="$scratch/bin:/usr/bin:/bin" \
    "$chezmoi_bin" --config "$scratch/empty.toml" --source "$scratch/removal-source" \
    --destination "$scratch/home" apply --force
  [[ ! -e "$scratch/home/.gemini/AGENTS.md" && ! -e "$scratch/home/.gemini/config/plugins/dotfiles-agy" ]] || fail "$pass apply retained managed Antigravity files"
  [[ ! -L "$scratch/home/.local/bin/agy" && ! -L "$scratch/home/.local/bin/antigravity" ]] || fail "$pass apply retained managed command links"
  for preserved in .gemini/antigravity-cli/settings.json .gemini/antigravity-cli/mcp_oauth_tokens.json .gemini/antigravity-cli/history .omp/agent/agent.db .local/share/compound-engineering/sentinel; do
    [[ $(cat "$scratch/home/$preserved") == 'personal sentinel' ]] || fail "$pass apply changed $preserved"
  done
done

printf '#!/usr/bin/env bash\nexit 0\n' >"$scratch/home/.local/bin/antigravity-sidecar"
chmod 0700 "$scratch/home/.local/bin/antigravity-sidecar"
cp "$source_root/dot_config/systemd/user/antigravity-sidecar.service" "$scratch/home/.config/systemd/user/"
render "$repo_root" "$scratch" "$chezmoi_bin" darwin "$source_root/Library/LaunchAgents/app.dotfiles.antigravity-sidecar.plist.tmpl" "$scratch/home/Library/LaunchAgents/app.dotfiles.antigravity-sidecar.plist"
cat >"$scratch/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CALLS"
[[ "$*" != '--user show-environment' || "${NO_BUS:-0}" != 1 ]]
STUB
cat >"$scratch/bin/launchctl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CALLS"
case $1 in
  print) [[ -f "$HOME/loaded" ]] ;;
  bootstrap) touch "$HOME/loaded" ;;
  bootout) rm "$HOME/loaded" ;;
  kickstart) : ;;
  *) exit 64 ;;
esac
STUB
chmod 0700 "$scratch/bin/systemctl" "$scratch/bin/launchctl"
template="$source_root/.chezmoiscripts/70-agents/run_after_activate-antigravity-sidecar.sh.tmpl"
for os in linux darwin; do
  render "$repo_root" "$scratch" "$chezmoi_bin" "$os" "$template" "$scratch/activate-$os.sh"
  bash -n "$scratch/activate-$os.sh"
  rm -f "$scratch/home/.local/state/dotfiles-antigravity-sidecar/service-revision"
  : >"$scratch/calls"
  env HOME="$scratch/home" PATH="$scratch/bin:/usr/bin:/bin" CALLS="$scratch/calls" bash "$scratch/activate-$os.sh"
  [[ -s "$scratch/home/.local/state/dotfiles-antigravity-sidecar/service-revision" ]] || fail "$os did not record successful activation"
  : >"$scratch/calls"
  env HOME="$scratch/home" PATH="$scratch/bin:/usr/bin:/bin" CALLS="$scratch/calls" bash "$scratch/activate-$os.sh"
  ! grep -Eq 'restart|bootstrap|bootout|daemon-reload' "$scratch/calls" || fail "$os restarted an unchanged service"
  printf '# changed\n' >>"$scratch/home/.local/bin/antigravity-sidecar"
  : >"$scratch/calls"
  env HOME="$scratch/home" PATH="$scratch/bin:/usr/bin:/bin" CALLS="$scratch/calls" bash "$scratch/activate-$os.sh"
  grep -Eq 'restart|bootstrap' "$scratch/calls" || fail "$os did not restart after a binary change"
done
env HOME="$scratch/home" PATH="$scratch/bin:/usr/bin:/bin" CALLS="$scratch/calls" NO_BUS=1 bash "$scratch/activate-linux.sh"
printf 'omp transition: all cases passed\n'
