#!/usr/bin/env pwsh
# install.ps1 - First-boot-safe Windows bootstrap orchestrator.
#
# Requires user-installed `mise`, provisions the tracked toolchain from the repo
# source, then applies the chezmoi-managed home tree through mise-managed
# chezmoi. Neither mise nor chezmoi is installed globally by this script.
#
# Idempotent: re-run after every `git pull`.
#
# Symlinks on Windows require Developer Mode enabled OR a token with
# SeCreateSymbolicLinkPrivilege (for example, elevated Administrator). The
# check below fails before chezmoi applies anything so first boot errors are
# actionable.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ChezmoiVersion = '2.70.5'
$RepoRoot = $PSScriptRoot

function Test-CommandExists {
    param([Parameter(Mandatory)][string]$Name)
    $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

function Test-WindowsHost {
    [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT
}

function Test-DeveloperModeEnabled {
    if (-not (Test-WindowsHost)) { return $false }

    $appModelUnlock = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock'
    try {
        $value = Get-ItemPropertyValue `
            -Path $appModelUnlock `
            -Name AllowDevelopmentWithoutDevLicense `
            -ErrorAction Stop
        return [int]$value -eq 1
    }
    catch {
        return $false
    }
}

function Test-SymbolicLinkPrivilegePresent {
    if (-not (Test-WindowsHost)) { return $false }

    try {
        $privileges = & whoami /priv 2>$null
        if ($LASTEXITCODE -ne 0) { return $false }

        return [bool]($privileges | Where-Object { $_ -match 'SeCreateSymbolicLinkPrivilege' })
    }
    catch {
        return $false
    }
}

function Test-CanCreateWindowsSymlinks {
    (Test-DeveloperModeEnabled) -or (Test-SymbolicLinkPrivilegePresent)
}

function Write-Step {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "install.ps1: $Message"
}

function Invoke-RequiredStep {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock
    )

    Write-Step "start: $Name"
    & $ScriptBlock
    Write-Step "done: $Name"
}

function Invoke-OptionalStep {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock
    )

    try {
        Write-Step "start: $Name"
        & $ScriptBlock
        Write-Step "done: $Name"
    }
    catch {
        Write-Warning "install.ps1: skipping $Name ($($_.Exception.Message))"
    }
}

function Confirm-LastExitCode {
    param([Parameter(Mandatory)][string]$Name)

    if ($LASTEXITCODE -ne 0) {
        throw "$Name exited with code $LASTEXITCODE."
    }
}

function Invoke-PowerShellScript {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$RelativePath
    )

    $scriptPath = Join-Path $RepoRoot $RelativePath
    if (-not (Test-Path -LiteralPath $scriptPath)) {
        throw "$RelativePath not found."
    }

    & $PowerShellBin -NoProfile -ExecutionPolicy Bypass -File $scriptPath
    Confirm-LastExitCode -Name $Name
}

function Confirm-WindowsSymlinkSupport {
    if (-not (Test-WindowsHost)) {
        throw 'install.ps1 is Windows-only. Use install.sh on macOS/Linux.'
    }

    if (Test-CanCreateWindowsSymlinks) { return }

    throw @'
install.ps1: Windows symlink creation is unavailable.

Enable Developer Mode (Settings > System > For developers > Developer Mode) or
run PowerShell as Administrator, then re-run install.ps1. chezmoi and the live
repo-tree link step require this before they can safely create symlinks.
'@
}

function Invoke-ToolchainProvision {
    $env:MISE_GLOBAL_CONFIG_FILE = "$RepoRoot\home\dot_config\mise\config.toml"

    & $MiseBin install
    Confirm-LastExitCode -Name 'mise install'

    & $MiseBin up
    Confirm-LastExitCode -Name 'mise up'
}

function Invoke-GlabSkillsInstall {
    & $MiseBin exec glab -- glab skills install -f --path ./agents/skills
    Confirm-LastExitCode -Name 'glab skills install'
}

function Invoke-RenderOpenCodePromptAppend {
    & $MiseBin exec node -- node scripts/bootstrap/render-opencode-prompt-append.mjs
    Confirm-LastExitCode -Name 'render-opencode-prompt-append.mjs'
}

function Invoke-ChezmoiApply {
    & $MiseBin exec "chezmoi@$ChezmoiVersion" -- chezmoi init --apply --source $RepoRoot --no-tty
    Confirm-LastExitCode -Name 'chezmoi init --apply'
}

function Invoke-PackagesBuild {
    & $MiseBin -C packages exec -- yarn install --immutable
    Confirm-LastExitCode -Name 'yarn install --immutable'

    & $MiseBin -C packages exec -- yarn build
    Confirm-LastExitCode -Name 'yarn build'
}

function Invoke-ConfigureCodexConfig {
    & $MiseBin exec node -- node scripts/bootstrap/configure-codex-config.mjs
    Confirm-LastExitCode -Name 'configure-codex-config.mjs'
}

function Remove-StaleDockerConfig {
    $dockerConfig = Join-Path $HOME '.docker\config.json'
    Remove-Item -LiteralPath $dockerConfig -Force -ErrorAction SilentlyContinue
    Write-Step 'docker: removed ~/.docker/config.json if present'
}

$MiseBin = if ($env:MISE_INSTALL_PATH) { $env:MISE_INSTALL_PATH } else { Join-Path $HOME '.local\bin\mise.exe' }

if (Test-CommandExists 'mise') {
    $MiseBin = 'mise'
}
elseif (-not (Test-Path -LiteralPath $MiseBin)) {
    Write-Error "install.ps1: mise not found. Install mise yourself and re-run. Expected mise on PATH or at '$MiseBin'."
    exit 1
}

$PowerShellBin = (Get-Process -Id $PID).Path
if (-not $PowerShellBin) { $PowerShellBin = 'pwsh' }

Push-Location -LiteralPath $RepoRoot
try {
    Invoke-RequiredStep -Name 'verify mise' -ScriptBlock {
        & $MiseBin --version
        Confirm-LastExitCode -Name 'mise --version'
    }

    Invoke-RequiredStep -Name 'toolchain provision' -ScriptBlock { Invoke-ToolchainProvision }

    Invoke-OptionalStep -Name 'remove-dotbot-symlinks.ps1' -ScriptBlock {
        Invoke-PowerShellScript `
            -Name 'remove-dotbot-symlinks.ps1' `
            -RelativePath 'scripts/bootstrap/remove-dotbot-symlinks.ps1'
    }

    Invoke-OptionalStep -Name 'glab skills install' -ScriptBlock { Invoke-GlabSkillsInstall }

    Invoke-RequiredStep -Name 'render OpenCode prompt_append' -ScriptBlock {
        Invoke-RenderOpenCodePromptAppend
    }

    Invoke-RequiredStep -Name 'check Windows symlink support' -ScriptBlock {
        Confirm-WindowsSymlinkSupport
    }

    Invoke-RequiredStep -Name 'chezmoi init --apply' -ScriptBlock { Invoke-ChezmoiApply }

    Invoke-OptionalStep -Name 'setup-glab.ps1' -ScriptBlock {
        Invoke-PowerShellScript -Name 'setup-glab.ps1' -RelativePath 'scripts/auth/setup-glab.ps1'
    }

    Invoke-OptionalStep -Name 'packages yarn build' -ScriptBlock { Invoke-PackagesBuild }

    Invoke-OptionalStep -Name 'link-repo-trees.ps1' -ScriptBlock {
        Invoke-PowerShellScript `
            -Name 'link-repo-trees.ps1' `
            -RelativePath 'scripts/bootstrap/link-repo-trees.ps1'
    }

    Invoke-OptionalStep -Name 'configure-codex-config.mjs' -ScriptBlock {
        Invoke-ConfigureCodexConfig
    }

    Invoke-OptionalStep -Name 'inject-1password-secrets.ps1' -ScriptBlock {
        Invoke-PowerShellScript `
            -Name 'inject-1password-secrets.ps1' `
            -RelativePath 'scripts/bootstrap/inject-1password-secrets.ps1'
    }

    Invoke-OptionalStep -Name 'install-fonts.ps1' -ScriptBlock {
        Invoke-PowerShellScript `
            -Name 'install-fonts.ps1' `
            -RelativePath 'scripts/bootstrap/install-fonts.ps1'
    }

    Invoke-OptionalStep -Name 'docker credential cleanup' -ScriptBlock { Remove-StaleDockerConfig }

    Write-Step 'complete'
}
finally {
    Pop-Location
}
