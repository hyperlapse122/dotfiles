#!/usr/bin/env bash
# test-wifi-import-gates.sh — hermetic proof that the Wi-Fi importers deploy
# only on their own OS, render per-OS with 1Password references resolved, keep
# secrets out of SOURCE files, and use only their platform's official Wi-Fi
# commands. Runs on a Linux CI worker; never touches live Wi-Fi (render only).
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
scratch_parent=${XDG_RUNTIME_DIR:-${HOME:?HOME is required}/.cache}
mkdir -p "$scratch_parent"
scratch=$(mktemp -d "$scratch_parent/wifi-import-gates.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
mkdir -p "$scratch/home" "$scratch/bin"
printf '[data]\n' >"$scratch/empty.toml"
chezmoi_bin=$(type -P chezmoi)

fail() { printf 'wifi-import gates: %s\n' "$*" >&2; exit 1; }

# op stub: deterministic per-item fixture values so the render can be asserted
# (and so the platform fixtures' leak scans know exactly which plaintext to
# hunt). onepasswordRead invokes `op read "<ref>"` as a single argument.
cat >"$scratch/bin/op" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *"KT HomeHub 5G/name"*)     printf 'fixture-ssid-home' ;;
  *"KT HomeHub 5G/password"*) printf 'fixture-psk-home' ;;
  *"CPS-01/name"*)            printf 'fixture-ssid-cps' ;;
  *"CPS-01/password"*)        printf 'fixture-psk-cps' ;;
  *)                          printf 'fixture-dummy' ;;
esac
EOF
chmod 0755 "$scratch/bin/op"

render() {
  local os=$1 input=$2 output=$3
  mkdir -p "$scratch/target-$os"
  env HOME="$scratch/home" PATH="$scratch/bin:/usr/bin:/bin" \
    "$chezmoi_bin" --config "$scratch/empty.toml" --source "$repo_root" \
      --destination "$scratch/target-$os" --override-data "{\"chezmoi\":{\"os\":\"$os\"}}" \
      execute-template <"$input" >"$output"
}

# --- deployed mode: source files exist with the owner-only (private_)
# --- executable attribute -----------------------------------------------
linux_tool=dot_local/bin/private_executable_import-wifi-1password.tmpl
macos_tool=dot_local/bin/private_executable_import-wifi-1password-macos.sh.tmpl
windows_tool=dot_local/bin/private_executable_import-wifi-1password.ps1.tmpl
for path in "$linux_tool" "$macos_tool" "$windows_tool" \
  .chezmoiignore .chezmoidata/networking.yaml \
  .ci/fixtures/wifi-secret-handoff/profiles .ci/fixtures/wifi-secret-handoff/netsh.cmd; do
  [[ -f "$repo_root/$path" ]] || fail "missing source surface $path"
done

# --- platform gates: render the source-root .chezmoiignore per OS --------
for os in linux darwin windows; do
  render "$os" "$repo_root/.chezmoiignore" "$scratch/ignore-$os"
done

# linux: NetworkManager tool deploys; macOS tool and every .ps1 gated out.
grep -qFx '.local/bin/import-wifi-1password-macos.sh' "$scratch/ignore-linux" \
  || fail "linux ignore must gate import-wifi-1password-macos"
grep -qFx '.local/bin/*.ps1' "$scratch/ignore-linux" || fail "linux ignore must gate *.ps1"
grep -qFx '.local/bin/import-wifi-1password' "$scratch/ignore-linux" \
  && fail "linux ignore must NOT gate import-wifi-1password"

# darwin: macOS tool deploys; Linux tool and every .ps1 gated out.
grep -qFx '.local/bin/import-wifi-1password' "$scratch/ignore-darwin" \
  || fail "darwin ignore must gate import-wifi-1password"
grep -qFx '.local/bin/*.ps1' "$scratch/ignore-darwin" || fail "darwin ignore must gate *.ps1"
grep -qFx '.local/bin/import-wifi-1password-macos.sh' "$scratch/ignore-darwin" \
  && fail "darwin ignore must NOT gate import-wifi-1password-macos"

# windows: only .ps1 deploys; both POSIX tools gated out.
grep -qFx '.local/bin/*' "$scratch/ignore-windows" || fail "windows ignore must gate *"
grep -qFx '!.local/bin/*.ps1' "$scratch/ignore-windows" || fail "windows ignore must un-gate !*.ps1"
grep -qFx '.local/bin/import-wifi-1password' "$scratch/ignore-windows" \
  || fail "windows ignore must gate import-wifi-1password"
grep -qFx '.local/bin/import-wifi-1password-macos.sh' "$scratch/ignore-windows" \
  || fail "windows ignore must gate import-wifi-1password-macos"

# --- renderability + platform-command identity per OS --------------------
render linux "$repo_root/$linux_tool" "$scratch/tool-linux"
grep -q 'nmcli' "$scratch/tool-linux" || fail "linux tool must drive NetworkManager (nmcli)"
grep -q 'fixture-psk-home' "$scratch/tool-linux" \
  || fail "linux render must resolve op:// refs at render time"
grep -qE 'netsh|profiles install' "$scratch/tool-linux" \
  && fail "linux tool must not reference native Windows/macOS commands"

render darwin "$repo_root/$macos_tool" "$scratch/tool-darwin"
grep -q 'profiles install' "$scratch/tool-darwin" \
  || fail "macOS tool must drive profiles(1)"
grep -q '/usr/libexec/PlistBuddy' "$scratch/tool-darwin" \
  || fail "macOS tool must parse its manifest with PlistBuddy (no jq/python dependency)"
grep -q 'fixture-psk-home' "$scratch/tool-darwin" \
  || fail "macOS render must resolve op:// refs at render time"
grep -q 'trap cleanup EXIT' "$scratch/tool-darwin" \
  || fail "macOS tool must delete plaintext through one shared EXIT trap"
grep -qE 'nmcli|netsh' "$scratch/tool-darwin" \
  && fail "macOS tool must not reference Linux/Windows commands"

render windows "$repo_root/$windows_tool" "$scratch/tool-windows"
grep -q "wlan', 'add', 'profile'" "$scratch/tool-windows" \
  || fail "windows tool must drive netsh wlan add profile"
grep -q 'set profileorder' "$scratch/tool-windows" \
  || fail "windows tool must apply priority via netsh wlan set profileorder"
grep -q 'fixture-psk-home' "$scratch/tool-windows" \
  || fail "windows render must resolve op:// refs at render time"
grep -q '} finally {' "$scratch/tool-windows" \
  || fail "windows tool must delete plaintext through one shared finally"
grep -qE 'nmcli|profiles install' "$scratch/tool-windows" \
  && fail "windows tool must not reference Linux/macOS commands"

# --- secret handoff: PSKs ride a transient owner-only FILE, never argv ---
grep -q 'keyMaterial' "$scratch/tool-windows" \
  || fail "windows tool must hand the PSK to netsh via profile XML keyMaterial"
grep -q '<key>Password</key>' "$scratch/tool-windows" \
  && fail "windows tool must not emit a macOS payload"
grep -q '<key>Password</key>' "$scratch/tool-darwin" \
  || fail "macOS tool must hand the PSK to profiles(1) via payload Password"
grep -q 'filename=' "$scratch/tool-windows" \
  || fail "windows netsh call must reference the transient file, not the key"

# --- source hygiene: secrets exist ONLY at render time -------------------
for path in "$linux_tool" "$macos_tool" "$windows_tool" .chezmoidata/networking.yaml; do
  grep -q 'fixture-psk' "$repo_root/$path" \
    && fail "$path must not contain fixture plaintext (secrets resolve at render)"
done
grep -q 'op://' "$repo_root/.chezmoidata/networking.yaml" \
  || fail "networking.yaml must keep referencing 1Password via op:// refs"

printf 'wifi-import gates: ok\n'
