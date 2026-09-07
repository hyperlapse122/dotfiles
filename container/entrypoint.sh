#!/usr/bin/env bash
# Orca worker entrypoint: turn a started container into a worker a workspace can
# attach to, then become sshd.
#
# ORDER IS THE DESIGN. Everything that needs a credential happens before sshd
# replaces this process, because a pod has no systemd and sshd starts each login
# session from PID 1's children WITHOUT inheriting this process's exported
# environment. Anything resolved here and merely exported would be invisible to
# the shell a workspace actually gets.
set -euo pipefail

log() { printf 'worker-entrypoint: %s\n' "$*" >&2; }
die() { printf 'worker-entrypoint: FATAL: %s\n' "$*" >&2; exit 1; }

# This process is root, because sshd needs to be. Anything that writes into the
# worker's HOME must NOT be: a root-owned ~/.mcp.json or ~/.ssh is a home the
# worker cannot rewrite, and sshd's strict mode refuses an authorized_keys it
# does not trust the ownership of.
WORKER_USER=${WORKER_USER:-worker}
WORKER_HOME=$(getent passwd "$WORKER_USER" | cut -d: -f6)
[[ -n "$WORKER_HOME" ]] || die "no home directory for user $WORKER_USER"
as_worker() { runuser -u "$WORKER_USER" -- "$@"; }

# --- 1. Refuse to start half-configured ------------------------------------
# A worker missing its Connect credentials starts fine and fails at the first
# thing an agent tries, far from the cause. Name what is missing, here.
missing=()
for var in OP_CONNECT_HOST OP_CONNECT_TOKEN; do
  [[ -n "${!var:-}" ]] || missing+=("$var")
done
((${#missing[@]} == 0)) || die "the platform did not supply: ${missing[*]}
  These come from the k3s platform, not from the image. Without them nothing in
  this worker can resolve a secret, so it would start and then fail at first use."

[[ -n "${WORKER_SSH_PUBKEY_REF:-}" ]] \
  || die 'WORKER_SSH_PUBKEY_REF must name the op:// reference holding the public key this worker accepts'


# --- 2. Say that this is a container ----------------------------------------
# chezmoi's `container` fact is a stat of /run/.containerenv or /.dockerenv, and
# those markers are written by Podman and Docker -- not by containerd, which is
# what runs this image in k3s. Without one, the apply below believes it is on a
# host and tries to provision packages, which asks for a password no pod has:
#
#   sudo: a terminal is required to read the password
#
# The build already ran under Podman, so the marker existed then and the failure
# appears only at runtime, in the cluster. Stating the fact here is the fix; the
# alternative would be teaching the platform to mount a file the image needs.
if [[ ! -f /run/.containerenv && ! -f /.dockerenv ]]; then
  log 'no container marker (containerd runtime); creating /run/.containerenv'
  : >/run/.containerenv
fi

# --- 3. Per-pod SSH host keys ----------------------------------------------
# Generated here, never baked. Each worker has its own MagicDNS name, so the
# known_hosts collision that shared keys avoid does not arise -- and a host key
# in a public image is a host key everyone has.
log 'generating per-pod SSH host keys'
ssh-keygen -A

# --- 4. The runtime apply ---------------------------------------------------
# The build rendered these targets with opAvailable false, so they carry op://
# references rather than values. With Connect present the fact flips and the same
# chezmoi renders the real thing. One renderer, no second templating layer over
# what chezmoi already wrote.
# The config was rendered at BUILD time, where there was no Connect. Its
# 1Password mode follows the environment, so it has to be re-rendered here or
# chezmoi refuses every op:// reference with "onepassword.mode is account, but
# OP_CONNECT_HOST and OP_CONNECT_TOKEN are set". Re-rendering the template is
# what `chezmoi init` would do, without its git fetch: a pod's start must not
# depend on reaching a git host.
log 'rendering the chezmoi config for Connect'
config_dir="${WORKER_HOME}/.config/chezmoi"
config_tmpl="${WORKER_HOME}/.local/share/chezmoi/.chezmoi.toml.tmpl"
[[ -f "$config_tmpl" ]] || die "no config template at $config_tmpl"
as_worker install -d -m 0700 "$config_dir"
as_worker env HOME="$WORKER_HOME" \
  OP_CONNECT_HOST="$OP_CONNECT_HOST" OP_CONNECT_TOKEN="$OP_CONNECT_TOKEN" \
  sh -c 'chezmoi execute-template --init --no-tty <"$1" >"$2"' sh "$config_tmpl" "$config_dir/chezmoi.toml"

log 'applying the op-dependent targets against 1Password Connect'
# --exclude=externals is what makes this targeted. Every external is already in
# the image, and re-fetching them would put a pod's start time and success at the
# mercy of upstream release hosts. Files and scripts DO re-render, and that is
# precisely the set that changes: opAvailable flipped, so every target holding an
# op:// reference now renders its value, and the run_onchange scripts among them
# re-run because their rendered content changed. Nothing else did, so nothing
# else moves.
as_worker env HOME="$WORKER_HOME" \
  OP_CONNECT_HOST="$OP_CONNECT_HOST" OP_CONNECT_TOKEN="$OP_CONNECT_TOKEN" \
  chezmoi apply --no-tty --exclude=externals </dev/null

# --- 5. authorized_keys -----------------------------------------------------
# Fetched at start rather than baked, so rotating the key restarts a pod instead
# of rebuilding an image. The public half is not a secret; this is about the
# rotation path, not confidentiality.
log 'writing authorized_keys'
install -d -m 0700 -o "$WORKER_USER" -g "$WORKER_USER" "${WORKER_HOME}/.ssh"
authorized="${WORKER_HOME}/.ssh/authorized_keys"
as_worker env OP_CONNECT_HOST="$OP_CONNECT_HOST" OP_CONNECT_TOKEN="$OP_CONNECT_TOKEN" \
  op read "${WORKER_SSH_PUBKEY_REF}" >"$authorized"
chown "$WORKER_USER:$WORKER_USER" "$authorized"
chmod 0600 "$authorized"
[[ -s "$authorized" ]] || die 'authorized_keys came back empty; no one could log in'

# --- 6. The environment a workspace actually gets ---------------------------
# sshd starts a login session from PID 1's children WITHOUT this process's
# environment, and the image's ENV lines apply to the container process, not to
# that session. So everything a workspace needs -- its toolchain on PATH, the
# shared caches, the proxy credential -- has to be written where a shell reads
# it, or the workspace gets a machine whose tools are installed and invisible.
profile=/etc/profile.d/99-orca-worker.sh

# The proxy credential, resolved ONCE and never per invocation. Not through
# apiKeyHelper or the Codex auth.command: `op read` takes about 19s on this
# hardware and the Codex auth.timeout_ms default is 5000ms.
#
# Two sources, in this order. ANTHROPIC_AUTH_TOKEN comes straight from the
# platform's own Secret and is preferred: the proxy key is issued BY the cluster,
# so routing it through 1Password would add a second copy of a value the cluster
# already owns -- and two copies that must be rotated together is a drift class,
# not a safeguard. ANTHROPIC_AUTH_TOKEN_REF stays supported for a platform that
# would rather keep the value in a vault.
token=
if [[ -n "${ANTHROPIC_AUTH_TOKEN:-}" ]]; then
  log 'using the model proxy credential supplied by the platform'
  token=$ANTHROPIC_AUTH_TOKEN
elif [[ -n "${ANTHROPIC_AUTH_TOKEN_REF:-}" ]]; then
  log 'resolving the model proxy credential'
  token=$(as_worker env OP_CONNECT_HOST="$OP_CONNECT_HOST" OP_CONNECT_TOKEN="$OP_CONNECT_TOKEN" \
    op read "${ANTHROPIC_AUTH_TOKEN_REF}")
  [[ -n "$token" ]] || die 'the proxy credential came back empty'
fi

log 'writing the login environment'
# 0640 root:worker, not the 0644 a profile.d drop-in usually carries: this file
# can hold a live credential, and a login shell reads it as the worker, so group
# read is all it needs. Written with a restrictive umask so it is never briefly
# world-readable between creation and chmod.
( umask 037
{
  printf '# Written by worker-entrypoint at pod start. Not baked into any layer.\n'
  # mise INSTALLS tools into the image and puts its shims here. Without this
  # line `node` is present and "command not found", which reads like a broken
  # image rather than a PATH an sshd session never inherited.
  printf 'export PATH=%q:%q:"$PATH"\n' \
    "${WORKER_HOME}/.local/share/mise/shims" "${WORKER_HOME}/.local/bin"
  [[ -n "$token" ]] && printf 'export ANTHROPIC_AUTH_TOKEN=%q\n' "$token"
  [[ -n "${ANTHROPIC_BASE_URL:-}" ]] && printf 'export ANTHROPIC_BASE_URL=%q\n' "$ANTHROPIC_BASE_URL"
  [[ -n "${OP_CONNECT_HOST:-}" ]] && printf 'export OP_CONNECT_HOST=%q\n' "$OP_CONNECT_HOST"
  [[ -n "${OP_CONNECT_TOKEN:-}" ]] && printf 'export OP_CONNECT_TOKEN=%q\n' "$OP_CONNECT_TOKEN"
  # WORKER_EXPORT_VARS names variables the PLATFORM wants a workspace shell to
  # see -- the shared cache paths are what it carries today. The image does not
  # name them itself: which caches are shared, and where, is a platform decision,
  # and hard-coding it here would put half of that decision in an image that has
  # to be rebuilt to change it.
  for var in ${WORKER_EXPORT_VARS:-}; do
    if [[ ! $var =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
      printf 'worker-entrypoint: ignoring invalid name in WORKER_EXPORT_VARS: %s\n' "$var" >&2
      continue
    fi
    [[ -n "${!var:-}" ]] || continue
    printf 'export %s=%q\n' "$var" "${!var}"
  done
} >"$profile" )
chown "root:$WORKER_USER" "$profile"
chmod 0640 "$profile"
# /etc/profile.d covers a LOGIN shell, which is what an attached workspace gets.
# `ssh worker <command>` is not a login shell and reads ~/.bashrc instead, so the
# same file is sourced from there -- otherwise a scripted agent invocation would
# silently have no credentials and no toolchain while an interactive one worked.
bashrc="${WORKER_HOME}/.bashrc"
guard='[ -r /etc/profile.d/99-orca-worker.sh ] && . /etc/profile.d/99-orca-worker.sh'
grep -qF "$guard" "$bashrc" 2>/dev/null || printf '%s\n' "$guard" >>"$bashrc"
chown "$WORKER_USER:$WORKER_USER" "$bashrc"
unset token

# --- 7. Become sshd ---------------------------------------------------------
# exec, so sshd is PID 1 and receives the pod's signals directly. -D keeps it in
# the foreground; -e sends its log to stderr, where the pod log collector is.
log 'starting sshd as PID 1'
exec /usr/sbin/sshd -D -e
