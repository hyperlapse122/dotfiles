#!/usr/bin/env pwsh
# scripts/inject-1password-secrets.ps1
#
# PowerShell counterpart to inject-1password-secrets.sh. Finds all
# `*.1password` templates in the repository, renders them with `op inject`, and
# writes the resulting secret files under ~/.secrets.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Test-CommandExists {
    param([Parameter(Mandatory)][string]$Name)
    $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

function Set-OwnerOnlyPermissions {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][System.Security.AccessControl.FileSystemRights]$Rights
    )

    $isWindowsHost = [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT

    if (-not $isWindowsHost) {
        if ((Get-Item -LiteralPath $Path -Force).PSIsContainer) {
            chmod 700 $Path
        } else {
            chmod 600 $Path
        }
        if ($LASTEXITCODE -ne 0) {
            exit $LASTEXITCODE
        }
        return
    }

    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $acl = Get-Acl -LiteralPath $Path
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($rule in @($acl.Access)) {
        [void]$acl.RemoveAccessRule($rule)
    }
    $accessRule = [System.Security.AccessControl.FileSystemAccessRule]::new(
        $identity,
        $Rights,
        [System.Security.AccessControl.AccessControlType]::Allow
    )
    $acl.AddAccessRule($accessRule)
    Set-Acl -LiteralPath $Path -AclObject $acl
}

$scriptDir = Split-Path -Parent $PSCommandPath
$repoRoot = Resolve-Path (Join-Path $scriptDir '..')
$secretsDir = if ($env:SECRETS_DIR) { $env:SECRETS_DIR } else { Join-Path $HOME '.secrets' }

$templateFiles = @(Get-ChildItem -LiteralPath $repoRoot -Filter '*.1password' -File -Recurse -Force |
    Where-Object { $_.FullName -notlike (Join-Path $repoRoot '.git*') })

foreach ($templateFile in $templateFiles) {
    if (-not (Test-CommandExists 'op')) {
        Write-Error 'inject-1password-secrets.ps1: op command not found. Install and sign in to 1Password CLI first.'
        exit 1
    }

    $outputName = [System.IO.Path]::GetFileNameWithoutExtension($templateFile.Name)
    $outputPath = Join-Path $secretsDir $outputName
    $outputDir = Split-Path -Parent $outputPath

    New-Item -ItemType Directory -Path $secretsDir -Force | Out-Null
    Set-OwnerOnlyPermissions -Path $secretsDir -Rights ([System.Security.AccessControl.FileSystemRights]::FullControl)
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
    Set-OwnerOnlyPermissions -Path $outputDir -Rights ([System.Security.AccessControl.FileSystemRights]::FullControl)

    op inject --force --in-file $templateFile.FullName --out-file $outputPath
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
    Set-OwnerOnlyPermissions -Path $outputPath -Rights ([System.Security.AccessControl.FileSystemRights]::Read -bor [System.Security.AccessControl.FileSystemRights]::Write)
}

if ($templateFiles.Count -eq 0) {
    Write-Host "inject-1password-secrets.ps1: no *.1password files found under $repoRoot."
}

exit 0
