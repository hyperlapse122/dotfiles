#!/usr/bin/env bash
# Prove the direct-RPM reconciler renders correctly AND that the rendered body
# actually installs the artifact it verified.
#
# WHY EXECUTION AND NOT JUST A TEXT COMPARISON. The first version of this script
# returned the downloaded archive path on the same stdout it printed its progress
# line to, so the caller's command substitution captured both lines and every
# install path died on a nonexistent path. That body rendered cleanly, passed
# `bash -n`, and passed shellcheck. Only running it catches that class of defect,
# so this fixture stubs curl/rpm/dnf/sudo and asserts dnf received a real file
# whose digest is the one the script verified.
#
# The lock is replaced in a scratch source copy, the way test-jetson-installer-
# render.sh replaces facts.tmpl: the fixture digest must match the fixture bytes,
# and a second render with a bumped version proves the onchange trigger moves.
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
scratch_root=${XDG_RUNTIME_DIR:-${HOME:?HOME is required}/.cache}
mkdir -p -- "$scratch_root"
scratch=$(mktemp -d "$scratch_root/direct-rpms-render.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT

fail() { printf 'test-direct-rpms-render: FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'test-direct-rpms-render: ok - %s\n' "$*"; }

template=.chezmoiscripts/30-components/run_onchange_before_75-direct-rpms.sh.tmpl
[ -f "$repo_root/$template" ] || fail "missing $template"

mkdir -p -- "$scratch/bin" "$scratch/target" "$scratch/serve"
: >"$scratch/empty.toml"
printf '#!/usr/bin/env bash\ncase "${1-}" in whoami) printf dummy@example.invalid;; *) printf dummy-secret;; esac\n' \
  >"$scratch/bin/op"
chmod 700 -- "$scratch/bin/op"

# The fixture artifacts the stubbed curl serves, and their real digests.
printf 'orca-ide fixture payload\n' >"$scratch/serve/orca-ide-9.9.9.x86_64.rpm"
printf 'teamviewer fixture payload\n' >"$scratch/serve/teamviewer_88.8.8.x86_64.rpm"
orca_sha=$(sha256sum "$scratch/serve/orca-ide-9.9.9.x86_64.rpm" | cut -d' ' -f1)

source_root="$scratch/source"
mkdir -p -- "$source_root"
cp -a -- "$repo_root/.chezmoidata" "$repo_root/.chezmoitemplates" "$repo_root/.chezmoiscripts" \
  "$source_root/"

# Rewrite only the two entries under test; every other tool keeps its real entry
# so release-lock-ref.tmpl resolves exactly as it does in production.
write_lock() {
  local orca_version=$1 tv_version=$2
  python3 - "$source_root/.chezmoidata/releases.json" "$orca_version" "$tv_version" "$orca_sha" <<'PY'
import json, sys
path, orca_version, tv_version, orca_sha = sys.argv[1:5]
lock = json.load(open(path))
tools = lock["releases"]["tools"]
tools["orca-ide"] = {
    "kind": "githubRelease",
    "source": "stablyai/orca",
    "version": orca_version,
    "artifacts": {
        arch: {
            "url": f"https://fixture.invalid/{orca_version.lstrip('v')}/orca-ide-{orca_version.lstrip('v')}.{rpm}.rpm",
            "sha256": orca_sha,
        }
        for arch, rpm in (("linux-amd64", "x86_64"), ("linux-arm64", "aarch64"))
    },
}
tools["teamviewer"] = {
    "kind": "vendorManifest",
    "source": "https://download.teamviewer.com/download/linux/teamviewer.x86_64.rpm",
    "version": tv_version,
}
json.dump(lock, open(path, "w"), indent=2, sort_keys=True)
PY
}

render() {
  env PATH="$scratch/bin:$PATH" chezmoi --config "$scratch/empty.toml" \
    --source "$source_root" --destination "$scratch/target" \
    --override-data '{"chezmoi":{"os":"linux","arch":"amd64","username":"fixture","osRelease":{"id":"fedora"}}}' \
    execute-template <"$repo_root/$template"
}

write_lock v9.9.9 88.8.8
render >"$scratch/rendered.sh"

# --- render assertions -------------------------------------------------------

grep -q "resolve_action \"\${pkg}\" '9.9.9'" "$scratch/rendered.sh" \
  || fail "orca version kept its leading v; rpm -q could never match it"
pass "the locked tag's leading v is stripped for the version comparison"

grep -q "version_88x/teamviewer_88.8.8.x86_64.rpm" "$scratch/rendered.sh" \
  || fail "TeamViewer URL was not composed from the locked version"
pass "the TeamViewer URL composes its major-version directory from the lock"

# The shared guards carry `|| true` on their own skip-record bookkeeping; what
# must never be swallowed is an install, a download, or a key import.
grep -E '(dnf|curl|rpm --import).*\|\| true' "$scratch/rendered.sh" \
  && fail "a swallowed failure path survived on an install, download or key import"
pass "no install, download or key import swallows its failure"

# A locked-version change must move the rendered bytes; that IS the update trigger.
write_lock v9.9.10 88.8.8
render >"$scratch/rendered-bumped.sh"
cmp -s "$scratch/rendered.sh" "$scratch/rendered-bumped.sh" \
  && fail "a locked-version bump left the rendered bytes unchanged; onchange would never re-run"
pass "a locked-version bump changes the rendered bytes"

# Non-Fedora hosts render nothing at all, so no runtime skip is declared.
env PATH="$scratch/bin:$PATH" chezmoi --config "$scratch/empty.toml" \
  --source "$source_root" --destination "$scratch/target" \
  --override-data '{"chezmoi":{"os":"linux","arch":"amd64","username":"fixture","osRelease":{"id":"ubuntu"}}}' \
  execute-template <"$repo_root/$template" >"$scratch/rendered-ubuntu.sh"
[ -s "$scratch/rendered-ubuntu.sh" ] && [ -n "$(tr -d '[:space:]' <"$scratch/rendered-ubuntu.sh")" ] \
  && fail "the template rendered a body on a non-Fedora host"
pass "a non-Fedora host renders an empty body"

# --- execution assertions ----------------------------------------------------
#
# Everything the rendered body reaches out to is stubbed, so this runs the real
# control flow without touching the host.

write_lock v9.9.9 88.8.8
render >"$scratch/rendered.sh"

cat >"$scratch/bin/curl" <<STUB
#!/usr/bin/env bash
url=""; out=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -o) out=\$2; shift 2 ;;
    -*) shift ;;
    *) url=\$1; shift ;;
  esac
done
src="$scratch/serve/\${url##*/}"
[ -f "\$src" ] || exit 22
cp -- "\$src" "\$out"
STUB

# rpm -q: nothing installed. rpm -qp: claim the pinned TeamViewer key.
cat >"$scratch/bin/rpm" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  -q)  exit 1 ;;
  -qp) printf 'RSA/SHA256, Wed 20 Aug 2026, Key ID ef9dbdc73b7d1a07' ;;
  --import) : ;;
esac
STUB

# dnf records the argv of every install, and whether the file it was handed
# existed AT THAT MOMENT -- the script's EXIT trap removes its scratch dir, so
# checking afterwards would test the trap rather than the install.
cat >"$scratch/bin/dnf" <<STUB
#!/usr/bin/env bash
for arg; do :; done
if [ -f "\$arg" ]; then state=present; else state=missing; fi
printf '%s\t%s\n' "\$state" "\$*" >>"$scratch/dnf-calls"
STUB

# sudo/timeout just run what they are given; the ladder only needs sudo -n true.
printf '#!/usr/bin/env bash\n[ "${1-}" = "-n" ] && [ "${2-}" = "true" ] && exit 0\nwhile [ $# -gt 0 ]; do case "$1" in -n|-A) shift;; *) break;; esac; done\nexec "$@"\n' \
  >"$scratch/bin/sudo"
printf '#!/usr/bin/env bash\nshift\nexec "$@"\n' >"$scratch/bin/timeout"
chmod 700 -- "$scratch/bin/curl" "$scratch/bin/rpm" "$scratch/bin/dnf" "$scratch/bin/sudo" "$scratch/bin/timeout"

: >"$scratch/dnf-calls"
if ! env PATH="$scratch/bin:$PATH" HOME="$scratch" bash "$scratch/rendered.sh" >"$scratch/run.log" 2>&1; then
  printf 'test-direct-rpms-render: rendered script exited non-zero:\n' >&2
  cat "$scratch/run.log" >&2
  fail "the rendered script could not complete against stubs"
fi
pass "the rendered script runs to completion against stubbed curl/rpm/dnf"

[ -s "$scratch/dnf-calls" ] || fail "no install was attempted"
installed_count=$(wc -l <"$scratch/dnf-calls")
[ "$installed_count" -eq 2 ] || fail "expected 2 installs, saw $installed_count"
pass "both entries reached the package manager"

# The defect this fixture exists for: the path handed to dnf must be a real file,
# not a progress line the caller captured alongside it.
while IFS=$'\t' read -r state call; do
  [ "$state" = present ] \
    || fail "dnf was handed a path that did not exist: '${call##* }' (from: $call)"
done <"$scratch/dnf-calls"
pass "each install received an existing file, not captured log output"

grep -q 'localpkg_gpgcheck=0' "$scratch/dnf-calls" || fail "the unsigned entry lost its documented gpgcheck setting"
grep -q 'localpkg_gpgcheck=1' "$scratch/dnf-calls" || fail "the signed entry lost its gpgcheck enforcement"
pass "each entry kept its own signature policy"

# A tampered artifact must abort rather than install.
printf 'tampered\n' >"$scratch/serve/orca-ide-9.9.9.x86_64.rpm"
: >"$scratch/dnf-calls"
if env PATH="$scratch/bin:$PATH" HOME="$scratch" bash "$scratch/rendered.sh" >"$scratch/run-tampered.log" 2>&1; then
  fail "a digest mismatch did not abort the script"
fi
grep -qi 'checksum mismatch' "$scratch/run-tampered.log" \
  || fail "the abort did not name the checksum mismatch"
grep -q 'localpkg_gpgcheck=0' "$scratch/dnf-calls" \
  && fail "the tampered artifact was installed anyway"
pass "a digest mismatch aborts before the install and names the mismatch"

printf 'test-direct-rpms-render: all cases passed\n'
