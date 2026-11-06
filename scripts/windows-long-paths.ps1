#requires -Version 5.1
# Enables Win32 long path support so long-path-aware tools can exceed MAX_PATH.
param(
    [string] $RegistryPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem',
    [switch] $NoElevation
)
$ErrorActionPreference = 'Stop'
$name = 'LongPathsEnabled'

function Test-LongPathsEnabled {
    $item = Get-ItemProperty -LiteralPath $RegistryPath -Name $name -ErrorAction SilentlyContinue
    return [bool]($item -and $item.$name -eq 1)
}

if (Test-LongPathsEnabled) { return }

try {
    New-ItemProperty -LiteralPath $RegistryPath -Name $name -Value 1 -PropertyType DWord -Force | Out-Null
} catch [UnauthorizedAccessException], [Security.SecurityException] {
    if ($NoElevation) { throw }
    Write-Host 'Enabling Windows long path support requires administrator approval.'
    $shell = Join-Path $PSHOME 'powershell.exe'
    if (-not (Test-Path -LiteralPath $shell)) { $shell = (Get-Process -Id $PID).Path }
    $arguments = @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', ('"{0}"' -f $PSCommandPath), '-RegistryPath', ('"{0}"' -f $RegistryPath), '-NoElevation')
    try {
        $process = Start-Process -FilePath $shell -ArgumentList ($arguments -join ' ') -Verb RunAs -Wait -PassThru
    } catch {
        throw "Windows long path support is disabled and elevation was not granted. Approve the administrator prompt or set $RegistryPath\$name to 1, then apply again. Details: $($_.Exception.Message)"
    }
    if ($process.ExitCode -ne 0) { throw "Enabling Windows long path support failed with exit code $($process.ExitCode)." }
}

if (-not (Test-LongPathsEnabled)) { throw "Windows long path support is still disabled at $RegistryPath\$name." }
Write-Host 'Enabled Windows long path support; processes started from now on can use paths beyond MAX_PATH.'
