#!/usr/bin/env pwsh
# scripts/auth/auth-glab.ps1
#
# PowerShell counterpart to auth-glab.sh. Prefer system `glab`; fall back to
# ephemeral `mise exec glab@latest`. Error if neither is available.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Test-CommandExists {
    param([Parameter(Mandatory)][string]$Name)
    $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

if (Test-CommandExists 'glab') {
    function Invoke-Glab { & glab @args }
} elseif (Test-CommandExists 'mise') {
    function Invoke-Glab { & mise exec glab@latest -- glab @args }
} else {
    Write-Error "auth-glab.ps1: glab not found and mise unavailable as fallback."
    exit 1
}

Invoke-Glab auth login --hostname git.jpi.app --web --container-registry-domains registry.jpi.app -a git.jpi.app -g https -p https
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Invoke-Glab auth login --hostname gitlab.com --web --container-registry-domains registry.gitlab.com -a gitlab.com -g https -p https
exit $LASTEXITCODE
