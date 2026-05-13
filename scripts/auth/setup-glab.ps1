#!/usr/bin/env pwsh
# scripts/auth/setup-glab.ps1
#
# PowerShell counterpart to setup-glab.sh. Prefer system `glab`; fall back to
# ephemeral `mise exec glab@latest`. Error if neither is available.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Test-CommandExists {
    param([Parameter(Mandatory)][string]$Name)
    $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

if (Test-CommandExists 'glab') {
    & glab config set client_id c6c350c323dbd7dbd4091b2f3e56a1d6ef31e7104ae6deddfc5d950c7d11d69f --global --host git.jpi.app
} elseif (Test-CommandExists 'mise') {
    & mise exec glab@latest -- glab config set client_id c6c350c323dbd7dbd4091b2f3e56a1d6ef31e7104ae6deddfc5d950c7d11d69f --global --host git.jpi.app
} else {
    Write-Error "setup-glab.ps1: glab not found and mise unavailable as fallback."
    exit 1
}

exit $LASTEXITCODE
