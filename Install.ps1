$ErrorActionPreference = 'Stop'

$CONFIG = $IsWindows ? "install-windows.conf.yaml" : "install.conf.yaml"
$PYTHON_EXECUTABLE = "python"

$ROOT_CONFIG = $IsWindows ? $null : "install-root.conf.yaml"
$DOTBOT_DIR = "dotbot"
$DOTBOT_BIN = "bin/dotbot"
$BASEDIR = Split-Path -Parent $MyInvocation.MyCommand.Definition

# If there is no Python executable, exit
if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
    Write-Host "Python not found. Please install it from https://www.python.org/downloads/"
    exit 1
}

Set-Location $BASEDIR
git submodule sync --quiet --recursive
git submodule update --init --recursive

if($IsWindows) {
    & "$PYTHON_EXECUTABLE" "$BASEDIR/$DOTBOT_DIR/$DOTBOT_BIN" "--plugin" "dotbot-windows/dotbot_windows.py" "-d" "$BASEDIR" "-c" "$CONFIG" @args
}
else {
    & "$PYTHON_EXECUTABLE" "$BASEDIR/$DOTBOT_DIR/$DOTBOT_BIN" "-d" "$BASEDIR" "-c" "$CONFIG" @args
}

if ($ROOT_CONFIG -and -not $IsWindows) {
    sudo "$PYTHON_EXECUTABLE" "$BASEDIR/$DOTBOT_DIR/$DOTBOT_BIN" "-d" "$BASEDIR" "-c" "$ROOT_CONFIG" @args
}