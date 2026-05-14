#Requires -Version 5.1
<#
.SYNOPSIS
    Install desktop fonts user-wide on Windows. Counterpart to install-fonts.sh.

.DESCRIPTION
    Downloads font release archives from GitHub and installs the .ttf/.otf
    files to the per-user fonts directory:

        $env:LOCALAPPDATA\Microsoft\Windows\Fonts

    Each file is also registered under HKCU so apps see it without re-login.
    No admin rights required (Windows 10 1803+).

    Add new fonts by appending entries to the $Fonts array near the top.

.PARAMETER Force
    Reinstall fonts even when the marker file is already present.

.EXAMPLE
    .\install-fonts.ps1
    Skips fonts already installed.

.EXAMPLE
    .\install-fonts.ps1 -Force
    Reinstalls every entry in the registry.
#>
[CmdletBinding()]
param(
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Font registry. To add a font, append one hashtable entry:
#
#   Name          Human-readable label used in log lines.
#   Repo          GitHub <owner>/<repo>. Latest release is queried.
#   AssetPattern  Glob handed to `gh release download --pattern`. Must match
#                 exactly one asset in the latest release.
#   Marker        Filename or glob (e.g. 'Foo-Ver*.ttf') matching at least one
#                 file installed by this entry. If any file in the user font
#                 directory matches, the entry is treated as already installed
#                 (re-run with -Force to override). Pick a marker distinct
#                 from other registry entries' markers to avoid false matches.
#   SourceDirs   Directories *inside the unzipped archive* whose .ttf/.otf/
#                 .ttc files should be installed. Use './' for the archive
#                 root. Other files are ignored.
# ---------------------------------------------------------------------------
$Fonts = @(
    @{
        Name         = 'Pretendard'
        Repo         = 'orioncactus/pretendard'
        AssetPattern = 'Pretendard-*.zip'
        Marker       = 'PretendardVariable.ttf'
        SourceDirs   = @('public/variable', 'public/static', 'public/static/alternative')
    },
    @{
        Name         = 'PretendardJP'
        Repo         = 'orioncactus/pretendard'
        AssetPattern = 'PretendardJP-*.zip'
        Marker       = 'PretendardJPVariable.ttf'
        SourceDirs   = @('public/variable', 'public/static', 'public/static/alternative')
    },
    @{
        Name         = 'D2Coding'
        Repo         = 'naver/d2codingfont'
        AssetPattern = 'D2Coding-*.zip'
        Marker       = 'D2Coding-Ver*.ttf'
        SourceDirs   = @('D2Coding', 'D2CodingAll', 'D2CodingLigature')
    },
    @{
        Name         = 'JetBrainsMono'
        Repo         = 'JetBrains/JetBrainsMono'
        AssetPattern = 'JetBrainsMono-*.zip'
        Marker       = 'JetBrainsMono-Regular.ttf'
        SourceDirs   = @('fonts/variable', 'fonts/ttf')
    },
    @{
        Name         = 'D2CodingNerd'
        Repo         = 'ryanoasis/nerd-fonts'
        AssetPattern = 'D2Coding.zip'
        Marker       = 'D2CodingLigatureNerdFont-Regular.ttf'
        SourceDirs   = @('.')
    },
    @{
        Name         = 'JetBrainsMonoNerd'
        Repo         = 'ryanoasis/nerd-fonts'
        AssetPattern = 'JetBrainsMono.zip'
        Marker       = 'JetBrainsMonoNerdFont-Regular.ttf'
        SourceDirs   = @('.')
    }
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Write-Log {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "install-fonts.ps1: $Message"
}

# Mirror auth-gh.ps1: prefer system gh, fall back to mise-managed gh@latest.
function Get-GhCommand {
    if (Get-Command gh -ErrorAction SilentlyContinue) {
        return @('gh')
    }
    if (Get-Command mise -ErrorAction SilentlyContinue) {
        return @('mise', 'exec', 'gh@latest', '--', 'gh')
    }
    throw 'gh not found and mise unavailable as fallback. Install GitHub CLI (https://cli.github.com/) or mise (https://mise.jdx.dev/).'
}

function Invoke-Gh {
    param([Parameter(Mandatory)][string[]]$Arguments)
    # @(...) forces array semantics: PowerShell's `return` unwraps single-element
    # arrays into scalars, so `return @('gh')` from Get-GhCommand would arrive
    # here as the string 'gh' and $gh[0] would be the character 'g'. Wrapping
    # the call in @(...) re-collects whatever shape into a proper array.
    $gh = @(Get-GhCommand)
    $exe = $gh[0]
    $rest = if ($gh.Length -gt 1) { $gh[1..($gh.Length - 1)] } else { @() }
    $argList = @($rest + $Arguments)
    & $exe @argList
    if ($LASTEXITCODE -ne 0) {
        throw "gh exited with code $LASTEXITCODE"
    }
}

# Install one font file into the user fonts dir AND register it under HKCU so
# already-running apps pick it up on next launch.
function Install-FontFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$DestDir
    )

    $fileName = Split-Path -Leaf $Path
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($fileName)
    $ext = [System.IO.Path]::GetExtension($fileName).ToLower()

    # Windows registers .ttc TrueType collections under "(TrueType)" — apps
    # discover the contained faces from the file itself.
    $regType = switch ($ext) {
        '.otf' { 'OpenType' }
        '.ttf' { 'TrueType' }
        '.ttc' { 'TrueType' }
        default { return }
    }

    if (-not (Test-Path $DestDir)) {
        New-Item -ItemType Directory -Path $DestDir -Force | Out-Null
    }

    $destPath = Join-Path $DestDir $fileName
    Copy-Item -Path $Path -Destination $destPath -Force

    $regPath = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts'
    if (-not (Test-Path $regPath)) {
        New-Item -Path $regPath -Force | Out-Null
    }
    New-ItemProperty `
        -Path $regPath `
        -Name "$baseName ($regType)" `
        -Value $destPath `
        -PropertyType String `
        -Force | Out-Null
}

function Install-Font {
    param(
        [Parameter(Mandatory)][hashtable]$Entry,
        [Parameter(Mandatory)][string]$DestDir,
        [Parameter(Mandatory)][string]$TempRoot,
        [Parameter(Mandatory)][bool]$ForceFlag
    )

    $name = $Entry.Name

    # Get-ChildItem -Filter accepts wildcards (`*` and `?`), so the same code
    # path handles exact-match markers and patterns like 'Foo-Ver*.ttf'.
    $existing = @(
        Get-ChildItem -Path $DestDir -Filter $Entry.Marker -File -ErrorAction SilentlyContinue
    )
    if (($existing.Count -gt 0) -and (-not $ForceFlag)) {
        Write-Log "$name`: already installed (matched: $($existing[0].Name)) — use -Force to reinstall"
        return
    }

    Write-Log "$name`: downloading from github.com/$($Entry.Repo) (pattern: $($Entry.AssetPattern))"

    $work = Join-Path $TempRoot $name
    New-Item -ItemType Directory -Path $work -Force | Out-Null

    Invoke-Gh @(
        'release', 'download',
        '--repo', $Entry.Repo,
        '--pattern', $Entry.AssetPattern,
        '--dir', $work,
        '--clobber'
    )

    $zip = Get-ChildItem -Path $work -Filter '*.zip' -File | Select-Object -First 1
    if (-not $zip) {
        throw "$($name): no archive downloaded for pattern $($Entry.AssetPattern)"
    }

    Write-Log "$name`: extracting $($zip.Name)"
    $extracted = Join-Path $work 'extracted'
    Expand-Archive -Path $zip.FullName -DestinationPath $extracted -Force

    $count = 0
    foreach ($srcRel in $Entry.SourceDirs) {
        $src = Join-Path $extracted ($srcRel -replace '/', '\')
        if (-not (Test-Path $src)) { continue }

        Get-ChildItem -Path $src -File `
            | Where-Object { $_.Extension -in '.ttf', '.otf', '.ttc' } `
            | ForEach-Object {
                Install-FontFile -Path $_.FullName -DestDir $DestDir
                $count++
            }
    }

    if ($count -eq 0) {
        throw "$($name): no .ttf/.otf/.ttc files found under: $($Entry.SourceDirs -join ', ')"
    }

    Write-Log "$name`: installed $count font file(s) to $DestDir"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

# $IsLinux / $IsMacOS exist on PowerShell 6+. On Windows PowerShell 5.1 they
# are $null, so the check correctly evaluates false and we proceed.
if ($IsLinux -or $IsMacOS) {
    throw 'install-fonts.ps1 is Windows-only. Use install-fonts.sh on macOS/Linux.'
}

# Per-user Fonts directory; Windows 10 1803+ supports per-user font install
# (no admin) when the file is here AND registered under HKCU.
$UserFontDir = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts'
$TempRoot = Join-Path $env:TEMP ("install-fonts-{0}" -f [Guid]::NewGuid().ToString('N'))

try {
    New-Item -ItemType Directory -Path $TempRoot -Force | Out-Null

    foreach ($font in $Fonts) {
        Install-Font `
            -Entry $font `
            -DestDir $UserFontDir `
            -TempRoot $TempRoot `
            -ForceFlag $Force.IsPresent
    }

    Write-Log 'done'
}
finally {
    if (Test-Path $TempRoot) {
        Remove-Item -Recurse -Force -Path $TempRoot
    }
}
