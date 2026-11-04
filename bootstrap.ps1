#requires -Version 5.1
[CmdletBinding()]
param(
    [string] $Destination = (Join-Path $env:USERPROFILE 'src\dotfiles')
)

$ErrorActionPreference = 'Stop'
$RepositoryUrl = 'https://github.com/hyperlapse122/dotfiles.git'

function Find-Application {
    param([string] $Name)
    $commands = @(Get-Command $Name -All -CommandType Application -ErrorAction SilentlyContinue)
    foreach ($command in $commands) {
        if ($Name -eq 'chezmoi') {
            $miseRoots = @(
                (Join-Path $env:LOCALAPPDATA 'mise')
                if ($env:XDG_DATA_HOME) { Join-Path $env:XDG_DATA_HOME 'mise' }
                $env:MISE_DATA_DIR
                $env:MISE_SHIMS_DIR
                $env:MISE_INSTALLS_DIR
                $env:MISE_INSTALL_STORE_DIR
            )
            $isMise = $false
            foreach ($root in $miseRoots) {
                if ($root -and [IO.Path]::GetFullPath($command.Source).StartsWith(([IO.Path]::GetFullPath($root).TrimEnd('\', '/') + '\'), [StringComparison]::OrdinalIgnoreCase)) {
                    $isMise = $true
                    break
                }
            }
            if ($isMise) { continue }
        }
        return $command.Source
    }
}

function Update-ProcessPath {
    # Installers update the registry, not the PATH inherited by this process.
    $paths = @(
        $env:PATH
        [Environment]::GetEnvironmentVariable('Path', 'Machine')
        [Environment]::GetEnvironmentVariable('Path', 'User')
    )
    $env:PATH = [Environment]::ExpandEnvironmentVariables(($paths -join ';'))
}

function Invoke-Checked {
    param([string] $Command, [string[]] $Arguments, [string] $Step)
    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Step failed (exit code $LASTEXITCODE)."
    }
}

function Install-Prerequisite {
    param([string] $Name, [string] $Package)
    $application = Find-Application $Name
    if ($application) { return $application }

    $winget = Find-Application 'winget'
    if (-not $winget) {
        Write-Host 'Registering the Windows App Installer command...'
        try {
            Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe
        }
        catch {
            throw "WinGet registration failed: $($_.Exception.Message) Install or update App Installer from https://apps.microsoft.com/detail/9nblggh4nns1 and rerun bootstrap."
        }
        Update-ProcessPath
        $winget = Find-Application 'winget'
    }
    if (-not $winget) {
        throw 'WinGet is unavailable. Install or update App Installer from https://apps.microsoft.com/detail/9nblggh4nns1 and rerun bootstrap.'
    }

    Write-Host "Installing $Package with WinGet; approve installation prompts when requested."
    # Send installer output to the host so this function returns only the executable path.
    Invoke-Checked $winget @('install', '--id', $Package, '--exact', '--source', 'winget') "Install $Package" | Out-Host
    Update-ProcessPath
    $application = Find-Application $Name
    if (-not $application) {
        throw "$Package installation finished, but $Name is not discoverable. Open a new PowerShell window and rerun bootstrap."
    }
    return $application
}

try {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        throw 'This entry point requires Windows. Prepare other worktrees with mise install.'
    }

    $Destination = [IO.Path]::GetFullPath($Destination)
    Write-Host 'Checking Git, mise, and native chezmoi prerequisites...'
    Update-ProcessPath
    $git = Install-Prerequisite 'git' 'Git.Git'
    $mise = Install-Prerequisite 'mise' 'jdx.mise'
    $chezmoi = Install-Prerequisite 'chezmoi' 'twpayne.chezmoi'
    Invoke-Checked $chezmoi @('--version') 'Check native chezmoi' | Out-Host

    if (Test-Path -LiteralPath $Destination) {
        if (-not (Test-Path -LiteralPath $Destination -PathType Container)) {
            throw "Destination is not a directory: $Destination"
        }
        $entries = Get-ChildItem -LiteralPath $Destination -Force | Select-Object -First 1
        if ($entries) {
            $prefix = Invoke-Checked $git @('-C', $Destination, 'rev-parse', '--show-prefix') 'Check destination repository'
            if ($prefix) {
                throw "Destination must be the repository root, not a nested directory: $Destination"
            }
        }
        else {
            Invoke-Checked $git @('clone', '--', $RepositoryUrl, $Destination) 'Clone repository'
        }
    }
    else {
        Invoke-Checked $git @('clone', '--', $RepositoryUrl, $Destination) 'Clone repository'
    }

    $origin = Invoke-Checked $git @('-C', $Destination, 'config', '--get', 'remote.origin.url') 'Check repository origin'
    if ($origin.Trim().TrimEnd('/') -ne $RepositoryUrl) {
        throw "Destination origin is not $RepositoryUrl; leave it untouched and select another -Destination."
    }
    $config = Join-Path $Destination 'mise.toml'
    if (-not (Test-Path -LiteralPath $config -PathType Leaf)) {
        throw "The selected checkout has no mise.toml: $Destination"
    }

    Push-Location -LiteralPath $Destination
    try {
        Write-Host 'Trusting the selected repository configuration...'
        Invoke-Checked $mise @('trust', $config) 'Trust project configuration'
        Write-Host 'Installing declared tools and preparing the worktree...'
        Invoke-Checked $mise @('install') 'Install declared tools'
        # mise reports failed postinstall hooks as warnings, so check the task's exit status too.
        Invoke-Checked $mise @('run', 'bootstrap') 'Verify worktree preparation'
    }
    finally {
        Pop-Location
    }

    Write-Host "Bootstrap complete: $Destination"
    Write-Host 'Personal settings were not applied and no global source was registered.'
    Write-Host "To register this permanent checkout, open a new PowerShell window and run: powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$Destination\configure-chezmoi.ps1`""
    Write-Host 'Then run chezmoi update from any directory when you intend to pull and apply personal settings.'
}
catch {
    Write-Error "Windows bootstrap failed: $($_.Exception.Message)" -ErrorAction Continue
    exit 1
}
