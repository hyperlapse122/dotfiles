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


# --- 2. Per-pod SSH host keys ----------------------------------------------
# Generated here, never baked. Each worker has its own MagicDNS name, so the
# known_hosts collision that shared keys avoid does not arise -- and a host key
# in a public image is a host key everyone has.
log 'generating per-pod SSH host keys'
ssh-keygen -A

# --- 3. The runtime apply ---------------------------------------------------
# The build rendered these targets with opAvailable false, so they carry op://
# references rather than values. With Connect present the fact flips and the same
# chezmoi renders the real thing. One renderer, no second templating layer over
# what chezmoi already wrote.
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

# --- 4. authorized_keys -----------------------------------------------------
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

# --- 5. The proxy credential, resolved ONCE ---------------------------------
# Not through apiKeyHelper or the Codex auth.command: `op read` takes about 19s on
# this hardware and the Codex auth.timeout_ms default is 5000ms, so a
# per-invocation helper times out. Resolve here, write where a LOGIN SHELL will
# read it -- an export from this process would not survive into an sshd session.
if [[ -n "${ANTHROPIC_AUTH_TOKEN_REF:-}" ]]; then
  log 'resolving the model proxy credential'
  token=$(as_worker env OP_CONNECT_HOST="$OP_CONNECT_HOST" OP_CONNECT_TOKEN="$OP_CONNECT_TOKEN" \
    op read "${ANTHROPIC_AUTH_TOKEN_REF}")
  [[ -n "$token" ]] || die 'the proxy credential came back empty'
  # 0640 root:worker, not the 0644 a profile.d drop-in usually carries: this file
  # holds a live credential, and a login shell reads it as the worker, so group
  # read is all it needs. Written with a restrictive umask so it is never briefly
  # world-readable between creation and chmod.
  profile=/etc/profile.d/99-orca-worker.sh
  ( umask 037
  {
    printf '# Written by worker-entrypoint at pod start. Not baked into any layer.\n'
    printf 'export ANTHROPIC_AUTH_TOKEN=%q\n' "$token"
    [[ -n "${ANTHROPIC_BASE_URL:-}" ]] && printf 'export ANTHROPIC_BASE_URL=%q\n' "$ANTHROPIC_BASE_URL"
    [[ -n "${OP_CONNECT_HOST:-}" ]] && printf 'export OP_CONNECT_HOST=%q\n' "$OP_CONNECT_HOST"
    [[ -n "${OP_CONNECT_TOKEN:-}" ]] && printf 'export OP_CONNECT_TOKEN=%q\n' "$OP_CONNECT_TOKEN"
  } >"$profile" )
  chown "root:$WORKER_USER" "$profile"
  chmod 0640 "$profile"
  # /etc/profile.d covers a LOGIN shell, which is what an attached workspace gets.
  # `ssh worker <command>` is not a login shell and reads ~/.bashrc instead, so the
  # same file is sourced from there -- otherwise a scripted agent invocation would
  # silently have no credentials while an interactive one worked.
  bashrc="${WORKER_HOME}/.bashrc"
  guard='[ -r /etc/profile.d/99-orca-worker.sh ] && . /etc/profile.d/99-orca-worker.sh'
  grep -qF "$guard" "$bashrc" 2>/dev/null || printf '%s\n' "$guard" >>"$bashrc"
  chown "$WORKER_USER:$WORKER_USER" "$bashrc"
  unset token
fi

# --- 6. Become sshd ---------------------------------------------------------
# exec, so sshd is PID 1 and receives the pod's signals directly. -D keeps it in
# the foreground; -e sends its log to stderr, where the pod log collector is.
log 'starting sshd as PID 1'
exec /usr/sbin/sshd -D -e
