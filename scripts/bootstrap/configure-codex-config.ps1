#!/usr/bin/env pwsh
# scripts/bootstrap/configure-codex-config.ps1
#
# PowerShell wrapper for configure-codex-config.mjs. Keeps script parity with
# configure-codex-config.sh while the merge logic runs through mise-managed
# Node.js.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Test-CommandExists {
    param([Parameter(Mandatory)][string]$Name)
    $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

$ScriptDir = Split-Path -Parent $PSCommandPath
$MiseBin = if ($env:MISE_INSTALL_PATH) { $env:MISE_INSTALL_PATH } else { Join-Path $HOME '.local\bin\mise.exe' }

if (Test-CommandExists 'mise') {
    $MiseBin = 'mise'
} elseif (-not (Test-Path $MiseBin)) {
    Write-Error "configure-codex-config.ps1: mise not found. Install mise yourself and re-run. Expected mise on PATH or at '$MiseBin'."
    exit 1
}

& $MiseBin exec node@latest -- node (Join-Path $ScriptDir 'configure-codex-config.mjs') @args
exit $LASTEXITCODE
