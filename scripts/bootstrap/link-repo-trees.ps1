#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-HostOsName {
    if ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)) {
        return 'Windows'
    }
    if ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Linux)) {
        return 'Linux'
    }
    if ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::OSX)) {
        return 'Darwin'
    }

    return [System.Runtime.InteropServices.RuntimeInformation]::OSDescription
}

function Join-HomePath {
    param([Parameter(Mandatory)][string]$RelativePath)
    Join-Path $HOME $RelativePath
}

function Write-LinkRepoLog {
    param([Parameter(Mandatory)][string]$Message)
    Write-Output $Message
}

function New-LiveSymlink {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Target
    )

    $parent = Split-Path -Parent $Target
    if ($parent) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }

    $existing = Get-Item -LiteralPath $Target -Force -ErrorAction SilentlyContinue
    if ($null -ne $existing) {
        Remove-Item -LiteralPath $Target -Force
    }

    try {
        New-Item -ItemType SymbolicLink -Force -Path $Target -Target $Source | Out-Null
    } catch {
        throw "link-repo-trees.ps1: failed to create symlink '$Target' -> '$Source'. Enable Windows Developer Mode or run PowerShell as Administrator, then re-run. Original error: $($_.Exception.Message)"
    }

    Write-LinkRepoLog "link: $Target -> $Source"
}

function New-PluginSymlinkPairIfPresent {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$DistDir,
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$TargetMap
    )

    $source = Join-Path $DistDir 'index.mjs'
    $sourceMap = Join-Path $DistDir 'index.mjs.map'

    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        Write-LinkRepoLog "skip: $Name dist absent"
        return
    }

    New-LiveSymlink -Source $source -Target $Target
    New-LiveSymlink -Source $sourceMap -Target $TargetMap
}

$Repo = (& git rev-parse --show-toplevel).Trim()
if ($LASTEXITCODE -ne 0 -or -not $Repo) {
    Write-Error 'link-repo-trees.ps1: failed to resolve repo root with git rev-parse --show-toplevel.'
    exit 1
}

$OsName = Get-HostOsName

Write-LinkRepoLog "link-repo-trees: repo=$Repo os=$OsName home=$HOME"

New-LiveSymlink (Join-Path $Repo 'agents/skills') (Join-HomePath '.agents/skills')
New-LiveSymlink (Join-Path $Repo 'agents/skills') (Join-HomePath '.claude/skills')
New-LiveSymlink (Join-Path $Repo 'agents/commands') (Join-HomePath '.config/opencode/commands')
New-LiveSymlink (Join-Path $Repo 'agents/commands') (Join-HomePath '.codex/prompts')
New-LiveSymlink (Join-Path $Repo 'agents/SHARED_AGENTS.md') (Join-HomePath '.config/opencode/AGENTS.md')
New-LiveSymlink (Join-Path $Repo 'agents/SHARED_AGENTS.md') (Join-HomePath '.codex/AGENTS.md')
New-LiveSymlink (Join-Path $Repo 'agents/SHARED_AGENTS.md') (Join-HomePath '.claude/CLAUDE.md')
New-LiveSymlink (Join-Path $Repo 'agents/.skill-lock.json') (Join-HomePath '.agents/.skill-lock.json')

if ($OsName -eq 'Linux' -or $OsName -eq 'Darwin') {
    New-LiveSymlink (Join-Path $Repo 'codex/hooks.json') (Join-HomePath '.codex/hooks.json')
} else {
    Write-LinkRepoLog "skip: codex hooks unsupported on $OsName"
}

if ($OsName -eq 'Linux') {
    New-PluginSymlinkPairIfPresent 'mxm4-haptic' (Join-Path $Repo 'packages/opencode-mxm4-haptic/dist') (Join-HomePath '.config/opencode/plugins/mxm4-haptic.js') (Join-HomePath '.config/opencode/plugins/mxm4-haptic.js.map')
} else {
    Write-LinkRepoLog "skip: mxm4-haptic plugin unsupported on $OsName"
}

New-PluginSymlinkPairIfPresent 'playwright-cli-session-injection' (Join-Path $Repo 'packages/opencode-playwright-cli-session-injection/dist') (Join-HomePath '.config/opencode/plugins/playwright-cli-session-injection.js') (Join-HomePath '.config/opencode/plugins/playwright-cli-session-injection.js.map')

Write-LinkRepoLog 'link-repo-trees: complete'
