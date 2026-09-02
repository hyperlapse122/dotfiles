#!/usr/bin/env bash
# Prove the Jetson installer body actually renders, and that its neighbours stay
# inert off a Thor.
#
# The CI arm64 runner is not a Jetson: `/etc/nv_tegra_release` is absent, so the
# `jetson` fact is false there and the whole installer body is gated out. Every
# other arm64 assertion therefore proves nothing about this script. This fixture
# supplies the fact map directly, which is the only way to reach the body without
# a board.
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/jetson-installer-render.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT

mkdir -p -- "$scratch/bin" "$scratch/target"
: >"$scratch/empty.toml"
printf '#!/usr/bin/env bash\ncase "${1-}" in whoami) printf dummy@example.invalid;; *) printf dummy-secret;; esac\n' \
  >"$scratch/bin/op"
chmod 700 -- "$scratch/bin/op"

source_root="$scratch/source"
mkdir -p -- "$source_root"
cp -a -- "$repo_root/.chezmoidata" "$repo_root/.chezmoitemplates" "$repo_root/.chezmoiscripts" \
  "$repo_root/system" "$source_root/"

# The fact map replaces facts.tmpl wholesale: every fact this repository declares
# must appear, because a consumer reading a missing key would silently get nil
# rather than the value under test.
write_facts() {
  local jetson=$1 shared_host=$2
  cat >"$source_root/.chezmoitemplates/facts.tmpl" <<FACTS
os: linux
distro: ubuntu
desktop: gnome
nvidia: false
thinkpad: false
jetson: ${jetson}
vm: false
virt: false
sddmBreeze: false
gdm: false
fprintdPam: false
headless: false
container: false
sharedHost: ${shared_host}
ux534: false
FACTS
}

render() {
  local template=$1 out=$2
  env PATH="$scratch/bin:$PATH" chezmoi \
    --config "$scratch/empty.toml" \
    --source "$source_root" \
    --destination "$scratch/target" \
    --override-data '{"chezmoi":{"osRelease":{"id":"ubuntu"},"arch":"arm64"}}' \
    execute-template <"$template" >"$out"
}

fail() {
  printf 'jetson-installer-render: FAIL: %s\n' "$1" >&2
  exit 1
}

installer="$repo_root/.chezmoiscripts/20-linux-ubuntu/run_onchange_before_jetson.sh.tmpl"

write_facts true false
render "$installer" "$scratch/on.sh"
bash -n "$scratch/on.sh" || fail 'the jetson=true render is not valid shell'
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -S warning "$scratch/on.sh" || fail 'the jetson=true render fails shellcheck'
fi

# The body is the point of the fixture: assert the pieces that only exist on a
# Thor, so a gate that silently stops emitting them is caught here.
for needle in \
  'install_apt "nvidia-jetpack"' \
  'install_apt "libssl-dev"' \
  'install_apt "libdbus-1-dev"' \
  'nvidia-l4t-apt-source.list' \
  '$2 == "VALIDSIG"' \
  '/opt/1Password/after-install.sh' \
  '/usr/share/applications/1password.desktop' \
  'NOTE: Jetson package and desktop changes may require service activation.'
do
  grep -qF -- "$needle" "$scratch/on.sh" || fail "the jetson=true render omits ${needle}"
done
for forbidden in nvidia-cuda-toolkit mokutil MOK dkms 1password-latest.tar.gz 'systemctl start' 'systemctl restart' 'systemctl reload' 'systemctl enable --now'; do
  ! grep -qF -- "$forbidden" "$scratch/on.sh" \
    || fail "the jetson=true render names the forbidden ${forbidden}"
done

write_facts false false
render "$installer" "$scratch/off.sh"
[[ ! -s "$scratch/off.sh" ]] || fail 'the jetson=false render is not empty'

# The lock lookups MUST sit inside the gate: release-lock-ref.tmpl hard-fails on a
# missing artifact key and this tool publishes linux-arm64 only, so a hoisted
# lookup would break every non-Jetson render the day that entry moves or is
# renamed. A render cannot show this while the key happens to resolve, so the
# ordering is asserted against the template source instead.
gate_line=$(grep -n '^{{ if and (eq .chezmoi.os "linux")' -- "$installer" | cut -d: -f1)
[[ -n "$gate_line" ]] || fail 'the installer gate line was not found'
while IFS=: read -r line _; do
  [[ "$line" -gt "$gate_line" ]] \
    || fail "a release-lock lookup on line ${line} precedes the gate on line ${gate_line}"
done < <(grep -n 'release-lock-ref.tmpl' -- "$installer")

printf 'jetson-installer-render: PASS\n'
