#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
scratch_root="${XDG_RUNTIME_DIR:-$HOME/.cache}/agent-scratch"
mkdir -p -- "$scratch_root"
scratch=$(mktemp -d "$scratch_root/shared-host-authd-flow.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
mkdir -p "$scratch/bin" "$scratch/target"
printf '#!/usr/bin/env bash\nprintf dummy-secret\n' >"$scratch/bin/op"
chmod 700 "$scratch/bin/op"
printf '[data]\n' >"$scratch/empty.toml"

fail() {
  printf 'shared-host-authd-flow: FAIL: %s\n' "$*" >&2
  exit 1
}

command -v chezmoi >/dev/null 2>&1 || fail 'chezmoi is required on PATH'
command -v node >/dev/null 2>&1 || fail 'node is required on PATH'

render() {
  local profile=$1 template=$2 output=$3 data
  case $profile in
    fedora)
      data='{"chezmoi":{"os":"linux","arch":"amd64","username":"fedora-fixture","osRelease":{"id":"fedora"}}}'
      ;;
    ubuntu-local)
      data='{"chezmoi":{"os":"linux","arch":"arm64","username":"ubuntu-fixture","osRelease":{"id":"ubuntu"}}}'
      ;;
    ubuntu-authd | shared-host)
      # `@` is the deterministic sharedHost/authd signal from facts.tmpl.
      data='{"chezmoi":{"os":"linux","arch":"arm64","username":"managed@example.invalid","osRelease":{"id":"ubuntu"}}}'
      ;;
    *) fail "unknown render profile $profile" ;;
  esac
  (
    cd -- "$repo_root"
    PATH="$scratch/bin:$PATH" chezmoi \
      --config "$scratch/empty.toml" \
      --source "$PWD" \
      --destination "$scratch/target" \
      --override-data "$data" \
      execute-template <"$template"
  ) >"$output"
}

without_facts() {
  local input=$1 output=$2
  node - "$input" "$output" <<'NODE'
const fs = require("node:fs");
const [input, output] = process.argv.slice(2);
const source = fs.readFileSync(input, "utf8");
const marker = "# Host facts — GENERATED from .chezmoidata/facts.yaml via\n";
const start = source.indexOf(marker);
if (start === -1) throw new Error(`generated facts block missing from ${input}`);
const end = source.indexOf("\n}\n", start);
if (end === -1) throw new Error(`generated facts block is unterminated in ${input}`);
fs.writeFileSync(output, `${source.slice(0, start)}${source.slice(end + 3)}`);
NODE
}

assert_shared_host_guard() {
  local template=$1 label=$2
  local rendered="$scratch/$label.rendered" body="$scratch/$label.body"
  render shared-host "$template" "$rendered"
  grep -Fqx '  FACT_SHARED_HOST=1' "$rendered" \
    || fail "$label did not render sharedHost=true for the managed-account profile"
  without_facts "$rendered" "$body"
  if ! node - "$body" <<'NODE'
const fs = require("node:fs");
const lines = fs.readFileSync(process.argv[2], "utf8").split(/\r?\n/);
const sharedGuard = lines.findIndex((line, index) =>
  /^# skip-declaration-v1 .*form=skip_here direction=harmless .*exit=exit-0$/.test(line) &&
  lines.slice(index, index + 12).some((candidate) => /printf .*shared host/i.test(candidate)) &&
  lines.slice(index, index + 12).some((candidate) => /^\s*exit 0\s*$/.test(candidate)),
);
process.exitCode = sharedGuard === -1 ? 1 : 0;
NODE
  then
    fail "$label does not render a terminating sharedHost skip_here guard"
  fi
}

for template in \
  .chezmoiscripts/30-linux/run_onchange_after_install-system-10-files.sh.tmpl \
  .chezmoiscripts/30-linux/run_onchange_after_install-system-20-host.sh.tmpl \
  .chezmoiscripts/30-linux/run_onchange_after_install-system-30-network.sh.tmpl
do
  assert_shared_host_guard "$template" "$(basename "${template%.tmpl}")"
done

login_template=.chezmoiscripts/30-linux/run_onchange_after_chsh-zsh.sh.tmpl
fedora_rendered="$scratch/chsh-fedora.rendered"
fedora_body="$scratch/chsh-fedora.body"
render fedora "$login_template" "$fedora_rendered"
without_facts "$fedora_rendered" "$fedora_body"
for forbidden in 'authctl user set-shell' 'UPDATE users SET shell' sqlite3 authd; do
  if grep -Fqi "$forbidden" "$fedora_body"; then
    fail "Fedora login-shell render contains Ubuntu-only authd control flow: $forbidden"
  fi
done

ubuntu_authd_rendered="$scratch/chsh-ubuntu-authd.rendered"
render ubuntu-authd "$login_template" "$ubuntu_authd_rendered"
for expected in 'authctl user set-shell' 'UPDATE users SET shell' sqlite3; do
  grep -Fqi "$expected" "$ubuntu_authd_rendered" \
    || fail "Ubuntu authd login-shell render is missing $expected"
done
[[ $(grep -Fc 'getent passwd' "$ubuntu_authd_rendered") -ge 2 ]] \
  || fail 'Ubuntu authd login-shell render does not confirm the updated shell with getent passwd'
if grep -Eqi '(^|[^[:alnum:]_])python3?([^[:alnum:]_]|$)' "$ubuntu_authd_rendered"; then
  fail 'Ubuntu authd login-shell render must not invoke Python'
fi
if grep -Fqi 'systemctl restart authd' "$ubuntu_authd_rendered"; then
  fail 'Ubuntu authd login-shell render must not restart authd'
fi

ubuntu_local_rendered="$scratch/chsh-ubuntu-local.rendered"
render ubuntu-local "$login_template" "$ubuntu_local_rendered"
grep -Fq 'chsh -s' "$ubuntu_local_rendered" \
  || fail 'Ubuntu local-account login-shell render lost the existing chsh path'
if grep -Fqi 'authctl user set-shell' "$ubuntu_local_rendered"; then
  fail 'Ubuntu local-account login-shell render incorrectly enters the authd path'
fi

printf '%s\n' 'shared-host-authd-flow: sharedHost guards and distro-compiled authd flow are correct'
