#!/usr/bin/env bash
set -euo pipefail

# Proves the delivered `fff-mcp` binary actually serves MCP.
#
# Every other gate covering this tool is a render or a manifest check: they read
# `.chezmoidata/releases.json`, expand a template, and compare strings. All of
# them pass while the binary is unusable — a wrong musl build, a missing runtime
# dependency, or a renamed tool would surface only in a live agent session.
#
# It also pins the tool NAMES. Issue 434 and the upstream README both advertise
# `ffgrep`, `fffind`, and `fff-multi-grep`; the shipped v0.10.6 server declares
# `find_files`, `grep`, and `multi_grep` (crates/fff-mcp/src/server.rs). Nothing
# but a real `tools/list` would have caught that, and a harness that renamed a
# tool between releases would silently break the agents that call it.
#
# The binary is fetched from the same locked URL chezmoi would use and verified
# against the same recorded digest, so this gate trusts nothing the lock does not
# already assert. A platform the lock carries no artifact for is skipped, not
# failed: this runs on whatever runner CI provides.

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
lock=${1:-$repo_root/.chezmoidata/releases.json}

fail() {
  printf 'fff-mcp runtime: %s\n' "$1" >&2
  [ -z "${2:-}" ] || printf '%s\n' "$2" >&2
  printf '::error::fff-mcp runtime: %s\n' "$1"
  exit 1
}

skip() {
  printf 'fff-mcp runtime: skipped - %s\n' "$1"
  exit 0
}

command -v jq >/dev/null 2>&1 || fail 'jq is required'
command -v python3 >/dev/null 2>&1 || fail 'python3 is required'
[ -f "$lock" ] || fail "lock not found: $lock"

# The lock keys the host the way release-lock does: linux/darwin plus amd64/arm64.
case "$(uname -s)" in
  Linux) os=linux ;;
  Darwin) os=darwin ;;
  *) skip "unsupported OS $(uname -s)" ;;
esac
case "$(uname -m)" in
  x86_64 | amd64) arch=amd64 ;;
  aarch64 | arm64) arch=arm64 ;;
  *) skip "unsupported architecture $(uname -m)" ;;
esac

# Prefer the musl artifact on a musl host, mirroring command-manifest.tmpl's
# probe order, and fall back to the glibc key.
platform="$os-$arch"
if [ "$os" = linux ] && ! ldd /bin/ls 2>/dev/null | grep -q 'libc\.so\.6'; then
  platform="$platform-musl"
fi

entry=$(jq -r --arg p "$platform" '.releases.tools["fff-mcp"].artifacts[$p] // empty' "$lock")
[ -n "$entry" ] || skip "lock carries no fff-mcp artifact for $platform"

url=$(printf '%s' "$entry" | jq -r '.url')
want=$(printf '%s' "$entry" | jq -r '.sha256 // empty')
[ -n "$want" ] || fail "lock entry for $platform carries no sha256"

scratch=$(mktemp -d "${TMPDIR:-/tmp}/fff-mcp-runtime-XXXXXX")
trap 'rm -rf "$scratch"' EXIT
bin="$scratch/fff-mcp"

curl -fsSL --retry 3 -o "$bin" "$url" || fail "could not download $url"

got=$(sha256sum "$bin" 2>/dev/null | cut -d' ' -f1) ||
  got=$(shasum -a 256 "$bin" | cut -d' ' -f1)
[ "$got" = "$want" ] ||
  fail "digest mismatch for $platform" "  expected $want"$'\n'"  got      $got"
chmod +x "$bin"

# A fixture repository, so the indexed root is a real git tree this gate owns
# rather than whatever directory CI happened to start in.
fixture="$scratch/fixture"
mkdir -p "$fixture"
printf 'the needle lives here\n' >"$fixture/haystack.txt"
git -C "$fixture" init -q
git -C "$fixture" add -A
git -C "$fixture" -c user.name=ci -c user.email=ci@example.invalid commit -qm init

# One stdio session: initialize, then tools/list. The server speaks
# newline-delimited JSON-RPC, so the driver writes both requests and reads until
# it has the response to id 2 or the deadline passes.
tools=$(cd "$fixture" && python3 - "$bin" <<'PY'
import json, subprocess, sys, threading

binary = sys.argv[1]
proc = subprocess.Popen(
    [binary, "--no-update-check"],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.DEVNULL,
    text=True,
)


def request(obj):
    proc.stdin.write(json.dumps(obj) + "\n")
    proc.stdin.flush()


request({
    "jsonrpc": "2.0",
    "id": 1,
    "method": "initialize",
    "params": {
        "protocolVersion": "2025-06-18",
        "capabilities": {},
        "clientInfo": {"name": "ci-gate", "version": "0"},
    },
})

names, error = [], None


def pump():
    global names, error
    for line in proc.stdout:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            continue
        if msg.get("id") == 1:
            if "error" in msg:
                error = f"initialize failed: {msg['error']}"
                return
            request({"jsonrpc": "2.0", "method": "notifications/initialized"})
            request({"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}})
        elif msg.get("id") == 2:
            if "error" in msg:
                error = f"tools/list failed: {msg['error']}"
                return
            names = [t["name"] for t in msg.get("result", {}).get("tools", [])]
            return


worker = threading.Thread(target=pump, daemon=True)
worker.start()
worker.join(timeout=120)

proc.kill()
proc.wait(timeout=10)

if error:
    print(error, file=sys.stderr)
    sys.exit(1)
if not names:
    print("no tools/list response before the deadline", file=sys.stderr)
    sys.exit(1)
print(" ".join(sorted(names)))
PY
) || fail 'the server did not complete an initialize + tools/list handshake'

expected='find_files grep multi_grep'
[ "$tools" = "$expected" ] ||
  fail 'tools/list returned an unexpected tool set' \
    "  expected: $expected"$'\n'"  got:      $tools"

printf 'fff-mcp runtime: ok - %s serves %s\n' "$platform" "$tools"
