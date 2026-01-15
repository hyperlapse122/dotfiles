$ErrorActionPreference = 'Stop'

$CONFIG = $IsWindows ? "install-windows.conf.yaml" : "install.conf.yaml"
$PYTHON_EXECUTABLE = $IsWindows ? "mise exec python@3 -- python" : "python"

$ROOT_CONFIG = $IsWindows ? $null : "install-root.conf.yaml"
$DOTBOT_DIR = "dotbot"
$DOTBOT_BIN = "bin/dotbot"
$BASEDIR = Split-Path -Parent $MyInvocation.MyCommand.Definition

# If there is no Python executable, exit
if (-not (Get-Command mise -ErrorAction SilentlyContinue)) {
    Write-Host "Mise not found. Please install it from https://mise.jdx.dev/getting-started.html"
    exit 1
}

Set-Location $BASEDIR
git submodule sync --quiet --recursive
git submodule update --init --recursive

# install dotnet LTS and 8
& "$DIR/dotnet/dotnet-install.ps1" -Channel LTS
& "$DIR/dotnet/dotnet-install.ps1" -Channel 8.0

$CMD = "$PYTHON_EXECUTABLE `"$BASEDIR/$DOTBOT_DIR/$DOTBOT_BIN`" `"-d`" `"$BASEDIR`" `"-c`" `"$CONFIG`" @args"
Invoke-Expression $CMD

if ($ROOT_CONFIG -and -not $IsWindows) {
    sudo $PYTHON_EXECUTABLE "$BASEDIR/$DOTBOT_DIR/$DOTBOT_BIN" "-d" "$BASEDIR" "-c" "$ROOT_CONFIG" @args
}