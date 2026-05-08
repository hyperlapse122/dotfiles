#!/usr/bin/env pwsh
# scripts/import-gpg-keys.ps1
#
# PowerShell counterpart to import-gpg-keys.sh. Reads GPG private key from
# 1Password via `op read` and pipes it into `gpg --batch --import`.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Test-CommandExists {
    param([Parameter(Mandatory)][string]$Name)
    $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

if (-not (Test-CommandExists 'op') -or -not (Test-CommandExists 'gpg')) {
    Write-Error "import-gpg-keys.ps1: Required commands 'op' and/or 'gpg' are not available."
    exit 1
}

op read "op://tjlmijoc5qxj6vypdnvxf6s2sq/gmwqu34rldszc6qtas2i3ejiaq/gpg_private.asc" | gpg --batch --import
exit $LASTEXITCODE
