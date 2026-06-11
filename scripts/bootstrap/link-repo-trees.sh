#!/usr/bin/env bash
set -euo pipefail

REPO="$(git rev-parse --show-toplevel)"
OS_NAME="$(uname -s)"

log() {
  printf '%s\n' "$*"
}

link_repo_tree() {
  local source=$1
  local target=$2

  mkdir -p "$(dirname -- "$target")"
  rm -f -- "$target"
  ln -sfn -- "$source" "$target"
  log "link: $target -> $source"
}

link_plugin_pair_if_present() {
  local name=$1
  local dist_dir=$2
  local target=$3
  local target_map=$4
  local source="$dist_dir/index.mjs"
  local source_map="$dist_dir/index.mjs.map"

  if [[ ! -f "$source" ]]; then
    log "skip: $name dist absent"
    return 0
  fi

  link_repo_tree "$source" "$target"
  link_repo_tree "$source_map" "$target_map"
}

log "link-repo-trees: repo=$REPO os=$OS_NAME home=$HOME"

link_repo_tree "$REPO/agents/skills" "$HOME/.agents/skills"
link_repo_tree "$REPO/agents/skills" "$HOME/.claude/skills"
link_repo_tree "$REPO/agents/commands" "$HOME/.config/opencode/commands"
link_repo_tree "$REPO/agents/commands" "$HOME/.codex/prompts"
link_repo_tree "$REPO/agents/SHARED_AGENTS.md" "$HOME/.config/opencode/AGENTS.md"
link_repo_tree "$REPO/agents/SHARED_AGENTS.md" "$HOME/.codex/AGENTS.md"
link_repo_tree "$REPO/agents/SHARED_AGENTS.md" "$HOME/.claude/CLAUDE.md"
link_repo_tree "$REPO/agents/.skill-lock.json" "$HOME/.agents/.skill-lock.json"

case "$OS_NAME" in
  Darwin | Linux)
    link_repo_tree "$REPO/codex/hooks.json" "$HOME/.codex/hooks.json"
    ;;
  *)
    log "skip: codex hooks unsupported on $OS_NAME"
    ;;
esac

if [[ "$OS_NAME" == "Linux" ]]; then
  link_plugin_pair_if_present \
    "mxm4-haptic" \
    "$REPO/packages/opencode-mxm4-haptic/dist" \
    "$HOME/.config/opencode/plugins/mxm4-haptic.js" \
    "$HOME/.config/opencode/plugins/mxm4-haptic.js.map"
else
  log "skip: mxm4-haptic plugin unsupported on $OS_NAME"
fi

link_plugin_pair_if_present \
  "playwright-cli-session-injection" \
  "$REPO/packages/opencode-playwright-cli-session-injection/dist" \
  "$HOME/.config/opencode/plugins/playwright-cli-session-injection.js" \
  "$HOME/.config/opencode/plugins/playwright-cli-session-injection.js.map"

log "link-repo-trees: complete"
