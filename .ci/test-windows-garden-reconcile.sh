#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
scratch_root="${XDG_RUNTIME_DIR:-$HOME/.cache}/agent-scratch"
mkdir -p "$scratch_root"
scratch=$(mktemp -d "$scratch_root/windows-garden.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
mkdir -p "$scratch/bin" "$scratch/home/.config/garden"
printf '#!/usr/bin/env bash\nprintf dummy-secret\n' >"$scratch/bin/op"
chmod 700 "$scratch/bin/op"
printf 'encryption = "gpg"\n[data]\n' >"$scratch/empty.toml"
PATH="$scratch/bin:$PATH" chezmoi --config "$scratch/empty.toml" --source "$repo_root" --refresh-externals=never \
  --override-data '{"chezmoi":{"os":"windows","arch":"amd64"}}' execute-template \
  <"$repo_root/.chezmoiscripts/90-src/run_onchange_after_reconcile-garden.ps1.tmpl" >"$scratch/reconcile.ps1"

# End-to-end target-state assertion: render .chezmoiignore through chezmoi,
# then ask the same target-state engine which path the encrypted source owns.
# This catches both an accidental Windows ignore and a source name that would
# deploy garden.yaml.asc instead of the registry path the reconciler consumes.
ignored=$(PATH="$scratch/bin:$PATH" chezmoi --config "$scratch/empty.toml" --source "$repo_root" --refresh-externals=never \
  --destination "$scratch/home" --override-data '{"chezmoi":{"os":"windows","arch":"amd64"}}' ignored)
if grep -qxF '.config/garden/garden.yaml' <<<"$ignored"; then
  printf '%s\n' 'windows garden reconciliation: garden registry is ignored on Windows' >&2
  exit 1
fi
managed=$(PATH="$scratch/bin:$PATH" chezmoi --config "$scratch/empty.toml" --source "$repo_root" --refresh-externals=never \
  --destination "$scratch/home" --override-data '{"chezmoi":{"os":"windows","arch":"amd64"}}' managed)
grep -qxF '.config/garden/garden.yaml' <<<"$managed" || {
  printf '%s\n' 'windows garden reconciliation: encrypted source does not render to .config/garden/garden.yaml' >&2
  exit 1
}

RECONCILE_SCRIPT="$scratch/reconcile.ps1" FIXTURE_HOME="$scratch/home" pwsh -NoProfile -Command - <<'PS'
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Set-Variable -Name HOME -Value $env:FIXTURE_HOME -Force
$env:HOME = $env:FIXTURE_HOME
$global:Calls = [Collections.Generic.List[string]]::new()
$global:LASTEXITCODE = 0
function global:garden {
    $global:Calls.Add(($args -join ' '))
    if ($env:GARDEN_FAIL_CMD -eq '1' -and $args -contains 'cmd') { $global:LASTEXITCODE = 9; return }
    $global:LASTEXITCODE = 0
    if ($args -contains 'ls') { '# repo C:\src\repo\.bare' }
}
function global:aoe { $global:LASTEXITCODE = 0 }
function global:git { $global:LASTEXITCODE = 0; 'true' }

# The reconciler must fail closed before invoking garden when target
# application did not materialize the decrypted registry.
$missingRejected = $false
try {
    . $env:RECONCILE_SCRIPT | Out-Null
} catch {
    if ($_.Exception.Message -notmatch 'missing') { throw }
    $missingRejected = $true
}
if (-not $missingRejected) {
    [Console]::Error.WriteLine('missing garden registry was accepted')
    exit 1
}
if ($global:Calls.Count -ne 0) { throw 'garden ran before the registry preflight passed' }
[IO.File]::WriteAllText((Join-Path $env:HOME '.config/garden/garden.yaml'), "trees: {}`n")

. $env:RECONCILE_SCRIPT | Out-Null
$expected = @(
    "--config $($env:HOME)\.config/garden/garden.yaml grow *",
    "--config $($env:HOME)\.config/garden/garden.yaml ls --all --no-commands --no-remotes --no-gardens --no-groups -v",
    "--config $($env:HOME)\.config/garden/garden.yaml cmd * setup-gitdir setup-upstream aoe-session"
)
if (($global:Calls -join "`n") -ne ($expected -join "`n")) { throw "unexpected command order: $($global:Calls -join '; ')" }
$global:Calls.Clear()
. $env:RECONCILE_SCRIPT | Out-Null
if (($global:Calls -join "`n") -ne ($expected -join "`n")) { throw 'second reconcile did not converge through the same idempotent command sequence' }
$env:GARDEN_FAIL_CMD = '1'
try { . $env:RECONCILE_SCRIPT | Out-Null; throw 'garden cmd failure was accepted' }
catch { if ($_.Exception.Message -notmatch 'failed') { throw } }
PS
printf '%s\n' 'windows garden reconciliation passed'
