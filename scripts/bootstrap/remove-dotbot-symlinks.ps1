$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# One-time migration helper for the dotbot -> chezmoi cutover.
# It removes only the known dotbot-created symlinks under $HOME before the first
# `chezmoi apply`, so chezmoi cannot follow a repo symlink or collide with one.
# Regular files and absent paths are left untouched; re-running is safe.

$Repo = (git rev-parse --show-toplevel).Trim()
$HomeDir = $env:HOME
if ([string]::IsNullOrWhiteSpace($HomeDir)) {
    $HomeDir = $env:USERPROFILE
}
if ([string]::IsNullOrWhiteSpace($HomeDir)) {
    throw 'HOME or USERPROFILE must be set'
}

$Targets = [System.Collections.Generic.List[string]]::new()
$Seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

function Add-Target {
    param([Parameter(Mandatory)][string]$RelativePath)

    $Normalized = $RelativePath.TrimStart('/', '\')
    if ($Seen.Add($Normalized)) {
        $Targets.Add((Join-Path -Path $HomeDir -ChildPath $Normalized))
    }
}

function Decode-Component {
    param([Parameter(Mandatory)][string]$Component)

    $Decoded = $Component
    while ($true) {
        if ($Decoded.StartsWith('private_', [System.StringComparison]::Ordinal)) {
            $Decoded = $Decoded.Substring('private_'.Length)
            continue
        }
        if ($Decoded.StartsWith('executable_', [System.StringComparison]::Ordinal)) {
            $Decoded = $Decoded.Substring('executable_'.Length)
            continue
        }
        break
    }

    if ($Decoded.StartsWith('dot_', [System.StringComparison]::Ordinal)) {
        $Decoded = '.' + $Decoded.Substring('dot_'.Length)
    }

    return $Decoded
}

function Decode-RelativePath {
    param([Parameter(Mandatory)][string]$SourceRelativePath)

    $DecodedComponents = foreach ($Component in ($SourceRelativePath -split '/')) {
        Decode-Component -Component $Component
    }
    return ($DecodedComponents -join '/')
}

function Add-TrackedTreeTargets {
    param(
        [Parameter(Mandatory)][string]$SourceDir,
        [Parameter(Mandatory)][string]$TargetDir
    )

    $Prefix = "$SourceDir/"
    foreach ($SourcePath in (git -C $Repo ls-files -- $SourceDir)) {
        $FullSourcePath = Join-Path -Path $Repo -ChildPath $SourcePath
        if (-not (Test-Path -LiteralPath $FullSourcePath -PathType Leaf)) {
            continue
        }

        $RelativePath = $SourcePath.Substring($Prefix.Length)
        $DecodedPath = Decode-RelativePath -SourceRelativePath $RelativePath
        Add-Target -RelativePath "$TargetDir/$DecodedPath"
    }
}

function Add-TrackedFileTargets {
    param(
        [string]$TargetDir,
        [Parameter(ValueFromRemainingArguments)][string[]]$SourcePaths
    )

    foreach ($SourcePath in $SourcePaths) {
        if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) {
            continue
        }

        $DecodedName = Decode-Component -Component (Split-Path -Path $SourcePath -Leaf)
        if ([string]::IsNullOrEmpty($TargetDir)) {
            Add-Target -RelativePath $DecodedName
        } else {
            Add-Target -RelativePath "$TargetDir/$DecodedName"
        }
    }
}

function Get-ChildFileNames {
    param(
        [Parameter(Mandatory)][string]$LiteralPath,
        [Parameter(Mandatory)][string[]]$Filters
    )

    foreach ($Filter in $Filters) {
        if (-not (Test-Path -LiteralPath $LiteralPath -PathType Container)) {
            continue
        }

        (Get-ChildItem -LiteralPath $LiteralPath -File -Filter $Filter).FullName
    }
}

function Add-SharedTargets {
    Add-Target -RelativePath '.agents/skills'
    Add-Target -RelativePath '.agents/.skill-lock.json'
    Add-Target -RelativePath '.claude/skills'
    Add-Target -RelativePath '.config/opencode/commands'
    Add-Target -RelativePath '.codex/prompts'
    Add-Target -RelativePath '.config/opencode/AGENTS.md'
    Add-Target -RelativePath '.codex/AGENTS.md'
    Add-Target -RelativePath '.claude/CLAUDE.md'
    Add-Target -RelativePath '.config/git/config'
    Add-Target -RelativePath '.config/mise/config.toml'
    Add-Target -RelativePath '.ssh/config'
    Add-Target -RelativePath '.config/1Password/ssh/agent.toml'
    Add-Target -RelativePath '.default-gems'
    Add-Target -RelativePath '.yarnrc.yml'
    Add-Target -RelativePath '.npmrc'
    Add-Target -RelativePath '.config/opencode/plugins/playwright-cli-session-injection.js'
    Add-Target -RelativePath '.config/opencode/plugins/playwright-cli-session-injection.js.map'

    Add-TrackedFileTargets -TargetDir '.config/opencode' @(
        Get-ChildFileNames -LiteralPath (Join-Path $Repo 'home/dot_config/opencode') -Filters @('*.json', '*.jsonc')
    )
    Add-TrackedTreeTargets -SourceDir 'home/dot_config/zsh' -TargetDir '.config/zsh'
}

function Add-PosixCommonTargets {
    Add-TrackedFileTargets -TargetDir '' @(
        (Get-ChildItem -LiteralPath (Join-Path $Repo 'home') -File -Filter 'dot_z*').FullName
    )
    Add-TrackedFileTargets -TargetDir '.gnupg' @(
        (Get-ChildItem -LiteralPath (Join-Path $Repo 'home/private_dot_gnupg') -File -Filter '*.conf').FullName
    )
    Add-Target -RelativePath '.local/bin/opencode'
    Add-Target -RelativePath '.local/bin/code'
    Add-Target -RelativePath '.codex/hooks.json'
}

function Add-LinuxTargets {
    Add-PosixCommonTargets
    Add-Target -RelativePath '.gitconfig.d/linux.gitconfig'
    Add-TrackedTreeTargets -SourceDir 'home/dot_config' -TargetDir '.config'
    Add-TrackedTreeTargets -SourceDir 'home/dot_local/share/applications' -TargetDir '.local/share/applications'
    Add-Target -RelativePath '.config/opencode/plugins/mxm4-haptic.js'
    Add-Target -RelativePath '.config/opencode/plugins/mxm4-haptic.js.map'
}

function Add-MacosTargets {
    Add-PosixCommonTargets
    Add-Target -RelativePath '.gitconfig.d/macos.gitconfig'
    Add-TrackedTreeTargets -SourceDir 'home/dot_config/Code/User' -TargetDir 'Library/Application Support/Code/User'
    Add-TrackedTreeTargets -SourceDir 'home/dot_config/VSCodium/User' -TargetDir 'Library/Application Support/VSCodium/User'
    Add-Target -RelativePath 'Library/LaunchAgents/dev.h82.mxm4-hapticd.plist'
}

function Add-WindowsTargets {
    Add-Target -RelativePath '.gitconfig.d/windows.gitconfig'
    Add-TrackedTreeTargets -SourceDir 'home/dot_config/Code/User' -TargetDir 'AppData/Roaming/Code/User'
    Add-TrackedTreeTargets -SourceDir 'home/dot_config/VSCodium/User' -TargetDir 'AppData/Roaming/VSCodium/User'
    Add-Target -RelativePath '.local/bin/opencode.ps1'
    Add-Target -RelativePath '.local/bin/code.ps1'
}

function Test-SymbolicLink {
    param([Parameter(Mandatory)][string]$Path)

    $Item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $Item) {
        return $false
    }

    return $Item.LinkType -eq 'SymbolicLink'
}

function Remove-SymlinkTargets {
    foreach ($Target in $Targets) {
        if (Test-SymbolicLink -Path $Target) {
            Remove-Item -LiteralPath $Target -Force
            Write-Output "removed symlink: $Target"
        }
    }
}

Add-SharedTargets

if ($IsLinux) {
    Add-LinuxTargets
} elseif ($IsMacOS) {
    Add-MacosTargets
} elseif ($IsWindows) {
    Add-WindowsTargets
} else {
    Write-Warning 'remove-dotbot-symlinks: unsupported PowerShell OS; shared targets only'
}

Remove-SymlinkTargets
