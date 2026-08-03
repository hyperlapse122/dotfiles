#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
scratch_root="${XDG_RUNTIME_DIR:-$HOME/.cache}/agent-scratch"
mkdir -p "$scratch_root"
scratch=$(mktemp -d "$scratch_root/windows-trust.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
mkdir -p "$scratch/bin"
printf '#!/usr/bin/env bash\nprintf dummy-secret\n' >"$scratch/bin/op"
chmod 700 "$scratch/bin/op"
printf '[data]\n' >"$scratch/empty.toml"
render() {
  PATH="$scratch/bin:$PATH" chezmoi --config "$scratch/empty.toml" --source "$repo_root" \
    --override-data '{"chezmoi":{"os":"windows","arch":"amd64"}}' execute-template <"$repo_root/$1" >"$2"
}
render .chezmoiscripts/80-keys/run_once_before_import-gpg-key.ps1.tmpl "$scratch/import-gpg.ps1"
render .chezmoiscripts/80-keys/run_before_probe-gpg-cache-ready.ps1.tmpl "$scratch/probe-gpg.ps1"
render .chezmoiscripts/10-auth/run_onchange_after_auth-github.ps1.tmpl "$scratch/auth-github.ps1"
render .chezmoiscripts/10-auth/run_onchange_after_auth-gitlab.ps1.tmpl "$scratch/auth-gitlab.ps1"
for script in "$scratch"/*.ps1; do
  SCRIPT_PATH="$script" pwsh -NoProfile -Command '[void][scriptblock]::Create([IO.File]::ReadAllText($env:SCRIPT_PATH))'
done

grep -F 'IdentityAgent //./pipe/OpenSSH-ssh-agent' "$repo_root/dot_ssh/.config_windows" >/dev/null
grep -F 'ForwardAgent no' "$repo_root/dot_ssh/.config_windows" >/dev/null
grep -F 'StrictHostKeyChecking yes' "$repo_root/dot_ssh/.config_windows" >/dev/null
if grep -E 'ForwardAgent[[:space:]]+yes|StrictHostKeyChecking[[:space:]]+(no|accept-new)' "$repo_root/dot_ssh/.config_windows" >/dev/null; then
  printf '%s\n' 'windows trust: permissive SSH policy detected' >&2
  exit 1
fi

GPG_SCRIPT="$scratch/import-gpg.ps1" FIXTURE_TEMP="$scratch/temp" pwsh -NoProfile -Command - <<'PS'
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$env:TEMP = $env:FIXTURE_TEMP
New-Item -ItemType Directory -Path $env:TEMP -Force | Out-Null
$scriptText = [IO.File]::ReadAllText($env:GPG_SCRIPT)
$expected = [regex]::Match($scriptText, "expectedFingerprint = '([^']+)'").Groups[1].Value
$global:LASTEXITCODE = 0
$global:ImportCount = 0
function global:icacls { $global:LASTEXITCODE = 0 }
function global:op {
    $index = [Array]::IndexOf($args, '--out-file')
    [IO.File]::WriteAllText($args[$index + 1], 'PRIVATE TEST FIXTURE')
    if ($env:OP_FAILURE -eq 'interrupt') { throw [Management.Automation.PipelineStoppedException]::new() }
    if ($env:OP_FAILURE -eq 'cancel') { throw [OperationCanceledException]::new('fixture cancellation') }
    $global:LASTEXITCODE = 0
}
function global:gpg {
    if ($args -contains 'show-only') {
        "fpr:::::::::$($env:FIXTURE_FINGERPRINT):"
        $global:LASTEXITCODE = 0
        return
    }
    if ($args -contains '--import') {
        if ($env:FAIL_IMPORT -eq '1') { $global:LASTEXITCODE = 7; return }
        $global:ImportCount++
    }
    $global:LASTEXITCODE = 0
}
function Assert-Clean {
    if (Get-ChildItem -LiteralPath $env:TEMP -Filter 'chezmoi-gpg-*' -Force) { throw 'transient GPG material was not removed' }
}
$env:FIXTURE_FINGERPRINT = 'BADFINGERPRINT'
try { . $env:GPG_SCRIPT; throw 'fingerprint mismatch was accepted' }
catch { if ($_.Exception.Message -notmatch 'fingerprint mismatch') { throw } }
Assert-Clean
$env:OP_FAILURE = 'interrupt'
try { . $env:GPG_SCRIPT; throw 'interruption was accepted' }
catch { if ($_ -isnot [Management.Automation.PipelineStoppedException]) { throw } }
Assert-Clean
$env:OP_FAILURE = 'cancel'
try { . $env:GPG_SCRIPT; throw 'cancellation was accepted' }
catch { if ($_ -isnot [OperationCanceledException]) { throw } }
Assert-Clean
$env:OP_FAILURE = ''
$env:FIXTURE_FINGERPRINT = $expected
$env:FAIL_IMPORT = '1'
try { . $env:GPG_SCRIPT; throw 'GPG import failure was accepted' }
catch { if ($_.Exception.Message -notmatch 'key import failed') { throw } }
Assert-Clean
$env:FAIL_IMPORT = '0'
. $env:GPG_SCRIPT
. $env:GPG_SCRIPT
Assert-Clean
if ($global:ImportCount -ne 2) { throw 'idempotent import fixture did not complete twice' }
PS

if grep -E 'PRIVATE TEST FIXTURE|op://[^'"'"'[:space:]]+/.+/.+' "$scratch"/*.out 2>/dev/null; then
  printf '%s\n' 'windows trust: secret-shaped output detected' >&2
  exit 1
fi
bash "$repo_root/.ci/test-packages-manifest.sh"
bash "$repo_root/.ci/test-package-ownership.sh"
printf '%s\n' 'windows trust validation passed'
