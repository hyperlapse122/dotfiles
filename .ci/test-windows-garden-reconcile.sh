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
printf '[data]\n' >"$scratch/empty.toml"
printf 'trees: {}\n' >"$scratch/home/.config/garden/garden.yaml"
PATH="$scratch/bin:$PATH" chezmoi --config "$scratch/empty.toml" --source "$repo_root" \
  --override-data '{"chezmoi":{"os":"windows","arch":"amd64"}}' execute-template \
  <"$repo_root/.chezmoiscripts/90-src/run_onchange_after_reconcile-garden.ps1.tmpl" >"$scratch/reconcile.ps1"

RECONCILE_SCRIPT="$scratch/reconcile.ps1" FIXTURE_HOME="$scratch/home" pwsh -NoProfile -Command - <<'PS'
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
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
