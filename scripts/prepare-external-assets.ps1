param(
    [Parameter(Mandatory = $true, Position = 0)][string] $ManifestPath,
    [Parameter(Mandatory = $true, Position = 1)][string] $RootsPath,
    [Parameter(Mandatory = $true, Position = 2)][string] $Destination,
    [Parameter(Mandatory = $true, Position = 3)][string] $CacheDirectory,
    [Parameter(Mandatory = $true, Position = 4)][string] $Chezmoi,
    [Parameter(Position = 5)][ValidateSet('normal', 'verify', 'refresh')][string] $Mode = 'normal'
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
$utf8 = [Text.UTF8Encoding]::new($false)
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class DotfilesAssetFiles {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool MoveFileEx(string source, string target, uint flags);
}
'@

function Move-AtomicFile([string] $Source, [string] $Target) {
    if (-not [DotfilesAssetFiles]::MoveFileEx($Source, $Target, 1)) {
        throw [ComponentModel.Win32Exception]::new([Runtime.InteropServices.Marshal]::GetLastWin32Error())
    }
}

function Get-TextHash([string] $Text) {
    $hash = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($hash.ComputeHash($utf8.GetBytes($Text))).Replace('-', '').ToLowerInvariant() }
    finally { $hash.Dispose() }
}

function Assert-ContainedPath([string] $Path, [string] $Boundary) {
    $full = [IO.Path]::GetFullPath($Path)
    $parent = [IO.Path]::GetFullPath($Boundary).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $full.StartsWith($parent, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Asset path is outside its owned root: $Path"
    }
    $cursor = [IO.Path]::GetDirectoryName($full)
    while ($cursor -and $cursor.Length -ge $parent.TrimEnd('\', '/').Length) {
        Assert-OrdinaryPath $cursor
        $cursor = [IO.Path]::GetDirectoryName($cursor)
    }
    return $full
}

function Assert-OrdinaryPath([string] $Path) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "Asset cache cannot traverse a reparse point: $Path"
    }
}

function Remove-OwnedPath([string] $Path, [string] $Boundary) {
    $full = Assert-ContainedPath $Path $Boundary
    if (Test-Path -LiteralPath $full) {
        Assert-OrdinaryPath $full
        # Check descendants before recursive removal; never traverse an installed junction.
        if (Test-Path -LiteralPath $full -PathType Container) {
            foreach ($item in Get-ChildItem -LiteralPath $full -Force -Recurse) {
                if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                    throw "Asset cleanup cannot traverse a reparse point: $($item.FullName)"
                }
            }
        }
        Remove-Item -LiteralPath $full -Force -Recurse
    }
}

function Get-RelativePath([string] $Base, [string] $Path) {
    return $Path.Substring($Base.TrimEnd('\', '/').Length + 1).Replace('\', '/')
}

function Get-RootEntries([string] $Base, $Root) {
    $path = Join-Path $Base $Root.path
    $item = Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    if (-not $item) { return }
    Assert-OrdinaryPath $path
    $item
    if ($item.PSIsContainer) {
        foreach ($child in Get-ChildItem -LiteralPath $path -Recurse -Force) {
            if ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "Asset cache cannot traverse a reparse point: $($child.FullName)"
            }
            $child
        }
    }
}

function Get-Snapshot([string] $Base, [bool] $Installed = $false) {
    $items = @{}
    foreach ($root in $roots) {
        $items[$root.path] = Get-Item -LiteralPath (Join-Path $Base $root.path) -Force -ErrorAction SilentlyContinue
        $enumerationBase = $Base
        if ($Installed -and -not $root.exact) { $enumerationBase = $tree }
        foreach ($item in @(Get-RootEntries $enumerationBase $root)) {
            $relative = Get-RelativePath $enumerationBase $item.FullName
            if ($enumerationBase -eq $Base) { $items[$relative] = $item }
            else { $items[$relative] = Get-Item -LiteralPath (Join-Path $Base $relative) -Force -ErrorAction SilentlyContinue }
        }
    }
    $rows = foreach ($relative in @($items.Keys | Sort-Object)) {
        $path = Join-Path $Base $relative
        $item = $items[$relative]
        if (-not $item) { "missing`t$relative"; continue }
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "Asset cache cannot traverse a reparse point: $path"
        }
        if ($item.PSIsContainer) {
            "directory`t$relative"
        } else {
            "file`t$relative`t$($item.Length)`t$($item.LastWriteTimeUtc.Ticks)`t$([int]$item.Attributes)"
        }
    }
    return $rows -join "`n"
}

function Write-AtomicText([string] $Path, [string] $Text) {
    $temporary = $Path + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($temporary, $Text, $utf8)
        Move-AtomicFile $temporary $Path
    } finally { [IO.File]::Delete($temporary) }
}

function Copy-PreparedFile([string] $Source, [string] $Target) {
    $null = Assert-ContainedPath $Target $Destination
    Assert-OrdinaryPath $Target
    if ($Mode -eq 'normal' -and [IO.File]::Exists($Target)) {
        $sourceInfo = Get-Item -LiteralPath $Source -Force
        $targetInfo = Get-Item -LiteralPath $Target -Force
        if ($sourceInfo.Length -eq $targetInfo.Length -and
            $sourceInfo.LastWriteTimeUtc.Ticks -eq $targetInfo.LastWriteTimeUtc.Ticks -and
            $sourceInfo.Attributes -eq $targetInfo.Attributes) { return }
    }
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Target)) | Out-Null
    $temporary = $Target + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::Copy($Source, $temporary)
        Move-AtomicFile $temporary $Target
    } finally { [IO.File]::Delete($temporary) }
}

$Destination = [IO.Path]::GetFullPath($Destination)
$CacheDirectory = [IO.Path]::GetFullPath($CacheDirectory)
$manifest = [IO.File]::ReadAllText($ManifestPath)
$rootText = [IO.File]::ReadAllText($RootsPath)
$roots = @()
foreach ($line in ($rootText -split "`n")) {
    $line = $line.TrimEnd("`r")
    if (-not $line) { continue }
    $fields = $line.Split("`t")
    if ($fields.Count -ne 3 -or $fields[1] -notin @('file', 'directory') -or
        $fields[2] -notin @('true', 'false') -or $fields[0] -match '[\\:\t\r\n]' -or
        $fields[0].StartsWith('/') -or @($fields[0].Split('/') | Where-Object { $_ -in @('', '.', '..') }).Count) {
        throw "Invalid managed asset root: $line"
    }
    $null = Assert-ContainedPath (Join-Path $Destination $fields[0]) $Destination
    $roots += @{ path = $fields[0]; kind = $fields[1]; exact = ($fields[2] -eq 'true') }
}
if (-not $roots.Count) {
    if ($manifest.Trim()) { throw 'External manifest has no declared managed roots.' }
    return
}

$generation = Join-Path (Join-Path $CacheDirectory 'generations') (Get-TextHash ($manifest + "`n" + $rootText))
$tree = Join-Path $generation 'tree'
$source = Join-Path $generation 'source'
$prepared = Join-Path $generation 'prepared'
$cacheSnapshot = Join-Path $generation 'cache.snapshot'
$destinationSnapshot = Join-Path $generation 'destination.snapshot'
Assert-OrdinaryPath $CacheDirectory
Assert-OrdinaryPath $generation
Assert-OrdinaryPath $tree
[IO.Directory]::CreateDirectory($source) | Out-Null
$config = Join-Path $CacheDirectory 'config.toml'
[IO.File]::WriteAllText($config, '', $utf8)
$cacheIntact = [IO.File]::Exists($prepared) -and [IO.File]::Exists($cacheSnapshot) -and
    ([IO.File]::ReadAllText($cacheSnapshot) -ceq (Get-Snapshot $tree))

if ($Mode -ne 'normal' -or -not $cacheIntact) {
    Write-Host 'Preparing external assets'
    [IO.File]::Delete($prepared)
    Remove-OwnedPath $tree $generation
    [IO.Directory]::CreateDirectory($tree) | Out-Null
    [IO.File]::WriteAllText((Join-Path $source '.chezmoiexternal.toml'), $manifest, $utf8)
    $arguments = @('--config', $config, '--source', $source, '--destination', $tree,
        '--cache', (Join-Path $CacheDirectory 'downloads'),
        '--persistent-state', (Join-Path $CacheDirectory 'state.boltdb'),
        '--no-tty', 'apply', '--force', '--exclude=scripts')
    if ($Mode -eq 'refresh') { $arguments += '--refresh-externals=always' }
    & $Chezmoi @arguments
    if ($LASTEXITCODE -ne 0) { throw "External asset preparation failed: chezmoi exited with code $LASTEXITCODE" }
    foreach ($root in $roots) {
        $path = Join-Path $tree $root.path
        $expectedType = if ($root.kind -eq 'directory') { 'Container' } else { 'Leaf' }
        if (-not (Test-Path -LiteralPath $path -PathType $expectedType)) {
            throw "Prepared asset is missing: $($root.path)"
        }
    }
    Write-AtomicText $cacheSnapshot (Get-Snapshot $tree)
    Write-AtomicText $prepared 'complete'
    $cacheIntact = $false
}

$installedIntact = [IO.File]::Exists($destinationSnapshot) -and
    ([IO.File]::ReadAllText($destinationSnapshot) -ceq (Get-Snapshot $Destination $true))
if ($cacheIntact -and $installedIntact -and $Mode -eq 'normal') {
    Write-Host 'Reusing prepared external assets'
    return
}

foreach ($root in $roots) {
    $sourceRoot = Join-Path $tree $root.path
    $targetRoot = Join-Path $Destination $root.path
    $null = Assert-ContainedPath $targetRoot $Destination
    Assert-OrdinaryPath $targetRoot
    if ($root.kind -eq 'file') {
        if (Test-Path -LiteralPath $targetRoot -PathType Container) { Remove-OwnedPath $targetRoot $Destination }
        Copy-PreparedFile $sourceRoot $targetRoot
        continue
    }
    if (Test-Path -LiteralPath $targetRoot -PathType Leaf) { Remove-OwnedPath $targetRoot $Destination }
    [IO.Directory]::CreateDirectory($targetRoot) | Out-Null
    $entries = @(Get-RootEntries $tree $root)
    $expected = @{}
    foreach ($entry in $entries) { $expected[(Get-RelativePath $tree $entry.FullName)] = $true }
    if ($root.exact) {
        $obsolete = @(Get-ChildItem -LiteralPath $targetRoot -Recurse -Force |
            Where-Object { -not $expected.ContainsKey((Get-RelativePath $Destination $_.FullName)) } |
            Sort-Object { $_.FullName.Length } -Descending)
        foreach ($entry in $obsolete) {
            if (Test-Path -LiteralPath $entry.FullName) { Remove-OwnedPath $entry.FullName $targetRoot }
        }
    }
    foreach ($entry in $entries) {
        $target = Join-Path $Destination (Get-RelativePath $tree $entry.FullName)
        Assert-OrdinaryPath $target
        if ($entry.PSIsContainer) {
            if (Test-Path -LiteralPath $target -PathType Leaf) { Remove-OwnedPath $target $targetRoot }
            [IO.Directory]::CreateDirectory($target) | Out-Null
        } else {
            if (Test-Path -LiteralPath $target -PathType Container) { Remove-OwnedPath $target $targetRoot }
            Copy-PreparedFile $entry.FullName $target
        }
    }
}
Write-AtomicText $destinationSnapshot (Get-Snapshot $Destination $true)
