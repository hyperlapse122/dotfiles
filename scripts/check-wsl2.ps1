#requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

try {
    $wsl = Get-Command wsl.exe -CommandType Application -ErrorAction Stop |
        Select-Object -First 1
    if (-not $wsl.Source) {
        throw 'The WSL executable could not be resolved.'
    }
}
catch {
    throw "WSL2 prerequisite check failed: WSL is not available. Manually install current WSL using https://learn.microsoft.com/windows/wsl/install, then restart Windows if requested and apply again. Details: $($_.Exception.Message)"
}

# Exit codes are invariant; diagnostic text can be localized. Neither command
# requires a Linux distribution or changes the default WSL version.
foreach ($option in @('--version', '--status')) {
    # Native processes update the global value even when called from a script.
    $global:LASTEXITCODE = $null
    try {
        # Ignore localized native text; legacy WSL can emit UTF-16 through pipes.
        $ErrorActionPreference = 'Continue'
        & $wsl.Source $option *> $null
        $exitCode = $global:LASTEXITCODE
    }
    catch {
        throw "WSL2 prerequisite check failed: could not run wsl.exe $option. Manually check the WSL installation and restart Windows if activation is pending. Details: $($_.Exception.Message)"
    }
    finally {
        $ErrorActionPreference = 'Stop'
    }
    if ($null -eq $exitCode -or $exitCode -ne 0) {
        throw "WSL2 prerequisite check failed: wsl.exe $option failed (exit code $exitCode). Manually install or update WSL using https://learn.microsoft.com/windows/wsl/install, complete any required feature activation, and restart Windows if requested before applying again. Run wsl.exe $option directly for native diagnostics."
    }
}

try {
    $features = @(Get-CimInstance -ClassName Win32_OptionalFeature -Filter "Name = 'VirtualMachinePlatform'" -ErrorAction Stop)
}
catch {
    throw "WSL2 prerequisite check failed: could not read Virtual Machine Platform state. Check access to Windows CIM and inspect the Virtual Machine Platform Windows feature before applying again. Details: $($_.Exception.Message)"
}
if ($features.Count -ne 1 -or $features[0].InstallState -ne 1) {
    throw 'WSL2 prerequisite check failed: Virtual Machine Platform is not confirmed enabled. Manually enable the Virtual Machine Platform Windows feature, complete any requested restart, and apply again. Its invariant CIM InstallState must be 1 (enabled).'
}

try {
    $computers = @(Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop)
}
catch {
    throw "WSL2 prerequisite check failed: could not confirm a running hypervisor. Check access to Windows CIM, firmware virtualization, and Windows hypervisor startup settings; complete any required restart before applying again. Details: $($_.Exception.Message)"
}
if ($computers.Count -ne 1 -or $computers[0].HypervisorPresent -isnot [bool] -or -not $computers[0].HypervisorPresent) {
    throw 'WSL2 prerequisite check failed: a running hypervisor is not confirmed. Check that virtualization is enabled in firmware and Windows hypervisor startup is enabled, then restart Windows if required before applying again.'
}

Write-Host 'WSL2 prerequisites are present. This read-only check does not guarantee VM startup; Rancher Desktop startup and Kubernetes readiness are checked separately.'
