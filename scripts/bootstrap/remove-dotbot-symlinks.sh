#!/usr/bin/env bash
set -euo pipefail

# One-time migration helper for the dotbot -> chezmoi cutover.
# It removes only the known dotbot-created symlinks under $HOME before the first
# `chezmoi apply`, so chezmoi cannot follow a repo symlink or collide with one.
# Regular files and absent paths are left untouched; re-running is safe.

REPO="$(git rev-parse --show-toplevel)"
HOME_DIR="${HOME:?HOME must be set}"

declare -a TARGETS=()
declare -A SEEN=()

add_target() {
  local relative_path="$1"
  relative_path="${relative_path#/}"

  if [[ -z "${SEEN[$relative_path]+x}" ]]; then
    TARGETS+=("$HOME_DIR/$relative_path")
    SEEN[$relative_path]=1
  fi
}

decode_component() {
  local component="$1"

  while :; do
    case "$component" in
      private_*) component="${component#private_}" ;;
      executable_*) component="${component#executable_}" ;;
      *) break ;;
    esac
  done

  if [[ "$component" == dot_* ]]; then
    component=".${component#dot_}"
  fi

  printf '%s' "$component"
}

decode_relative_path() {
  local source_relative_path="$1"
  local decoded=""
  local component

  IFS='/' read -r -a components <<< "$source_relative_path"
  for component in "${components[@]}"; do
    if [[ -n "$decoded" ]]; then
      decoded+="/"
    fi
    decoded+="$(decode_component "$component")"
  done

  printf '%s' "$decoded"
}

add_tracked_tree_targets() {
  local source_dir="$1"
  local target_dir="$2"
  local source_path relative_path decoded_path

  while IFS= read -r -d '' source_path; do
    [[ -f "$REPO/$source_path" ]] || continue
    relative_path="${source_path#"$source_dir/"}"
    decoded_path="$(decode_relative_path "$relative_path")"
    add_target "$target_dir/$decoded_path"
  done < <(git -C "$REPO" ls-files -z -- "$source_dir")
}

add_tracked_file_targets() {
  local target_dir="$1"
  shift

  local source_path basename decoded_name
  for source_path in "$@"; do
    [[ -f "$source_path" ]] || continue
    basename="${source_path##*/}"
    decoded_name="$(decode_component "$basename")"
    add_target "$target_dir/$decoded_name"
  done
}

add_shared_targets() {
  add_target ".agents/skills"
  add_target ".agents/.skill-lock.json"
  add_target ".claude/skills"
  add_target ".config/opencode/commands"
  add_target ".codex/prompts"
  add_target ".config/opencode/AGENTS.md"
  add_target ".codex/AGENTS.md"
  add_target ".claude/CLAUDE.md"
  add_target ".config/git/config"
  add_target ".config/mise/config.toml"
  add_target ".ssh/config"
  add_target ".config/1Password/ssh/agent.toml"
  add_target ".default-gems"
  add_target ".yarnrc.yml"
  add_target ".npmrc"
  add_target ".config/opencode/plugins/playwright-cli-session-injection.js"
  add_target ".config/opencode/plugins/playwright-cli-session-injection.js.map"

  add_tracked_file_targets ".config/opencode" \
    "$REPO"/home/dot_config/opencode/*.json \
    "$REPO"/home/dot_config/opencode/*.jsonc
  add_tracked_tree_targets "home/dot_config/zsh" ".config/zsh"
}

add_posix_common_targets() {
  add_tracked_file_targets "" "$REPO"/home/dot_z*
  add_tracked_file_targets ".gnupg" "$REPO"/home/private_dot_gnupg/*.conf
  add_target ".local/bin/opencode"
  add_target ".local/bin/code"
  add_target ".codex/hooks.json"
}

add_linux_targets() {
  add_posix_common_targets
  add_target ".gitconfig.d/linux.gitconfig"
  add_tracked_tree_targets "home/dot_config" ".config"
  add_tracked_tree_targets "home/dot_local/share/applications" ".local/share/applications"
  add_target ".config/opencode/plugins/mxm4-haptic.js"
  add_target ".config/opencode/plugins/mxm4-haptic.js.map"
}

add_macos_targets() {
  add_posix_common_targets
  add_target ".gitconfig.d/macos.gitconfig"
  add_tracked_tree_targets "home/dot_config/Code/User" "Library/Application Support/Code/User"
  add_tracked_tree_targets "home/dot_config/VSCodium/User" "Library/Application Support/VSCodium/User"
  add_target "Library/LaunchAgents/dev.h82.mxm4-hapticd.plist"
}

remove_symlink_targets() {
  local target

  for target in "${TARGETS[@]}"; do
    if [[ -L "$target" ]]; then
      rm -f -- "$target"
      printf 'removed symlink: %s\n' "$target"
    fi
  done
}

add_shared_targets

case "$(uname -s)" in
  Linux)
    add_linux_targets
    ;;
  Darwin)
    add_macos_targets
    ;;
  *)
    printf 'remove-dotbot-symlinks: unsupported POSIX OS from uname -s; shared targets only\n' >&2
    ;;
esac

remove_symlink_targets
