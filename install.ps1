#!/usr/bin/env pwsh
# install.ps1 - Bootstrap dotfiles on Windows.
#
# Requires user-installed `mise`, then runs dotbot ephemerally via mise-managed
# `uvx`. dotbot itself is NEVER installed — see AGENTS.md.
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

# 1. Require mise from the user's own installation.
$MiseBin = if ($env:MISE_INSTALL_PATH) { $env:MISE_INSTALL_PATH } else { Join-Path $HOME '.local\bin\mise.exe' }

if (Test-CommandExists 'mise') {
    $MiseBin = 'mise'
} elseif (-not (Test-Path $MiseBin)) {
    Write-Error "install.ps1: mise not found. Install mise yourself and re-run. Expected mise on PATH or at '$MiseBin'."
    exit 1
}

# 2. Run dotbot ephemerally via mise-managed uvx. Pass through extra args (e.g. --only).
#    NOTE: dotbot's `-c` uses argparse `nargs='+'` (NOT `append`), so multiple
#    config files MUST be passed under a SINGLE `-c` flag. `-c f1 -c f2` would
#    only use f2 (the last one wins). Don't change this back.
$DotbotCmd = "uvx dotbot -d . -c install.conf.yaml install.windows.yaml"
Write-Host "Running dotbot with command: $DotbotCmd"
& $MiseBin exec uv@latest --command $DotbotCmd

exit $LASTEXITCODE
