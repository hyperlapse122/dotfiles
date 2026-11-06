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

# Windows refuses to replace a running executable but allows renaming it within its volume.
# The retired copy leaves the owned roots and is deleted once nothing holds it.
function Install-PreparedFile([string] $Source, [string] $Target) {
    if ([DotfilesAssetFiles]::MoveFileEx($Source, $Target, 1)) { return }
    $code = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
    if ($code -ne 5 -or -not [IO.File]::Exists($Target)) { throw [ComponentModel.Win32Exception]::new($code) }
    [IO.Directory]::CreateDirectory($retired) | Out-Null
    $aside = Join-AssetPath $retired ([Guid]::NewGuid().ToString('N'))
    if (-not [DotfilesAssetFiles]::MoveFileEx($Target, $aside, 0)) { throw [ComponentModel.Win32Exception]::new($code) }
    if (-not [DotfilesAssetFiles]::MoveFileEx($Source, $Target, 0)) {
        $code = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        $null = [DotfilesAssetFiles]::MoveFileEx($aside, $Target, 0)
        throw [ComponentModel.Win32Exception]::new($code)
    }
    try { [IO.File]::Delete($aside) } catch { }
}

function Clear-RetiredFiles {
    if (-not [IO.Directory]::Exists($retired)) { return }
    foreach ($file in [IO.Directory]::GetFiles($retired)) {
        try { [IO.File]::Delete($file) } catch { }
    }
}

# Windows PowerShell 5.1 is not long-path aware, even with LongPathsEnabled, and the
# generation tree prefix pushes deep plugin files past MAX_PATH. Extended-length paths
# bypass that limit; chezmoi receives the ordinary spelling.
function ConvertTo-ExtendedPath([string] $Path) {
    if ([IO.Path]::DirectorySeparatorChar -ne '\' -or $Path.StartsWith('\\?\')) { return $Path }
    if ($Path.StartsWith('\\')) { return '\\?\UNC\' + $Path.Substring(2) }
    return '\\?\' + $Path
}

function ConvertFrom-ExtendedPath([string] $Path) {
    if ($Path.StartsWith('\\?\UNC\')) { return '\\' + $Path.Substring(8) }
    if ($Path.StartsWith('\\?\')) { return $Path.Substring(4) }
    return $Path
}

# Join-Path rejects extended-length paths, which also skip separator normalization.
function Join-AssetPath([string] $Base, [string] $Child) {
    return [IO.Path]::Combine($Base, $Child.Replace('/', [IO.Path]::DirectorySeparatorChar))
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
    $path = Join-AssetPath $Base $Root.path
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
        $items[$root.path] = Get-Item -LiteralPath (Join-AssetPath $Base $root.path) -Force -ErrorAction SilentlyContinue
        $enumerationBase = $Base
        if ($Installed -and -not $root.exact) { $enumerationBase = $tree }
        foreach ($item in @(Get-RootEntries $enumerationBase $root)) {
            $relative = Get-RelativePath $enumerationBase $item.FullName
            if ($enumerationBase -eq $Base) { $items[$relative] = $item }
            else { $items[$relative] = Get-Item -LiteralPath (Join-AssetPath $Base $relative) -Force -ErrorAction SilentlyContinue }
        }
    }
    $rows = foreach ($relative in @($items.Keys | Sort-Object)) {
        $path = Join-AssetPath $Base $relative
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
        Install-PreparedFile $temporary $Target
    } finally { [IO.File]::Delete($temporary) }
}

$Destination = ConvertTo-ExtendedPath ([IO.Path]::GetFullPath($Destination))
$CacheDirectory = ConvertTo-ExtendedPath ([IO.Path]::GetFullPath($CacheDirectory))
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
    $null = Assert-ContainedPath (Join-AssetPath $Destination $fields[0]) $Destination
    $roots += @{ path = $fields[0]; kind = $fields[1]; exact = ($fields[2] -eq 'true') }
}
if (-not $roots.Count) {
    if ($manifest.Trim()) { throw 'External manifest has no declared managed roots.' }
    return
}

$generation = Join-AssetPath (Join-AssetPath $CacheDirectory 'generations') (Get-TextHash ($manifest + "`n" + $rootText))
$tree = Join-AssetPath $generation 'tree'
$source = Join-AssetPath $generation 'source'
$prepared = Join-AssetPath $generation 'prepared'
$cacheSnapshot = Join-AssetPath $generation 'cache.snapshot'
$destinationSnapshot = Join-AssetPath $generation 'destination.snapshot'
$retired = Join-AssetPath $CacheDirectory 'retired'
Assert-OrdinaryPath $CacheDirectory
Assert-OrdinaryPath $generation
Assert-OrdinaryPath $tree
Assert-OrdinaryPath $retired
Clear-RetiredFiles
[IO.Directory]::CreateDirectory($source) | Out-Null
$config = Join-AssetPath $CacheDirectory 'config.toml'
[IO.File]::WriteAllText($config, '', $utf8)
$cacheIntact = [IO.File]::Exists($prepared) -and [IO.File]::Exists($cacheSnapshot) -and
    ([IO.File]::ReadAllText($cacheSnapshot) -ceq (Get-Snapshot $tree))

if ($Mode -ne 'normal' -or -not $cacheIntact) {
    Write-Host 'Preparing external assets'
    [IO.File]::Delete($prepared)
    Remove-OwnedPath $tree $generation
    [IO.Directory]::CreateDirectory($tree) | Out-Null
    [IO.File]::WriteAllText((Join-AssetPath $source '.chezmoiexternal.toml'), $manifest, $utf8)
    $arguments = @('--config', $config, '--source', $source, '--destination', $tree,
        '--cache', (Join-AssetPath $CacheDirectory 'downloads'),
        '--persistent-state', (Join-AssetPath $CacheDirectory 'state.boltdb')) |
        ForEach-Object { ConvertFrom-ExtendedPath $_ }
    $arguments += @('--no-tty', 'apply', '--force', '--exclude=scripts')
    if ($Mode -eq 'refresh') { $arguments += '--refresh-externals=always' }
    & $Chezmoi @arguments
    if ($LASTEXITCODE -ne 0) { throw "External asset preparation failed: chezmoi exited with code $LASTEXITCODE" }
    foreach ($root in $roots) {
        $path = Join-AssetPath $tree $root.path
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
    $sourceRoot = Join-AssetPath $tree $root.path
    $targetRoot = Join-AssetPath $Destination $root.path
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
        $target = Join-AssetPath $Destination (Get-RelativePath $tree $entry.FullName)
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
