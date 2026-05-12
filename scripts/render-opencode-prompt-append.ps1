#!/usr/bin/env pwsh
# scripts/render-opencode-prompt-append.ps1
#
# PowerShell wrapper for render-opencode-prompt-append.mjs. Keeps script parity
# with render-opencode-prompt-append.sh while the rendering logic runs through
# mise-managed Node.js.

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
    Write-Error "render-opencode-prompt-append.ps1: mise not found. Install mise yourself and re-run. Expected mise on PATH or at '$MiseBin'."
    exit 1
}

& $MiseBin exec node@latest -- node (Join-Path $ScriptDir 'render-opencode-prompt-append.mjs') @args
exit $LASTEXITCODE
