#!/usr/bin/env pwsh
# install.ps1 - Bootstrap dotfiles on Windows.
#
# Ensures `uv` is on PATH (installing it from astral.sh if missing), then runs
# dotbot ephemerally via `uvx`. dotbot itself is NEVER installed — see AGENTS.md.
#
# Idempotent: re-run after every `git pull`.
#
# Symlinks on Windows require Developer Mode enabled OR running this script
# as Administrator. dotbot will surface the OS error if neither is present.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$RepoRoot = $PSScriptRoot

function Test-CommandExists {
    param([Parameter(Mandatory)][string]$Name)
    $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

# 1. Ensure uv on PATH. The astral PowerShell installer drops uv.exe and
#    uvx.exe into $HOME\.local\bin and updates the user PATH for future
#    sessions. We also prepend it to the current session's $env:Path.
if (-not (Test-CommandExists 'uv')) {
    Write-Host 'install.ps1: uv not found, installing from astral.sh...'
    Invoke-RestMethod 'https://astral.sh/uv/install.ps1' | Invoke-Expression
    $env:Path = "$HOME\.local\bin;$env:Path"
}

if (-not (Test-CommandExists 'uv')) {
    Write-Error "install.ps1: uv still not on PATH after install attempt. Add '$HOME\.local\bin' to PATH and re-run, or restart PowerShell."
    exit 1
}

# 2. Run dotbot ephemerally via uvx. Pass through extra args (e.g. --only).
#    NOTE: dotbot's `-c` uses argparse `nargs='+'` (NOT `append`), so multiple
#    config files MUST be passed under a SINGLE `-c` flag. `-c f1 -c f2` would
#    only use f2 (the last one wins). Don't change this back.
& uvx dotbot `
    -d $RepoRoot `
    -c (Join-Path $RepoRoot 'install.conf.yaml') (Join-Path $RepoRoot 'install.windows.yaml') `
    @args

exit $LASTEXITCODE
