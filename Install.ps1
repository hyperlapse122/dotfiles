$ErrorActionPreference = 'Stop'

winget install --source winget Git.Git Microsoft.PowerShell Python.Python.3.14 gnupg.gpg4win

$CONFIG = $IsWindows ? "install-windows.conf.yaml" : "install.conf.yaml"
$PYTHON_EXECUTABLE = "python"

$ROOT_CONFIG = $IsWindows ? $null : "install-root.conf.yaml"
$DOTBOT_DIR = "dotbot"
$DOTBOT_BIN = "bin/dotbot"
$BASEDIR = Split-Path -Parent $MyInvocation.MyCommand.Definition

# If there is no Python executable, exit
if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
    Write-Host "Python not found. Please install it."
    exit 1
}

Set-Location $BASEDIR
git submodule sync --quiet --recursive
git submodule update --init --recursive

winget install --source winget Microsoft.DotNet.SDK.10 Microsoft.DotNet.SDK.9 Microsoft.DotNet.SDK.8 Microsoft.DotNet.SDK.7 Microsoft.DotNet.SDK.6 GnuWin32.Bison GnuWin32.Cpio GnuWin32.DiffUtils GnuWin32.File GnuWin32.GetText GnuWin32.Grep GnuWin32.Gzip GnuWin32.M4 GnuWin32.Make GnuWin32.UnZip GnuWin32.Zip GnuWin32.FindUtils GnuWin32.Gperf GnuWin32.Patch GnuWin32.Tar GnuWin32.Tree GnuWin32.Which cURL.cURL

$CMD = "$PYTHON_EXECUTABLE `"$BASEDIR/$DOTBOT_DIR/$DOTBOT_BIN`" -d `"$BASEDIR`" -c `"$CONFIG`""
Write-Output $CMD
Invoke-Expression $CMD

if ($ROOT_CONFIG -and -not $IsWindows) {
    sudo $PYTHON_EXECUTABLE "$BASEDIR/$DOTBOT_DIR/$DOTBOT_BIN" "-d" "$BASEDIR" "-c" "$ROOT_CONFIG" @args
}