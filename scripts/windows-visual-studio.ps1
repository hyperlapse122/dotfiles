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

function Test-VisualStudioAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        $isAdministrator = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    finally { $identity.Dispose() }
    $isAdministrator
}

function Invoke-VisualStudioInstaller {
    param([string]$Executable, [string]$Operation, [string[]]$Arguments)

    $parameters = @{
        FilePath = $Executable
        ArgumentList = (($Arguments | ForEach-Object { ConvertTo-WindowsCommandLineArgument $_ }) -join ' ')
        Wait = $true
        PassThru = $true
    }
    if (-not (Test-VisualStudioAdministrator)) { $parameters.Verb = 'RunAs' }
    try { $process = Start-Process @parameters }
    catch { throw "Visual Studio $Operation could not start: $($_.Exception.Message)" }
    if ($process.ExitCode -in @(1641, 3010)) {
        throw "Visual Studio $Operation returned exit code $($process.ExitCode): reboot required. Restart Windows and apply again; the build environment is not ready."
    }
    if ($process.ExitCode -ne 0) {
        throw "Visual Studio $Operation failed with exit code $($process.ExitCode). Close any active Visual Studio installer/build processes and inspect the installer logs before applying again."
    }
}

function Assert-VisualStudioReady {
    param($Instance, [string[]]$Components, [string]$ConfigPath)

    $problems = @()
    foreach ($name in @('isComplete', 'isLaunchable')) {
        if (-not $Instance.PSObject.Properties[$name] -or $Instance.$name -ne $true) {
            $problems += "$name is false or unknown"
        }
    }
    if ($Instance.PSObject.Properties['isRebootRequired'] -and $Instance.isRebootRequired) {
        $problems += 'isRebootRequired is true; restart Windows'
    }
    $ready = @(Get-VisualStudioInstances -RequiredComponents $Components | Where-Object { $_.instanceId -eq $Instance.instanceId })
    if ($problems.Count -eq 0 -and $ready.Count -eq 1) { return }

    $missing = @()
    foreach ($component in $Components) {
        $present = @(Get-VisualStudioInstances -IncludeIncomplete -RequiredComponents @($component) |
            Where-Object { $_.instanceId -eq $Instance.instanceId })
        if ($present.Count -eq 0) { $missing += $component }
    }
    if ($missing.Count -gt 0) { $problems += "missing required components: $($missing -join ', ')" }
    if ($problems.Count -eq 0) { $problems += 'selected instance is not returned by the ready inventory query' }
    throw "Visual Studio 2026 Build Tools '$($Instance.instanceId)' at '$($Instance.installationPath)' is not ready: $($problems -join '; '). Open Visual Studio Installer and manually Update, Modify (import '$ConfigPath'), or Repair this Build Tools instance as appropriate. Complete any required restart, then apply again. Existing installations are never automatically serviced."
}

function Invoke-VisualStudioProvisioning {
    param([string]$ConfigPath, [string]$DownloadUri, [string]$StableChannel, [string]$NewInstallPath)

    if ($DownloadUri -cne 'https://aka.ms/vs/18/stable/vs_buildtools.exe' -or $StableChannel -cne 'VisualStudio.18.Release') {
        throw 'Visual Studio provisioning requires the official stable Build Tools 18 bootstrapper and VisualStudio.18.Release channel.'
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
    if ($null -ne $instance) {
        Assert-VisualStudioReady -Instance $instance -Components $components -ConfigPath $ConfigPath
        Write-Output "Visual Studio 2026 Build Tools is ready: $($instance.installationPath)"
        return
    }
    $temporaryDirectory = Join-Path ([IO.Path]::GetTempPath()) ('windows-build-tools-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $temporaryDirectory
    $bootstrapper = Join-Path $temporaryDirectory 'vs_buildtools.exe'
    try {
        Invoke-WebRequest -Uri $DownloadUri -OutFile $bootstrapper -UseBasicParsing
        # A mise PowerShell environment can include another edition's module path.
        Import-Module (Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Security\Microsoft.PowerShell.Security.psd1') -ErrorAction Stop
        $signature = Get-AuthenticodeSignature -LiteralPath $bootstrapper
        if ($signature.Status -ne 'Valid' -or $null -eq $signature.SignerCertificate -or
            $signature.SignerCertificate.Subject -notmatch '(?:^|,\s*)CN=Microsoft Corporation(?:,|$)') {
            throw 'The Visual Studio bootstrapper must have a valid Microsoft Corporation Authenticode signature; it was not executed.'
        }
        Invoke-VisualStudioInstaller -Executable $bootstrapper -Operation 'installation' -Arguments @(
            '--installPath', $NewInstallPath, '--channelId', $StableChannel, '--config', $ConfigPath,
            '--quiet', '--norestart', '--wait'
        )
        $instance = Select-VisualStudioInstance -Instances @(Get-VisualStudioInstances -IncludeIncomplete) -StableChannel $StableChannel
        if ($null -eq $instance) { throw 'Visual Studio installation returned success but no stable Build Tools 2026 instance was registered.' }
        Assert-VisualStudioReady -Instance $instance -Components $components -ConfigPath $ConfigPath
        Write-Output "Visual Studio 2026 Build Tools is ready: $($instance.installationPath)"
    }
    finally {
        Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-VisualStudioProvisioning -ConfigPath $ConfigurationPath -DownloadUri $BootstrapperUri -StableChannel $ChannelId -NewInstallPath $InstallPath
}
