# Read-only BitLocker status (Windows only — gated per-OS in .chezmoiignore;
# macOS uses encryption-status and Linux keeps its existing LUKS/TPM2 path).
# Disk-encryption enablement is an operator-owned high-impact security action:
# this tool MUST NEVER enable, disable, or modify encryption state — it only
# queries.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
try {
    if (Get-Command Get-BitLockerVolume -ErrorAction SilentlyContinue) {
        Get-BitLockerVolume |
            Select-Object MountPoint, VolumeStatus, EncryptionPercentage, ProtectionStatus |
            Format-Table -AutoSize
    } else {
        # BitLocker cmdlets absent (e.g. Windows Home): read-only WMI query.
        Get-CimInstance -Namespace 'root\CIMv2\Security\MicrosoftVolumeEncryption' -ClassName Win32_EncryptableVolume -ErrorAction Stop |
            Select-Object DriveLetter, ConversionStatus, ProtectionStatus |
            Format-Table -AutoSize
    }
} catch {
    # Status queries can require elevation on some SKUs; report, never mutate.
    Write-Output "encryption-status: BitLocker status query requires elevation on this host ($($_.Exception.Message))"
}
