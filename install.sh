#!/usr/bin/env bash

set -euo pipefail

CHEZMOI_VERSION='2.70.5'
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log_step() {
  printf 'install.sh: %s\n' "$*"
}

fail() {
  printf 'install.sh: %s\n' "$*" >&2
  exit 1
}

run_required() {
  local name="$1"
  shift

  log_step "start: ${name}"
  "$@"
  log_step "done: ${name}"
}

run_optional() {
  local name="$1"
  shift

  log_step "start: ${name}"
  if "$@"; then
    log_step "done: ${name}"
  else
    printf 'install.sh: skip: %s\n' "$name" >&2
  fi
}

run_optional_bash_script() {
  local relative_path="$1"
  local script_path="$REPO/$relative_path"

  if [[ ! -f "$script_path" ]]; then
    printf 'install.sh: skip: %s absent\n' "$relative_path" >&2
    return 0
  fi

  bash "$script_path"
}

verify_mise() {
  "$MISE_BIN" --version
}

provision_toolchain() {
  MISE_GLOBAL_CONFIG_FILE="$REPO/home/dot_config/mise/config.toml" "$MISE_BIN" install
  MISE_GLOBAL_CONFIG_FILE="$REPO/home/dot_config/mise/config.toml" "$MISE_BIN" up
}

install_glab_skills() {
  "$MISE_BIN" exec glab -- glab skills install -f --path ./agents/skills
}

render_opencode_prompt_append() {
  "$MISE_BIN" exec node -- node scripts/bootstrap/render-opencode-prompt-append.mjs
}

apply_chezmoi() {
  "$MISE_BIN" exec "chezmoi@${CHEZMOI_VERSION}" -- chezmoi init --apply --source "$REPO" --no-tty
}

setup_glab() {
  if [[ ! -f "$REPO/scripts/auth/setup-glab.sh" ]]; then
    printf 'install.sh: skip: scripts/auth/setup-glab.sh absent\n' >&2
    return 0
  fi

  sh scripts/auth/setup-glab.sh
}

install_mxm4_haptic_all_bins() {
  if ! command -v cargo >/dev/null 2>&1; then
    printf 'install.sh: skip: mxm4-haptic build (cargo unavailable)\n' >&2
    return 0
  fi

  case "$OS_NAME" in
    Darwin)
      "$MISE_BIN" exec rust@latest -- cargo install \
        --path crates/mxm4-haptic \
        --root "$HOME/.local" \
        --bin mxm4-hapticd \
        --bin mxm4-haptic \
        --locked \
        --force \
        --quiet
      ;;
    Linux)
      "$MISE_BIN" exec rust@latest -- cargo install \
        --path crates/mxm4-haptic \
        --root "$HOME/.local" \
        --locked \
        --force \
        --quiet
      ;;
  esac
}

build_packages_workspace() {
  "$MISE_BIN" trust packages/mise.toml &&
    "$MISE_BIN" -C packages install &&
    "$MISE_BIN" -C packages exec -- yarn install --immutable &&
    "$MISE_BIN" -C packages exec -- yarn build
}

configure_codex_config() {
  "$MISE_BIN" exec node -- node scripts/bootstrap/configure-codex-config.mjs
}

install_linux_system_config() {
  bash scripts/linux/install-linux-system-config.sh
}

enable_mxm4_haptic_systemd() {
  if [ -x "$HOME/.local/bin/mxm4-hapticd" ] &&
    systemctl --user daemon-reload &&
    systemctl --user enable mxm4-hapticd.service mxm4-haptic-notify.service; then
    log_step 'mxm4-haptic: systemd services enabled'
  else
    printf 'skip: mxm4-haptic enable\n' >&2
  fi
}

enable_podman_user_units() {
  if command -v podman >/dev/null 2>&1 &&
    systemctl --user daemon-reload &&
    systemctl --user enable --now podman.socket &&
    systemctl --user enable podman-prune.timer; then
    log_step 'podman: rootless socket + prune timer enabled'
  else
    printf 'skip: podman enable\n' >&2
  fi
}

remove_stale_docker_config() {
  rm -f "$HOME/.docker/config.json"
}

generate_mxm4_haptic_completion() {
  if [ ! -x "$HOME/.local/bin/mxm4-haptic" ]; then
    printf 'skip: mxm4-haptic completion\n' >&2
    return 0
  fi

  mkdir -p "$HOME/.config/zsh/completions"
  if "$HOME/.local/bin/mxm4-haptic" --usage |
    "$MISE_BIN" exec usage@latest -- usage generate completion zsh mxm4-haptic -f - \
      >"$HOME/.config/zsh/completions/_mxm4-haptic"; then
    log_step 'mxm4-haptic: zsh completion generated'
  else
    printf 'skip: mxm4-haptic completion\n' >&2
  fi
}

configure_solaar() {
  bash scripts/linux/config-solaar.sh
}

configure_kde() {
  bash scripts/linux/config-kde.sh
}

install_mxm4_haptic_macos_bins() {
  if ! command -v cargo >/dev/null 2>&1; then
    printf 'install.sh: skip: mxm4-haptic macOS build (cargo unavailable)\n' >&2
    return 0
  fi

  "$MISE_BIN" exec rust@latest -- cargo install \
    --path crates/mxm4-haptic \
    --root "$HOME/.local" \
    --bin mxm4-hapticd \
    --bin mxm4-haptic \
    --locked \
    --force \
    --quiet
}

load_mxm4_haptic_launchd_agent() {
  if [ ! -x "$HOME/.local/bin/mxm4-hapticd" ]; then
    printf 'skip: launchd load\n' >&2
    return 0
  fi

  launchctl bootout "gui/$(id -u)/dev.h82.mxm4-hapticd" 2>/dev/null || true
  if launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/dev.h82.mxm4-hapticd.plist"; then
    log_step 'mxm4-haptic: launchd agent loaded'
  else
    printf 'skip: launchd load\n' >&2
  fi
}

run_linux_block() {
  run_required 'linux system config' install_linux_system_config
  run_optional 'mxm4-haptic systemd enable' enable_mxm4_haptic_systemd
  run_optional 'podman user units enable' enable_podman_user_units
  run_required 'docker credential cleanup' remove_stale_docker_config
  run_optional 'mxm4-haptic zsh completion' generate_mxm4_haptic_completion
  run_required 'config-solaar.sh' configure_solaar
  run_required 'config-kde.sh' configure_kde
}

run_macos_block() {
  run_required 'docker credential cleanup' remove_stale_docker_config
  run_optional 'mxm4-haptic macOS cargo build' install_mxm4_haptic_macos_bins
  run_optional 'mxm4-haptic launchd load' load_mxm4_haptic_launchd_agent
  run_optional 'mxm4-haptic zsh completion' generate_mxm4_haptic_completion
}

OS_NAME="$(uname -s)"
case "$OS_NAME" in
  Darwin | Linux) ;;
  *)
    fail "unsupported OS: ${OS_NAME}. Use install.ps1 on Windows."
    ;;
esac

if command -v mise >/dev/null 2>&1; then
  MISE_BIN="$(command -v mise)"
elif [[ -x "$HOME/.local/bin/mise" ]]; then
  MISE_BIN="$HOME/.local/bin/mise"
else
  fail "mise not found. Install mise yourself and re-run. Expected mise on PATH or at $HOME/.local/bin/mise."
fi

pushd "$REPO" >/dev/null
trap 'popd >/dev/null || true' EXIT

run_required 'verify mise' verify_mise
run_required 'toolchain provision' provision_toolchain
run_optional 'remove-dotbot-symlinks.sh' run_optional_bash_script 'scripts/bootstrap/remove-dotbot-symlinks.sh'
run_optional 'glab skills install' install_glab_skills
run_required 'render OpenCode prompt_append' render_opencode_prompt_append
run_required 'chezmoi init --apply' apply_chezmoi
run_optional 'setup-glab.sh' setup_glab
run_optional 'mxm4-haptic cargo build' install_mxm4_haptic_all_bins
run_optional 'packages yarn build' build_packages_workspace
run_optional 'link-repo-trees.sh' run_optional_bash_script 'scripts/bootstrap/link-repo-trees.sh'
run_optional 'configure-codex-config.mjs' configure_codex_config
run_optional 'inject-1password-secrets.sh' run_optional_bash_script 'scripts/bootstrap/inject-1password-secrets.sh'
run_optional 'install-fonts.sh' run_optional_bash_script 'scripts/bootstrap/install-fonts.sh'

case "$OS_NAME" in
  Linux) run_linux_block ;;
  Darwin) run_macos_block ;;
esac

log_step 'complete'
