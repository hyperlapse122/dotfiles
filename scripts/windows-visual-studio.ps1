[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ConfigurationPath,
    [Parameter(Mandatory = $true)][string]$BootstrapperUri,
    [Parameter(Mandatory = $true)][string]$ChannelId,
    [string]$InstallPath = (Join-Path $env:ProgramFiles 'Microsoft Visual Studio\18\BuildTools')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-VisualStudioInstances {
    param([string[]]$RequiredComponents = @(), [switch]$IncludeIncomplete)

    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path -LiteralPath $vswhere -PathType Leaf)) {
        return
    }
    $arguments = @('-products', 'Microsoft.VisualStudio.Product.BuildTools', '-version', '[18.0,19.0)', '-format', 'json', '-utf8')
    if ($IncludeIncomplete) { $arguments += '-all' }
    if ($RequiredComponents.Count -gt 0) { $arguments += @('-requires') + $RequiredComponents }
    # vswhere explicitly emits UTF-8, including paths outside the current ANSI code page.
    $previousEncoding = [Console]::OutputEncoding
    try {
        [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding
        $json = & $vswhere @arguments
        $discoveryExitCode = $LASTEXITCODE
    }
    finally {
        [Console]::OutputEncoding = $previousEncoding
    }
    if ($discoveryExitCode -ne 0) {
        throw "Visual Studio discovery failed with exit code $discoveryExitCode ($vswhere)."
    }
    if ($json) {
        $instances = $json -join "`n" | ConvertFrom-Json
        foreach ($instance in $instances) {
            $instance
        }
    }
}

function Select-VisualStudioInstance {
    param([object[]]$Instances, [string]$StableChannel)

    $eligible = @($Instances | Where-Object {
        $_.productId -eq 'Microsoft.VisualStudio.Product.BuildTools' -and
        $_.channelId -eq $StableChannel -and -not $_.isPrerelease -and
        [version]$_.installationVersion -ge [version]'18.0' -and
        [version]$_.installationVersion -lt [version]'19.0'
    })
    if ($eligible.Count -gt 1) {
        throw 'Multiple stable Visual Studio 2026 Build Tools instances were found; resolve the ambiguity before applying.'
    }
    if ($eligible.Count -eq 1) { $eligible[0] }
}

function ConvertTo-WindowsCommandLineArgument {
    param([AllowEmptyString()][string]$Value)

    # CommandLineToArgvW escaping: backslashes only double before quotes or the closing quote.
    '"' + [regex]::Replace([regex]::Replace($Value, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1') + '"'
}

function Invoke-VisualStudioInstaller {
    param([string]$Executable, [string]$Operation, [string[]]$Arguments)

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        $isAdministrator = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    finally { $identity.Dispose() }
    $parameters = @{
        FilePath = $Executable
        ArgumentList = (($Arguments | ForEach-Object { ConvertTo-WindowsCommandLineArgument $_ }) -join ' ')
        Wait = $true
        PassThru = $true
    }
    if (-not $isAdministrator) { $parameters.Verb = 'RunAs' }
    try { $process = Start-Process @parameters }
    catch { throw "Visual Studio $Operation could not start: $($_.Exception.Message)" }
    if ($process.ExitCode -eq 3010) {
        throw "Visual Studio $Operation returned exit code 3010: reboot required. Restart Windows and apply again; the build environment is not ready."
    }
    if ($process.ExitCode -ne 0) {
        throw "Visual Studio $Operation failed with exit code $($process.ExitCode). Close any active Visual Studio installer/build processes and inspect the installer logs before applying again."
    }
}

function Invoke-VisualStudioProvisioning {
    param([string]$ConfigPath, [string]$DownloadUri, [string]$StableChannel, [string]$NewInstallPath)

    if ($DownloadUri -cne 'https://aka.ms/vs/stable/vs_buildtools.exe' -or $StableChannel -cne 'VisualStudio.18.Stable') {
        throw 'Visual Studio provisioning requires the official stable Build Tools bootstrapper and VisualStudio.18.Stable channel.'
    }
    if (-not [IO.Path]::IsPathRooted($ConfigPath)) { throw 'The Visual Studio configuration path must be absolute.' }
    $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    $components = @($config.components)
    if ($components.Count -eq 0 -or @($components | Where-Object { $_ -isnot [string] -or [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) {
        throw 'The Visual Studio configuration must contain required component IDs.'
    }
    $instance = Select-VisualStudioInstance -Instances @(Get-VisualStudioInstances -IncludeIncomplete) -StableChannel $StableChannel
    if ($null -eq $instance -and (Test-Path -LiteralPath $NewInstallPath)) {
        throw "No eligible stable Build Tools instance is registered, but the proposed install path already exists: $NewInstallPath. Resolve the existing installation before applying."
    }
    $temporaryDirectory = Join-Path ([IO.Path]::GetTempPath()) ('windows-build-tools-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $temporaryDirectory
    $bootstrapper = Join-Path $temporaryDirectory 'vs_buildtools.exe'
    try {
        Invoke-WebRequest -Uri $DownloadUri -OutFile $bootstrapper -UseBasicParsing
        $signature = Get-AuthenticodeSignature -LiteralPath $bootstrapper
        if ($signature.Status -ne 'Valid' -or $null -eq $signature.SignerCertificate -or
            $signature.SignerCertificate.Subject -notmatch '(?:^|,\s*)CN=Microsoft Corporation(?:,|$)') {
            throw 'The Visual Studio bootstrapper must have a valid Microsoft Corporation Authenticode signature; it was not executed.'
        }
        if ($null -eq $instance) {
            Invoke-VisualStudioInstaller -Executable $bootstrapper -Operation 'installation' -Arguments @(
                '--installPath', $NewInstallPath, '--channelId', $StableChannel, '--config', $ConfigPath,
                '--quiet', '--norestart', '--wait'
            )
            $instance = Select-VisualStudioInstance -Instances @(Get-VisualStudioInstances -IncludeIncomplete) -StableChannel $StableChannel
            if ($null -eq $instance) { throw 'Visual Studio installation returned success but no stable Build Tools 2026 instance was registered.' }
        }
        else {
            Invoke-VisualStudioInstaller -Executable $bootstrapper -Operation 'update' -Arguments @(
                'update', '--installPath', $instance.installationPath, '--channelId', $StableChannel,
                '--quiet', '--norestart', '--wait'
            )
            $complete = @(Get-VisualStudioInstances -RequiredComponents $components | Where-Object { $_.instanceId -eq $instance.instanceId })
            if ($complete.Count -eq 0) {
                Invoke-VisualStudioInstaller -Executable $bootstrapper -Operation 'component reconciliation' -Arguments @(
                    'modify', '--installPath', $instance.installationPath, '--channelId', $StableChannel, '--config', $ConfigPath,
                    '--quiet', '--norestart', '--wait'
                )
            }
        }
        $ready = Select-VisualStudioInstance -Instances @(Get-VisualStudioInstances -RequiredComponents $components) -StableChannel $StableChannel
        if ($null -eq $ready -or $ready.instanceId -ne $instance.instanceId) {
            throw 'Visual Studio installation is not ready: the selected stable Build Tools instance is incomplete or missing required components. Inspect installer logs and apply again.'
        }
        Write-Output "Visual Studio 2026 Build Tools is ready: $($ready.installationPath)"
    }
    finally {
        Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-VisualStudioProvisioning -ConfigPath $ConfigurationPath -DownloadUri $BootstrapperUri -StableChannel $ChannelId -NewInstallPath $InstallPath
}
