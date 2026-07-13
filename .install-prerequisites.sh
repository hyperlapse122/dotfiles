#!/usr/bin/env bash
#
# chezmoi `read-source-state.pre` hook — installs the tooling chezmoi needs
# *before* it reads the source state:
#
#   * 1Password + 1Password CLI (`op`) — secret templates call `onepasswordRead`,
#     which requires an authenticated `op`.
#   * mise — the runtime / CLI version manager the rest of this config relies on.
#
# chezmoi runs a hook `command` verbatim and never renders it as a template, so
# this file MUST NOT be a `.tmpl`. OS divergence is decided at runtime by reading
# /etc/os-release on Linux, not from Go-template branches.

set -euo pipefail

# Container / CI detection: Podman creates /run/.containerenv, Docker creates
# /.dockerenv. Neither exists on a bare-metal host or VM.
#
# distrobox and toolbox are the OPT-OUT: both bind-mount the host $HOME and both
# create /run/.toolboxenv (distrobox touches it for toolbx compatibility), so an
# apply inside one targets the real host $HOME and must provision like the host.
# Treat only a "real" container — a marker WITHOUT /run/.toolboxenv — as one here.
is_devbox() {
  [[ -f /run/.toolboxenv ]]
}

is_container() {
  [[ -f /run/.containerenv || -f /.dockerenv ]] || return 1
  ! is_devbox
}

# `op` can resolve secrets. `op whoami` succeeds for BOTH a desktop-app
# integration and a service-account token (OP_SERVICE_ACCOUNT_TOKEN) — the
# latter is how containers/CI authenticate. `op user get --me` is the legacy
# fallback: it works for a signed-in human account but NOT a service account.
op_ready() {
  command -v op >/dev/null 2>&1 || return 1
  op whoami >/dev/null 2>&1 && return 0
  op user get --me >/dev/null 2>&1
}

# Human-facing instructions for enabling the 1Password CLI. Printed once before
# waiting and again on timeout. Mirrors the flow documented in README.md and the
# container branch above, with a headless service-account escape hatch.
print_op_auth_guidance() {
  printf 'install-prerequisites.sh: 1Password CLI is not authenticated yet.\n' >&2
  printf 'Let chezmoi resolve secrets by enabling the 1Password CLI:\n' >&2
  printf '  1. Open the 1Password desktop app and sign in.\n' >&2
  printf '  2. Enable Settings -> Developer -> Integrate with 1Password CLI.\n' >&2
  printf '  (Headless host? Export a service-account token instead and re-run:\n' >&2
  printf '     export OP_SERVICE_ACCOUNT_TOKEN=...   # op service account create --help)\n' >&2
}

# Poll op_ready() until it succeeds or a bounded deadline elapses. Interval and
# max-wait are env-overridable so the unit test can drive it fast with a stubbed
# `op` and a no-op `sleep`.
wait_for_op_auth() {
  local interval="${OP_AUTH_POLL_INTERVAL_SECS:-5}"
  local max_wait="${OP_AUTH_MAX_WAIT_SECS:-900}"
  local waited=0
  while ! op_ready; do
    if (( waited >= max_wait )); then
      printf 'install-prerequisites.sh: timed out after %ss waiting for 1Password CLI auth.\n' "$max_wait" >&2
      print_op_auth_guidance
      return 1
    fi
    sleep "$interval"
    waited=$(( waited + interval ))
    if (( waited % 30 == 0 )); then
      printf '  .. still waiting for 1Password CLI sign-in (%ss elapsed)\n' "$waited" >&2
    fi
  done
  return 0
}

# Return 0 once `op` can resolve secrets. Already authed -> return immediately.
# Otherwise guide the user; fail fast (like the container branch) when stdin is
# not a TTY so a headless/CI run never hangs; else wait interactively.
ensure_op_authenticated() {
  if op_ready; then
    return 0
  fi
  print_op_auth_guidance
  # `[[ -t 0 ]]` is true only under an interactive chezmoi run; never block a
  # non-interactive / piped invocation waiting for a sign-in that cannot happen.
  if [[ ! -t 0 ]]; then
    printf 'install-prerequisites.sh: non-interactive shell; cannot wait for sign-in.\n' >&2
    return 1
  fi
  if wait_for_op_auth; then
    printf 'install-prerequisites.sh: 1Password CLI authenticated; continuing.\n' >&2
    return 0
  fi
  return 1
}

# config-secrets key: the chezmoi config template (.chezmoi.toml.tmpl) stores
# its prompted secrets (LUKS passphrase, MOK password) AES-encrypted in
# ~/.config/chezmoi/chezmoi.toml instead of plaintext. The AES key lives ONLY
# in the user keyring (Secret Service on Linux, Keychain on macOS) under
# service=chezmoi-config-secrets / user=<username>; templates read it back
# fail-soft via `chezmoi secret keyring get`
# (.chezmoitemplates/config-secrets-key.tmpl). Generate it here — this hook
# runs before chezmoi renders the config template on `init` — once per
# user+host, and NEVER fail the hook over it: with no reachable keyring
# (headless/TTY/container) the templates behave as if no secret was entered.
# Keep in sync with Confirm-ConfigSecretsKey in .install-prerequisites.ps1
# (Windows Credential Manager works headless, same service/user names).
ensure_config_secrets_key() {
  command -v chezmoi >/dev/null 2>&1 || return 0
  local user existing key
  user="${USER:-$(id -un)}"
  existing="$(chezmoi secret keyring get --service=chezmoi-config-secrets --user="$user" 2>/dev/null || true)"
  [[ -n "$existing" ]] && return 0
  key="$(head -c 32 /dev/urandom | base64 | tr -d '\n')"
  if ! chezmoi secret keyring set --service=chezmoi-config-secrets --user="$user" --value="$key" 2>/dev/null; then
    printf 'install-prerequisites.sh: user keyring unreachable; config-template secrets cannot be stored this run.\n' >&2
  fi
  return 0
}

# chezmoi calls the GitHub API while reading the source state (it fetches the
# .chezmoiexternals repos, e.g. prezto) and again during provisioning (release
# assets such as fonts and mise-managed tools). It authenticates with the first
# of these tokens it finds — CHEZMOI_GITHUB_ACCESS_TOKEN, then GITHUB_ACCESS_TOKEN,
# then GITHUB_TOKEN. With none set, those calls fall back to GitHub's anonymous
# 60-requests/hour-per-IP limit and a fresh apply can fail mid-read with an opaque
# HTTP 403, so require a token up front and stop here with actionable guidance.
ensure_github_token() {
  if [[ -n "${CHEZMOI_GITHUB_ACCESS_TOKEN:-}" \
     || -n "${GITHUB_ACCESS_TOKEN:-}" \
     || -n "${GITHUB_TOKEN:-}" ]]; then
    return 0
  fi
  printf 'install-prerequisites.sh: no GitHub API token in the environment.\n' >&2
  printf 'chezmoi is about to read the source state, which calls the GitHub API;\n' >&2
  printf 'without a token it shares the anonymous 60-request/hour limit and a fresh\n' >&2
  printf 'apply can fail. Inject a PAT from 1Password, then re-run in the same shell:\n' >&2
  # SC2016: the $(op read ...) is literal text for the user to copy, not for us to expand.
  # shellcheck disable=SC2016
  printf '  export GITHUB_TOKEN=$(op read "op://Private/GitHub/PAT")\n' >&2
  return 1
}

# Unit-test seam: let the harness `source` this file for its functions without
# running the installer below. No-op in normal execution (variable unset).
if [[ -n "${_INSTALL_PREREQUISITES_TEST_SOURCE:-}" ]]; then
  return 0
fi

# The config-secrets key must exist before chezmoi renders .chezmoi.toml.tmpl
# (`init` encrypts its prompted secrets with it), so ensure it BEFORE the fast
# path — a fully provisioned host still needs it on its next `init`. One
# keyring read per hook run; soft-skips real containers (no keyring there, and
# the container CLI-only profile deploys no secret consumers anyway).
if ! is_container; then
  ensure_config_secrets_key
fi

# Fast path: nothing to do once mise is present and `op` can resolve secrets.
# Keeps re-runs cheap — chezmoi invokes this hook on every `init`/`apply`.
if command -v mise >/dev/null 2>&1 && op_ready; then
  exit 0
fi

# Inside a container we NEVER install packages or the 1Password desktop app —
# the base image plus mise are expected to provide `op` and `mise`, and secrets
# come from a service-account token. Fail fast with guidance instead of trying
# to dnf/apt/brew inside the container.
if is_container; then
  missing=()
  command -v op   >/dev/null 2>&1 || missing+=("op (1Password CLI)")
  command -v mise >/dev/null 2>&1 || missing+=("mise")
  if [[ ${#missing[@]} -gt 0 ]]; then
    printf 'install-prerequisites.sh: container detected, but missing from the base image: %s.\n' "${missing[*]}" >&2
    printf 'Bake op + mise into the image; this hook never installs packages inside a container.\n' >&2
    exit 1
  fi
  printf 'install-prerequisites.sh: container detected, but op is not authenticated.\n' >&2
  printf 'Export a 1Password service-account token before applying:\n' >&2
  printf '  export OP_SERVICE_ACCOUNT_TOKEN=...   # see: op service account create --help\n' >&2
  exit 1
fi

# Fedora: install via dnf, mirroring .chezmoidata/packages.yaml (1Password's
# stable RPM repo + the jdxcode/mise COPR). Skips work that is already done so
# the hook is idempotent across re-runs.
install_fedora() {
  # Use sudo only when not already root (matches the package-install script).
  # Throw early if neither root nor sudo is available — dnf needs it.
  local -a SUDO
  if [[ "${EUID}" -eq 0 ]]; then
    SUDO=()
  elif command -v sudo >/dev/null 2>&1; then
    SUDO=(sudo)
  else
    printf 'install-prerequisites.sh: requires root or sudo for package installation.\n' >&2
    exit 1
  fi

  if ! rpm -q 1password 1password-cli >/dev/null 2>&1; then
    "${SUDO[@]}" tee /etc/yum.repos.d/1password.repo >/dev/null <<'EOF'
[1password]
name=1Password Stable Channel
baseurl=https://downloads.1password.com/linux/rpm/stable/$basearch
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey="https://downloads.1password.com/linux/keys/1password.asc"
EOF
    "${SUDO[@]}" dnf install 1password 1password-cli -y
  fi

  if ! rpm -q gh zsh git-lfs >/dev/null 2>&1; then
    "${SUDO[@]}" dnf install gh zsh git-lfs -y
  fi

  if ! rpm -q mise >/dev/null 2>&1; then
    "${SUDO[@]}" dnf copr enable jdxcode/mise -y
    "${SUDO[@]}" dnf install mise -y
  fi
}

# Ubuntu/Debian: install via apt. Ordered to install transport tools and
# 1Password keyring before the package installs.
install_ubuntu() {
  # Fail fast if no sudo (needed for apt-get and keyring writes).
  if [[ "${EUID}" -ne 0 ]]; then
    if ! command -v sudo >/dev/null 2>&1; then
      printf 'install-prerequisites.sh: requires root or sudo for package installation.\n' >&2
      exit 1
    fi
    sudo -v || { printf 'install-prerequisites.sh: sudo failed; aborting.\n' >&2; exit 1; }
  fi
  local -a SUDO
  if [[ "${EUID}" -eq 0 ]]; then SUDO=(); else SUDO=(sudo); fi

  export DEBIAN_FRONTEND=noninteractive

  # Self-heal before the FIRST apt invocation, mirroring setup_apt_repos in
  # .chezmoiscripts/40-linux-ubuntu/run_onchange_before_ubuntu.sh.tmpl (keep the
  # two sites in lockstep): a retired aptRepos revision left an active legacy
  # /etc/apt/sources.list.d/1password.list whose signed-by= disagrees with the
  # package-managed 1password.sources, and apt rejects the entire source list on
  # that conflict — which would abort this hook right here on `apt-get update`.
  # The run_onchange cleanup alone can't cover this path: it runs only after the
  # hook, and the hook only reaches this function when its mise+op fast path
  # misses.
  if [[ -f /etc/apt/sources.list.d/1password.sources && -f /etc/apt/sources.list.d/1password.list ]]; then
    "${SUDO[@]}" rm -f /etc/apt/sources.list.d/1password.list /usr/share/keyrings/1password.gpg
  fi

  # Bootstrap transport tools needed to add the 1Password repo.
  "${SUDO[@]}" apt-get update -qq
  for pkg in ca-certificates curl gnupg lsb-release; do
    dpkg -s "$pkg" >/dev/null 2>&1 || "${SUDO[@]}" apt-get install -y "$pkg"
  done

  # Add 1Password apt repo + GPG keyring (idempotent), per
  # https://support.1password.com/install-linux/#debian-or-ubuntu — the repo is
  # arch-partitioned (amd64 at /linux/debian/amd64, arm64 at /linux/debian/arm64),
  # so the `deb` line pins the native arch; the old /linux/apt/debian path 404s.
  # This bootstrap .list only has to survive until the install below: the
  # 1password deb's postinst takes over the repo definition — it writes the
  # deb822 /etc/apt/sources.list.d/1password.sources signed by the SAME
  # /usr/share/keyrings/1password-archive-keyring.gpg and comments out this
  # .list — so nothing else may manage this repo (apt rejects the entire source
  # list when one source carries two different Signed-By values; the chezmoi
  # Ubuntu installer only cleans the neutralized .list up).
  if ! dpkg -s 1password 1password-cli >/dev/null 2>&1; then
    local arch
    arch="$(dpkg --print-architecture)"
    "${SUDO[@]}" mkdir -p /usr/share/keyrings
    curl -fsSL https://downloads.1password.com/linux/keys/1password.asc \
      | "${SUDO[@]}" gpg --yes --dearmor -o /usr/share/keyrings/1password-archive-keyring.gpg
    printf '%s\n' \
      "deb [arch=${arch} signed-by=/usr/share/keyrings/1password-archive-keyring.gpg] https://downloads.1password.com/linux/debian/${arch} stable main" \
      | "${SUDO[@]}" tee /etc/apt/sources.list.d/1password.list >/dev/null
    "${SUDO[@]}" apt-get update -qq
    "${SUDO[@]}" apt-get install -y 1password 1password-cli
  fi

  # GitHub CLI.
  dpkg -s gh >/dev/null 2>&1 || "${SUDO[@]}" apt-get install -y gh

  # git-lfs.
  dpkg -s git-lfs >/dev/null 2>&1 || "${SUDO[@]}" apt-get install -y git-lfs

  # zsh.
  dpkg -s zsh >/dev/null 2>&1 || "${SUDO[@]}" apt-get install -y zsh

  # mise via its distro-agnostic apt repo: mise.jdx.dev/deb serves real
  # amd64 AND arm64 indexes and works on debian too (this function handles
  # ubuntu|debian), whereas the jdxcode Launchpad PPA that
  # .chezmoidata/packages.yaml uses publishes mise only for Ubuntu 26.04
  # amd64 (its other arch indexes are empty) — on Ubuntu, setup_apt_repos in
  # the chezmoi installer later converges mise.list + keyring to that PPA.
  # arch pinned so apt never asks this repo for an i386 index once the
  # installer enables i386 as a foreign arch for Steam (the repo publishes
  # none, and an unpinned line made every `apt update` warn).
  if ! command -v mise >/dev/null 2>&1; then
    curl -fsSL https://mise.jdx.dev/gpg-key.pub \
      | "${SUDO[@]}" gpg --yes --dearmor -o /usr/share/keyrings/mise.gpg
    echo "deb [arch=amd64,arm64 signed-by=/usr/share/keyrings/mise.gpg] https://mise.jdx.dev/deb stable main" \
      | "${SUDO[@]}" tee /etc/apt/sources.list.d/mise.list >/dev/null
    "${SUDO[@]}" apt-get update -qq
    "${SUDO[@]}" apt-get install -y mise
  fi
}

# macOS: install via Homebrew, bootstrapping Homebrew itself when it is missing
# (it is the package manager the macOS side of this config assumes — see the
# /opt/homebrew PATH wiring in dot_config/zsh/dot_zprofile).
install_macos() {
  if ! command -v brew >/dev/null 2>&1; then
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  fi
  # Make `brew` usable in this non-login shell for the installs below.
  if [[ -x /opt/homebrew/bin/brew ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  elif [[ -x /usr/local/bin/brew ]]; then
    eval "$(/usr/local/bin/brew shellenv)"
  fi

  brew list --cask 1password >/dev/null 2>&1 || brew install --cask 1password
  brew list --cask 1password-cli >/dev/null 2>&1 || brew install --cask 1password-cli
  brew list mise >/dev/null 2>&1 || brew install mise
}

case "$(uname -s)" in
  Darwin) install_macos ;;
  Linux)
    # Detect distro from /etc/os-release (available on all modern Linux distros).
    distro_id=""
    if [[ -r /etc/os-release ]]; then
      # shellcheck source=/dev/null
      distro_id="$(. /etc/os-release 2>/dev/null && printf '%s' "${ID:-}")"
    fi
    case "$distro_id" in
      fedora) install_fedora ;;
      ubuntu|debian) install_ubuntu ;;
      *)
        printf 'install-prerequisites.sh: unsupported Linux distro: %s.\n' "${distro_id:-unknown}" >&2
        exit 1
        ;;
    esac
    ;;
  *)
    printf 'install-prerequisites.sh: unsupported OS %s.\n' "$(uname -s)" >&2
    exit 1
    ;;
esac

# Packages are installed now, but on a fresh device `op` still is not signed in
# (installing the app/CLI does not authenticate it), so chezmoi would fail on the
# first `onepasswordRead`. Block until the user enables the 1Password CLI
# (interactive), or fail fast with guidance (non-interactive / headless).
ensure_op_authenticated || exit 1

# With `op` authenticated, chezmoi's very next step is to read the source state
# over the GitHub API. Require a token now — placed after op auth so the `op read`
# in the guidance actually works — instead of letting the read hit a rate limit.
ensure_github_token || exit 1
exit 0
