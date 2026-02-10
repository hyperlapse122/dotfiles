$ErrorActionPreference = 'Stop'

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

# install dotnet LTS and 8
& "$BASEDIR/dotnet/dotnet-install.ps1" -Channel LTS -NoPath
& "$BASEDIR/dotnet/dotnet-install.ps1" -Channel 9.0 -NoPath
& "$BASEDIR/dotnet/dotnet-install.ps1" -Channel 8.0 -NoPath
& "$BASEDIR/dotnet/dotnet-install.ps1" -Channel 7.0 -NoPath
& "$BASEDIR/dotnet/dotnet-install.ps1" -Channel 6.0 -NoPath

$CMD = "$PYTHON_EXECUTABLE `"$BASEDIR/$DOTBOT_DIR/$DOTBOT_BIN`" -d `"$BASEDIR`" -c `"$CONFIG`""
Write-Output $CMD
Invoke-Expression $CMD

if ($ROOT_CONFIG -and -not $IsWindows) {
    sudo $PYTHON_EXECUTABLE "$BASEDIR/$DOTBOT_DIR/$DOTBOT_BIN" "-d" "$BASEDIR" "-c" "$ROOT_CONFIG" @args
}