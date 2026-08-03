#!/usr/bin/env bash
# .ci/test-vscodium-extensions.sh — proves the extension reconcilers converge
# against a stubbed `codium`, WITHOUT a live HOME and WITHOUT a real VSCodium:
#   - the POSIX half (rendered for darwin, exercising the widened gate) and
#     the Windows PowerShell half (run under pwsh) both manage EXACTLY the set
#     declared in .chezmoidata/vscodium.yaml — the same managed set on both;
#   - first run installs missing + force-updates installed declared entries,
#     second run converges through the identical command sequence;
#   - additive only: a hand-installed extension is never uninstalled;
#   - fail-closed: a failed install exits non-zero (retry on next apply), and
#     a missing `codium` soft-skips with success.
set -euo pipefail
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
scratch_root="${XDG_RUNTIME_DIR:-$HOME/.cache}/agent-scratch"
mkdir -p "$scratch_root"
scratch=$(mktemp -d "$scratch_root/vscodium-extensions.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
printf '[data]\n' >"$scratch/empty.toml"
mkdir -p "$scratch/bin" "$scratch/nobin"

# The declared managed set, straight from the authority.
mapfile -t DECLARED < <(sed -n 's/^    - //p' "$repo_root/.chezmoidata/vscodium.yaml")
((${#DECLARED[@]} > 0)) || { echo 'no extensions parsed from vscodium.yaml' >&2; exit 1; }

# A codium-less PATH for the soft-skip case (only the tools the scripts need).
for tool in tr grep printf; do ln -s "$(command -v "$tool")" "$scratch/nobin/"; done

# --- POSIX half (rendered for darwin) ---------------------------------------
chezmoi --config "$scratch/empty.toml" --source "$repo_root" \
  --override-data '{"chezmoi":{"os":"darwin","arch":"arm64"}}' execute-template \
  <"$repo_root/.chezmoiscripts/30-linux/run_onchange_after_install-vscodium-extensions.sh.tmpl" \
  >"$scratch/reconcile.sh"
# The widened gate must render a real script for darwin, not an empty guard.
grep -q '^EXTENSIONS=(' "$scratch/reconcile.sh" || { echo 'darwin render produced no EXTENSIONS block' >&2; exit 1; }
for ext in "${DECLARED[@]}"; do
  grep -qxF "  \"$ext\"" "$scratch/reconcile.sh" || { echo "sh managed set missing $ext" >&2; exit 1; }
done

# Stub codium: logs every invocation; --list-extensions serves the fixture;
# --install-extension records success and can be failed via FAIL_EXT.
cat >"$scratch/bin/codium" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CODIUM_LOG"
case "${1:-}" in
  --list-extensions) cat "$CODIUM_INSTALLED" ;;
  --install-extension)
    [[ $2 == "${FAIL_EXT:-}" ]] && exit 1
    grep -qixF -- "$2" "$CODIUM_INSTALLED" 2>/dev/null || printf '%s\n' "$2" >>"$CODIUM_INSTALLED"
    ;;
esac
exit 0
STUB
chmod +x "$scratch/bin/codium"

# Fixture: one declared extension already installed (update path) plus one
# hand-installed extension the reconciler must NEVER touch.
printf '%s\n' "${DECLARED[0]}" 'user.hand-installed' >"$scratch/installed"

run_posix() { # run_posix — fresh log, stubbed PATH
  : >"$scratch/log"
  CODIUM_LOG="$scratch/log" CODIUM_INSTALLED="$scratch/installed" \
    PATH="$scratch/bin:/usr/bin:/bin" bash "$scratch/reconcile.sh"
}

expected_sequence() { # expected_sequence <out-file>
  printf -- '--list-extensions\n' >"$1"
  for ext in "${DECLARED[@]}"; do
    printf -- '--install-extension %s --force\n' "$ext" >>"$1"
  done
}

expected_sequence "$scratch/expected"
run_posix
cmp "$scratch/expected" "$scratch/log" || { echo 'posix first-run command sequence wrong' >&2; cat "$scratch/log" >&2; exit 1; }
# Second apply converges: identical idempotent sequence, no uninstalls ever.
run_posix
cmp "$scratch/expected" "$scratch/log" || { echo 'posix second run did not converge' >&2; exit 1; }
grep -qxF 'user.hand-installed' "$scratch/installed" || { echo 'posix reconciler dropped a hand-installed extension' >&2; exit 1; }
! grep -q 'uninstall' "$scratch/log" || { echo 'posix reconciler uninstalled something' >&2; exit 1; }
# Failure propagates (non-zero) so chezmoi retries on next apply.
if CODIUM_LOG="$scratch/log" CODIUM_INSTALLED="$scratch/installed" FAIL_EXT="${DECLARED[1]}" \
  PATH="$scratch/bin:/usr/bin:/bin" bash "$scratch/reconcile.sh" >/dev/null 2>&1; then
  echo 'posix reconciler accepted a failed install' >&2
  exit 1
fi
# Missing codium soft-skips with success. Absolute bash path: the PATH= prefix
# would make the shell look up bash itself in the stripped PATH.
bash_bin=$(command -v bash)
PATH="$scratch/nobin" "$bash_bin" "$scratch/reconcile.sh" >/dev/null 2>"$scratch/skip.err" \
  || { echo 'posix reconciler did not soft-skip without codium' >&2; exit 1; }
grep -q 'skipping' "$scratch/skip.err" || { echo 'posix soft-skip was silent' >&2; exit 1; }

# --- Windows half (pwsh, stubbed codium function) ---------------------------
chezmoi --config "$scratch/empty.toml" --source "$repo_root" \
  --override-data '{"chezmoi":{"os":"windows","arch":"amd64"}}' execute-template \
  <"$repo_root/.chezmoiscripts/30-windows/run_onchange_after_install-vscodium-extensions.ps1.tmpl" \
  >"$scratch/reconcile.ps1"

RECONCILE_SCRIPT="$scratch/reconcile.ps1" DECLARED_CSV="$(IFS=,; printf '%s' "${DECLARED[*]}")" \
  pwsh -NoProfile -Command - <<'PS'
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
try {
  $declared = $env:DECLARED_CSV -split ','
  # Fixture trackers are named Fixture*: the reconciler is DOT-SOURCED, so its
  # own variables ($installed, $extensions, ...) land in this shared scope and
  # would silently overwrite any colliding fixture state (PS names are
  # case-insensitive).
  $global:FixtureCalls = [Collections.Generic.List[string]]::new()
  $global:LASTEXITCODE = 0
  $global:FixtureInstalled = [Collections.Generic.List[string]]::new()
  $global:FixtureInstalled.Add($declared[0])
  $global:FixtureInstalled.Add('user.hand-installed')
  function global:codium {
    $global:FixtureCalls.Add(($args -join ' '))
    $global:LASTEXITCODE = 0
    if ($args[0] -eq '--list-extensions') { $global:FixtureInstalled | ForEach-Object { $_ } }
    elseif ($args[0] -eq '--install-extension') {
      if ($args[1] -eq $env:FAIL_EXT) { $global:LASTEXITCODE = 1; return }
      if ($global:FixtureInstalled -notcontains $args[1]) { $global:FixtureInstalled.Add($args[1]) }
    }
  }

  $expected = @('--list-extensions') + @($declared | ForEach-Object { "--install-extension $_ --force" })

  . $env:RECONCILE_SCRIPT
  if (($global:FixtureCalls -join "`n") -ne ($expected -join "`n")) { throw "ps1 first-run sequence wrong: $($global:FixtureCalls -join '; ')" }
  $global:FixtureCalls.Clear()
  . $env:RECONCILE_SCRIPT
  if (($global:FixtureCalls -join "`n") -ne ($expected -join "`n")) { throw 'ps1 second run did not converge through the identical sequence' }
  if (($global:FixtureCalls -join "`n") -match 'uninstall') { throw 'ps1 reconciler uninstalled something' }
  if ($global:FixtureInstalled -notcontains 'user.hand-installed') { throw 'ps1 reconciler dropped a hand-installed extension' }
  $env:FAIL_EXT = $declared[1]
  $global:FixtureCalls.Clear()
  try { . $env:RECONCILE_SCRIPT; throw 'ps1 reconciler accepted a failed install' }
  catch { if ($_.Exception.Message -notmatch 'will retry on next apply') { throw } }
  $env:FAIL_EXT = $null
  # Missing codium soft-skips: return (not throw) with a warning. Strip PATH so
  # no real codium can be found, and remove the stub.
  $env:Path = [IO.Path]::GetTempPath()
  Remove-Item function:codium
  . $env:RECONCILE_SCRIPT
} catch {
  Write-Host "FIXTURE FAILED: $($_.Exception.Message)"
  exit 1
}
exit 0
PS

printf '%s\n' 'vscodium extension convergence passed'
