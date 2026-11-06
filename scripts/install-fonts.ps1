param(
    [Parameter(Mandatory = $true)][string] $AssetRoot,
    [Parameter(Mandatory = $true)][string] $IndexPath,
    [Parameter(Mandatory = $true)][string] $FontDirectory,
    [Parameter(Mandatory = $true)][string] $StatePath
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

function Assert-OwnedName([string] $Name) {
    if ($Name -cnotmatch '^dotfiles-[a-z][a-z0-9-]*-[A-Za-z0-9][A-Za-z0-9_.-]*\.ttf$') {
        throw "Invalid owned font name: $Name"
    }
}

function Get-FontLabel([string] $Name) {
    return "Dotfiles $Name (TrueType)"
}

function Get-FontHash([string] $Path) {
    $stream = [IO.File]::OpenRead($Path)
    $hash = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($hash.ComputeHash($stream)).Replace('-', '').ToLowerInvariant() }
    finally { $hash.Dispose(); $stream.Dispose() }
}

$AssetRoot = [IO.Path]::GetFullPath($AssetRoot)
$FontDirectory = [IO.Path]::GetFullPath($FontDirectory)
$StatePath = [IO.Path]::GetFullPath($StatePath)
$previous = @{}
if (Test-Path -LiteralPath $StatePath) {
    $state = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
    if ($state.version -ne 1) { throw 'Unsupported font manifest version.' }
    foreach ($entry in $state.fonts) {
        Assert-OwnedName $entry.name
        if ($entry.sha256 -cnotmatch '^[0-9a-f]{64}$' -or $previous.ContainsKey($entry.name)) {
            throw 'Invalid font manifest entry.'
        }
        $previous[$entry.name] = $entry.sha256
    }
}

$desired = @{}
foreach ($line in [IO.File]::ReadAllLines($IndexPath)) {
    if (-not $line) { continue }
    $fields = $line.Split("`t")
    if ($fields.Count -ne 4) { throw 'Invalid font index row.' }
    $package, $member, $basename, $checksum = $fields
    if ($package -cnotmatch '^[a-z][a-z0-9-]*$' -or
        $basename -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_.-]*\.ttf$' -or
        $member -cnotmatch '^[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*$' -or
        @($member.Split('/') | Where-Object { $_ -eq '.' -or $_ -eq '..' }).Count -or
        $checksum -cnotmatch '^[0-9a-f]{64}$') {
        throw 'Invalid font index path or checksum.'
    }
    $name = "dotfiles-$package-$basename"
    Assert-OwnedName $name
    if ($desired.ContainsKey($name)) { throw "Duplicate font destination: $name" }
    $source = Join-Path (Join-Path $AssetRoot $package) $member
    if (-not (Test-Path -LiteralPath $source -PathType Leaf) -or
        (Get-FontHash $source) -cne $checksum) {
        throw "Staged font checksum mismatch: $source. Refresh externals and reapply."
    }
    $desired[$name] = @{ source = $source; sha256 = $checksum }
}

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class DotfilesFonts {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool MoveFileEx(string existing, string replacement, uint flags);
    [DllImport("gdi32.dll", CharSet = CharSet.Unicode)]
    public static extern int AddFontResourceEx(string name, uint flags, IntPtr reserved);
    [DllImport("gdi32.dll", CharSet = CharSet.Unicode)]
    public static extern bool RemoveFontResourceEx(string name, uint flags, IntPtr reserved);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr SendMessageTimeout(IntPtr window, uint message,
        UIntPtr parameter, IntPtr value, uint flags, uint timeout, out UIntPtr result);
}
'@

function Unregister-Font([string] $Path) {
    while ([DotfilesFonts]::RemoveFontResourceEx($Path, 0, [IntPtr]::Zero)) { }
}

function Send-FontChange {
    $result = [UIntPtr]::Zero
    $notified = [DotfilesFonts]::SendMessageTimeout([IntPtr]0xffff, 0x1d, [UIntPtr]::Zero,
        [IntPtr]::Zero, 0x2, 5000, [ref]$result)
    if ($notified -eq [IntPtr]::Zero) {
        throw 'Font change notification failed. Close unresponsive applications and reapply.'
    }
}

function Move-FontFile([string] $Source, [string] $Destination) {
    if (-not [DotfilesFonts]::MoveFileEx($Source, $Destination, 1)) {
        throw [ComponentModel.Win32Exception]::new([Runtime.InteropServices.Marshal]::GetLastWin32Error())
    }
}

[IO.Directory]::CreateDirectory($FontDirectory) | Out-Null
$key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Software\Microsoft\Windows NT\CurrentVersion\Fonts')
$changed = $false
try {
    foreach ($name in $desired.Keys) {
        $entry = $desired[$name]
        $target = Join-Path $FontDirectory $name
        $label = Get-FontLabel $name
        $same = (Test-Path -LiteralPath $target -PathType Leaf) -and
            (Get-FontHash $target) -ceq $entry.sha256
        if (-not $same) {
            $temporary = Join-Path $FontDirectory ('.dotfiles-font-' + [Guid]::NewGuid().ToString('N') + '.tmp')
            try {
                [IO.File]::Copy($entry.source, $temporary)
                if (Test-Path -LiteralPath $target) {
                    Unregister-Font $target
                    $key.DeleteValue($label, $false)
                    Send-FontChange
                    Move-FontFile $temporary $target
                } else {
                    [IO.File]::Move($temporary, $target)
                }
            } catch {
                throw "Cannot replace font $target. Close applications using it; if needed sign out or restart, then reapply. $($_.Exception.Message)"
            } finally {
                if (Test-Path -LiteralPath $temporary) { [IO.File]::Delete($temporary) }
            }
        }
        $registered = $key.GetValue($label)
        if (-not $same -or $registered -cne $target) {
            # Clear this owned path's prior session reference before adding it once.
            Unregister-Font $target
            if ([DotfilesFonts]::AddFontResourceEx($target, 0, [IntPtr]::Zero) -eq 0) {
                throw "Windows could not load font $target. Close affected applications and reapply."
            }
            $key.SetValue($label, $target, [Microsoft.Win32.RegistryValueKind]::String)
            $changed = $true
        }
    }
    $obsolete = @($previous.Keys | Where-Object { -not $desired.ContainsKey($_) })
    # Remove persistence for the whole obsolete set before a loaded file can
    # block deletion; otherwise it would be loaded again after signing in.
    foreach ($name in $obsolete) {
        $target = Join-Path $FontDirectory $name
        Unregister-Font $target
        $key.DeleteValue((Get-FontLabel $name), $false)
    }
    if ($obsolete.Count) { Send-FontChange }
    foreach ($name in $obsolete) {
        $target = Join-Path $FontDirectory $name
        try {
            if (Test-Path -LiteralPath $target) { [IO.File]::Delete($target) }
        } catch {
            throw "Cannot remove font $target. Close applications using it; if needed sign out or restart, then reapply. $($_.Exception.Message)"
        }
        $changed = $true
    }
} finally {
    $key.Dispose()
}

if ($changed) {
    Send-FontChange
}
$entries = @($desired.Keys | Sort-Object | ForEach-Object {
    @{ name = $_; sha256 = $desired[$_].sha256 }
})
$manifest = @{ version = 1; fonts = $entries } | ConvertTo-Json -Depth 4
if (-not (Test-Path -LiteralPath $StatePath) -or
    [IO.File]::ReadAllText($StatePath).TrimEnd() -cne $manifest.TrimEnd()) {
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($StatePath)) | Out-Null
    $temporary = $StatePath + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($temporary, $manifest + "`n", [Text.UTF8Encoding]::new($false))
        if (Test-Path -LiteralPath $StatePath) { Move-FontFile $temporary $StatePath }
        else { [IO.File]::Move($temporary, $StatePath) }
    } finally {
        if (Test-Path -LiteralPath $temporary) { [IO.File]::Delete($temporary) }
    }
}
