[CmdletBinding()]
param(
    [ValidateSet('Dotnet', 'Rust', 'Vcpkg')][string] $Phase,
    [ValidateSet(8, 10)][int] $SdkMajor,
    [string] $VcpkgRepository,
    [string] $VcpkgRevision,
    [string] $VcpkgRoot
)

$ErrorActionPreference = 'Stop'

function Invoke-BuildNative {
    param([string] $Command, [string[]] $Arguments = @())
    $application = Get-Command -Name $Command -CommandType Application -ErrorAction Stop
    # Windows PowerShell can surface native stderr as nonterminating errors.
    # Keep diagnostics visible and decide success from the process exit code.
    $ErrorActionPreference = 'Continue'
    $output = @(& $application.Source @Arguments)
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed with exit code ${LASTEXITCODE}: $Command $($Arguments -join ' ')"
    }
    return $output
}

function Test-BuildAbsolutePath([string] $Path) {
    return $Path -match '^(?:[a-zA-Z]:[\\/]|\\\\[^\\/]+[\\/][^\\/]+(?:[\\/]|$))'
}

function ConvertTo-BuildPath([string] $Entry) {
    if ([string]::IsNullOrWhiteSpace($Entry)) { return '' }
    try {
        $expanded = [Environment]::ExpandEnvironmentVariables($Entry.Trim().Trim('"'))
        return [IO.Path]::GetFullPath($expanded.Replace('/', '\')).TrimEnd('\', '/')
    } catch {
        # An unrelated malformed entry must survive reconciliation unchanged.
        return $Entry
    }
}

function Merge-BuildPath {
    param([AllowNull()][string] $RawPath, [string[]] $Directories, [string[]] $ReplacedDirectories = @())
    $managed = @($Directories | Where-Object { $_ } | Select-Object -Unique)
    $remove = @($managed + $ReplacedDirectories | ForEach-Object { ConvertTo-BuildPath $_ })
    $remaining = @()
    if ($null -ne $RawPath) {
        foreach ($entry in $RawPath.Split(';')) {
            if ($remove -notcontains (ConvertTo-BuildPath $entry)) { $remaining += $entry }
        }
    }
    return (@($managed) + $remaining) -join ';'
}

function Set-BuildUserEnvironment {
    param([Microsoft.Win32.RegistryKey] $Key, [hashtable] $Values)
    $rawOption = [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames
    $directories = @()
    $replaced = @()
    $kinds = @{}
    foreach ($name in @('DOTNET_ROOT', 'CARGO_HOME', 'RUSTUP_HOME', 'VCPKG_ROOT')) {
        $old = $Key.GetValue($name, $null, $rawOption)
        if ($Values.ContainsKey($name)) {
            $kind = [Microsoft.Win32.RegistryValueKind]::String
            if ($null -ne $old) { $kind = $Key.GetValueKind($name) }
            if ($kind -notin @([Microsoft.Win32.RegistryValueKind]::String, [Microsoft.Win32.RegistryValueKind]::ExpandString)) {
                throw "Cannot preserve unsupported registry type for $name. Correct that user environment value before applying."
            }
            $kinds[$name] = $kind
            if ($old -and $name -ne 'RUSTUP_HOME') {
                $oldRoot = [Environment]::ExpandEnvironmentVariables([string]$old)
                $replaced += $(if ($name -eq 'CARGO_HOME') { Join-Path $oldRoot 'bin' } else { $oldRoot })
            }
            $value = $Values[$name]
        } else { $value = $old }
        if ($value -and $name -ne 'RUSTUP_HOME') {
            $root = [Environment]::ExpandEnvironmentVariables([string]$value)
            $directories += $(if ($name -eq 'CARGO_HOME') { Join-Path $root 'bin' } else { $root })
        }
    }
    $rawPath = $Key.GetValue('Path', $null, $rawOption)
    $pathKind = [Microsoft.Win32.RegistryValueKind]::String
    if ($null -ne $rawPath) { $pathKind = $Key.GetValueKind('Path') }
    if ($pathKind -notin @([Microsoft.Win32.RegistryValueKind]::String, [Microsoft.Win32.RegistryValueKind]::ExpandString)) {
        throw 'Cannot preserve unsupported user PATH registry type. Correct that value before applying.'
    }
    $newPath = Merge-BuildPath -RawPath $rawPath -Directories $directories -ReplacedDirectories $replaced
    foreach ($name in $Values.Keys) {
        $Key.SetValue($name, [string]$Values[$name], $kinds[$name])
        [Environment]::SetEnvironmentVariable($name, [string]$Values[$name], 'Process')
    }
    $Key.SetValue('Path', $newPath, $pathKind)
    # Preserve machine and task-local entries in this process, never in the registry.
    $env:PATH = Merge-BuildPath -RawPath $env:PATH -Directories $directories -ReplacedDirectories $replaced
}

function Send-BuildEnvironmentChanged {
    if (-not ('WindowsBuildEnvironmentNotification' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class WindowsBuildEnvironmentNotification {
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr SendMessageTimeout(IntPtr window, uint message,
        UIntPtr parameter, string value, uint flags, uint timeout, out UIntPtr result);
}
'@
    }
    $result = [UIntPtr]::Zero
    [WindowsBuildEnvironmentNotification]::SendMessageTimeout(
        [IntPtr]0xffff, 0x1a, [UIntPtr]::Zero, 'Environment', 0x2, 5000, [ref]$result
    ) | Out-Null
}

function Get-BuildDotnetEnvironment([int] $Major) {
    if ($Major -notin @(8, 10)) { throw 'Dotnet requires -SdkMajor 8 or 10.' }
    if (-not (Test-BuildAbsolutePath $env:DOTNET_ROOT)) {
        throw 'The mise SDK task must supply an absolute shared DOTNET_ROOT.'
    }
    $root = [IO.Path]::GetFullPath($env:DOTNET_ROOT)
    $sdks = @(Invoke-BuildNative (Join-Path $root 'dotnet.exe') @('--list-sdks'))
    if (-not ($sdks | Where-Object { $_ -match "^$Major\.\d+\.\d+[^ ]*\s+\[" })) {
        throw ".NET SDK $Major is missing from shared root '$root'. Reapply the corresponding mise SDK task. Found: $($sdks -join '; ')"
    }
    Write-Host ".NET shared root: $root`n$($sdks -join [Environment]::NewLine)"
    return @{ DOTNET_ROOT = $root }
}

function Get-BuildRustEnvironment {
    if (-not $env:CARGO_HOME -or -not $env:RUSTUP_HOME -or -not $env:RUSTUP_TOOLCHAIN) {
        throw 'The mise Rust task must supply CARGO_HOME, RUSTUP_HOME, and RUSTUP_TOOLCHAIN.'
    }
    if (-not (Test-BuildAbsolutePath $env:CARGO_HOME) -or -not (Test-BuildAbsolutePath $env:RUSTUP_HOME)) {
        throw 'CARGO_HOME and RUSTUP_HOME must be absolute user paths.'
    }
    $cargoHome = [IO.Path]::GetFullPath($env:CARGO_HOME)
    $rustupHome = [IO.Path]::GetFullPath($env:RUSTUP_HOME)
    $bin = Join-Path $cargoHome 'bin'
    $rustup = Join-Path $bin 'rustup.exe'
    $rustc = @(Invoke-BuildNative (Join-Path $bin 'rustc.exe') @('--version', '--verbose'))
    $cargo = @(Invoke-BuildNative (Join-Path $bin 'cargo.exe') @('--version'))
    if (-not ($rustc -contains 'host: x86_64-pc-windows-msvc')) {
        throw "The managed Rust toolchain must use the x86_64-pc-windows-msvc host. Found: $($rustc -join '; ')"
    }
    $targets = @(Invoke-BuildNative $rustup @('target', 'list', '--installed', '--toolchain', $env:RUSTUP_TOOLCHAIN))
    foreach ($target in @('x86_64-pc-windows-msvc', 'aarch64-pc-windows-msvc')) {
        if ($targets -notcontains $target) {
            throw "Rust target '$target' is missing for '$env:RUSTUP_TOOLCHAIN'. Reapply the mise Rust task with both MSVC targets."
        }
    }
    $toolchains = @(Invoke-BuildNative $rustup @('toolchain', 'list'))
    if (-not ($toolchains | Where-Object { $_ -match '\([^)]*\bdefault\b[^)]*\)' })) {
        Invoke-BuildNative $rustup @('default', $env:RUSTUP_TOOLCHAIN) | Out-Host
    }
    Write-Host "Rust roots: cargo=$cargoHome; rustup=$rustupHome`n$($rustc -join [Environment]::NewLine)`n$($cargo -join [Environment]::NewLine)`nTargets: $($targets -join ', ')"
    return @{ CARGO_HOME = $cargoHome; RUSTUP_HOME = $rustupHome }
}

function Get-BuildVcpkgEnvironment {
    param([string] $Repository, [string] $Revision, [string] $Root)
    if ($Repository -notmatch '^https://github\.com/microsoft/vcpkg(?:\.git)?/?$') {
        throw 'VcpkgRepository must be the official https://github.com/microsoft/vcpkg.git upstream.'
    }
    if (-not $Revision -or $Revision.StartsWith('-') -or $Revision -match '[\s~^:?*\[\\]') {
        throw 'VcpkgRevision must be an exact commit or tag, not a branch or revision expression.'
    }
    if (-not (Test-BuildAbsolutePath $Root)) { throw 'VcpkgRoot must be an absolute writable user path.' }
    $Root = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $git = (Get-Command git -CommandType Application -ErrorAction Stop).Source
    if (-not (Test-Path -LiteralPath (Join-Path $Root '.git'))) {
        if ((Test-Path -LiteralPath $Root) -and @(Get-ChildItem -LiteralPath $Root -Force).Count -ne 0) {
            throw "Refusing unrelated directory '$Root': select an empty root or a clean Microsoft vcpkg checkout."
        }
        Invoke-BuildNative $git @('clone', '--origin', 'origin', $Repository, $Root) | Out-Host
    }
    $top = @(Invoke-BuildNative $git @('-C', $Root, 'rev-parse', '--show-toplevel'))
    if ($top.Count -ne 1 -or (ConvertTo-BuildPath $top[0]) -ne (ConvertTo-BuildPath $Root)) {
        throw "Refusing vcpkg root '$Root': Git reports a different checkout root."
    }
    $origin = @(Invoke-BuildNative $git @('-C', $Root, 'remote', 'get-url', 'origin'))
    if ($origin.Count -ne 1 -or $origin[0] -notmatch '^https://github\.com/microsoft/vcpkg(?:\.git)?/?$') {
        throw "Refusing vcpkg checkout '$Root': origin is not the Microsoft upstream."
    }
    $dirty = @(Invoke-BuildNative $git @('-C', $Root, 'status', '--porcelain', '--untracked-files=normal'))
    if ($dirty.Count -ne 0) {
        throw "Refusing to update dirty vcpkg checkout '$Root'. Preserve or commit local changes before reapplying.`n$($dirty -join [Environment]::NewLine)"
    }
    $probe = Join-Path $Root ([IO.Path]::GetRandomFileName())
    try { [IO.File]::WriteAllText($probe, '') } finally {
        if (Test-Path -LiteralPath $probe) { Remove-Item -LiteralPath $probe -Force }
    }
    if ($Revision -match '^[0-9a-fA-F]{40}$') { $reference = $Revision }
    else { $reference = "refs/tags/$Revision" }
    Invoke-BuildNative $git @('-C', $Root, 'fetch', 'origin', $reference) | Out-Host
    $commit = @(Invoke-BuildNative $git @('-C', $Root, 'rev-parse', '--verify', 'FETCH_HEAD^{commit}'))
    if ($commit.Count -ne 1 -or $commit[0] -notmatch '^[0-9a-fA-F]{40}$') { throw 'Git did not resolve the pinned vcpkg revision to one commit.' }
    if ($Revision -match '^[0-9a-fA-F]{40}$' -and $commit[0] -ne $Revision) { throw 'Fetched vcpkg commit does not match the pinned revision.' }
    Invoke-BuildNative $git @('-C', $Root, 'checkout', '--detach', $commit[0]) | Out-Host
    foreach ($relative in @('bootstrap-vcpkg.bat', 'ports', 'scripts\buildsystems\msbuild\vcpkg.targets')) {
        if (-not (Test-Path -LiteralPath (Join-Path $Root $relative))) { throw "Incomplete vcpkg checkout: missing '$relative' in '$Root'." }
    }
    Push-Location -LiteralPath $Root
    try { Invoke-BuildNative (Join-Path $Root 'bootstrap-vcpkg.bat') @('-disableMetrics') | Out-Host }
    finally { Pop-Location }
    $executable = Join-Path $Root 'vcpkg.exe'
    Invoke-BuildNative $executable @('integrate', 'install') | Out-Host
    $version = @(Invoke-BuildNative $executable @('version'))
    Write-Host "vcpkg root: $Root`nRevision: $($commit[0])`n$($version -join [Environment]::NewLine)"
    return @{ VCPKG_ROOT = $Root }
}

# Dot sourcing exposes ordinary operations without applying to the real user.
if ($MyInvocation.InvocationName -ne '.') {
    if (-not $Phase) { throw 'Specify -Phase Dotnet, Rust, or Vcpkg.' }
    $values = switch ($Phase) {
        'Dotnet' { Get-BuildDotnetEnvironment $SdkMajor }
        'Rust' { Get-BuildRustEnvironment }
        'Vcpkg' { Get-BuildVcpkgEnvironment -Repository $VcpkgRepository -Revision $VcpkgRevision -Root $VcpkgRoot }
    }
    $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Environment')
    try { Set-BuildUserEnvironment -Key $key -Values $values }
    finally { $key.Dispose() }
    Send-BuildEnvironmentChanged
}
