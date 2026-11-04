#requires -Version 5.1
[CmdletBinding()]
param(
    [string] $Source
)

$ErrorActionPreference = 'Stop'
if (-not $PSBoundParameters.ContainsKey('Source')) {
    # Windows PowerShell 5.1 -File does not set $PSScriptRoot for parameter defaults.
    $Source = $PSScriptRoot
}

# Windows PowerShell 5.1 initializes PSScriptRoot after -File parameter defaults.
if (-not $PSBoundParameters.ContainsKey('Source')) {
    $Source = $PSScriptRoot
}

function Invoke-Checked {
    param([string] $Command, [string[]] $Arguments, [string] $Step)
    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Step failed (exit code $LASTEXITCODE)."
    }
}

function Resolve-HomePath {
    param([string] $Path)
    if ($Path -eq '~') {
        $Path = $env:USERPROFILE
    }
    elseif ($Path.StartsWith('~/') -or $Path.StartsWith('~\')) {
        $Path = Join-Path $env:USERPROFILE $Path.Substring(2)
    }
    return [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
}

try {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        throw 'Global registration with this entry point requires Windows.'
    }
    # WinGet updates the registry PATH, not an already-running parent process.
    $paths = @(
        $env:PATH
        [Environment]::GetEnvironmentVariable('Path', 'Machine')
        [Environment]::GetEnvironmentVariable('Path', 'User')
    )
    $env:PATH = [Environment]::ExpandEnvironmentVariables(($paths -join ';'))
    # Native command output must preserve Unicode paths in Windows PowerShell.
    [Console]::OutputEncoding = New-Object Text.UTF8Encoding
    $Source = Resolve-HomePath $Source
    $OutputEncoding = [Console]::OutputEncoding
    if (-not (Test-Path -LiteralPath (Join-Path $Source '.git') -PathType Container)) {
        throw 'Source must be a permanent standalone checkout, not a linked worktree.'
    }
    $git = (Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $prefix = Invoke-Checked $git @('-C', $Source, 'rev-parse', '--show-prefix') 'Check source root'
    if ($prefix) { throw 'Source must be the repository root.' }
    $origin = Invoke-Checked $git @('-C', $Source, 'config', '--get', 'remote.origin.url') 'Check source origin'
    if ($origin.Trim().TrimEnd('/') -ne 'https://github.com/hyperlapse122/dotfiles.git') {
        throw 'Source origin is not https://github.com/hyperlapse122/dotfiles.git.'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $Source 'home\.chezmoi.toml.tmpl') -PathType Leaf)) {
        throw 'Source has no chezmoi configuration template. Update the permanent checkout first.'
    }

    $miseRoots = @(
        (Join-Path $env:LOCALAPPDATA 'mise')
        if ($env:XDG_DATA_HOME) { Join-Path $env:XDG_DATA_HOME 'mise' }
        $env:MISE_DATA_DIR
        $env:MISE_SHIMS_DIR
        $env:MISE_INSTALLS_DIR
        $env:MISE_INSTALL_STORE_DIR
    )
    $chezmoi = $null
    foreach ($command in @(Get-Command chezmoi -All -CommandType Application -ErrorAction SilentlyContinue)) {
        $isMise = $false
        foreach ($root in $miseRoots) {
            if ($root -and (Resolve-HomePath $command.Source).StartsWith(((Resolve-HomePath $root) + '\'), [StringComparison]::OrdinalIgnoreCase)) {
                $isMise = $true
                break
            }
        }
        if (-not $isMise) { $chezmoi = $command.Source; break }
    }
    if (-not $chezmoi) {
        throw 'Native Windows chezmoi was not found. Run Windows bootstrap, then open a new PowerShell window.'
    }

    $configRoot = if ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { Join-Path $env:USERPROFILE '.config' }
    $extraConfigDirs = if ($env:XDG_CONFIG_DIRS) { $env:XDG_CONFIG_DIRS -split ';' } else { @('\etc\xdg') }
    $config = $null
    foreach ($directory in (@($configRoot) + $extraConfigDirs)) {
        if (-not $directory) { continue }
        $configDir = Join-Path $directory 'chezmoi'
        foreach ($format in @('json', 'jsonc', 'yaml', 'yml')) {
            if (Test-Path -LiteralPath (Join-Path $configDir "chezmoi.$format")) {
                throw "Existing chezmoi.$format configuration requires explicit migration; no configuration was changed."
            }
        }
        $candidate = Join-Path $configDir 'chezmoi.toml'
        if (Test-Path -LiteralPath $candidate) { $config = $candidate; break }
    }
    if ($config) {
        # Parse only the existing values, without executing its configured hooks.
        $quotedConfig = ConvertTo-Json $config.Replace('\', '/') -Compress
        $template = "{{ include $quotedConfig | fromToml | toJson }}"
        $hookFreeConfig = Join-Path $PSScriptRoot '.chezmoi-bootstrap.toml'
        $text = $template | & $chezmoi --config $hookFreeConfig execute-template
        if ($LASTEXITCODE -ne 0) { throw "Read existing configuration failed (exit code $LASTEXITCODE)." }
        $existing = ($text -join "`n") | ConvertFrom-Json
        $existingSource = if ($existing.sourceDir) { $existing.sourceDir } else {
            $dataRoot = if ($env:XDG_DATA_HOME) { $env:XDG_DATA_HOME } else { Join-Path $env:USERPROFILE '.local\share' }
            Join-Path $dataRoot 'chezmoi'
        }
        if ((Resolve-HomePath $existingSource) -ne $Source) {
            throw 'Existing chezmoi configuration points to another source; no configuration was changed.'
        }
        if ($existing.workingTree -and (Resolve-HomePath $existing.workingTree) -ne $Source) {
            throw 'Existing chezmoi configuration uses another working tree; no configuration was changed.'
        }
    }

    Invoke-Checked $chezmoi @('--source', $Source, 'init') 'Register permanent source' | Out-Host
    $effective = (Invoke-Checked $chezmoi @('dump-config', '--format', 'json') 'Verify registered source') -join "`n" | ConvertFrom-Json
    if ((Resolve-HomePath $effective.workingTree) -ne $Source) {
        throw 'Registration did not retain the selected working tree.'
    }
    Write-Host "Registered native chezmoi: $chezmoi"
    Write-Host "Permanent checkout: $Source"
    Write-Host 'No managed home files were applied. Run chezmoi update --apply=false, then chezmoi init and chezmoi apply.'
}
catch {
    Write-Error "Global chezmoi registration failed: $($_.Exception.Message)" -ErrorAction Continue
    exit 1
}
