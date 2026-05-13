#!/usr/bin/env pwsh
# scripts/auth/auth-gh.ps1
#
# PowerShell counterpart to auth-gh.sh. Prefer system `gh`; fall back to
# ephemeral `mise exec gh@latest`. Error if neither is available.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Test-CommandExists {
    param([Parameter(Mandatory)][string]$Name)
    $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

if (Test-CommandExists 'gh') {
    & gh auth login -p https -h github.com -w --clipboard
} elseif (Test-CommandExists 'mise') {
    & mise exec gh@latest -- gh auth login -p https -h github.com -w --clipboard
} else {
    Write-Error "auth-gh.ps1: gh not found and mise unavailable as fallback."
    exit 1
}

exit $LASTEXITCODE
