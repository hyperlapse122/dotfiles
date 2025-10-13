$ErrorActionPreference = 'Stop'

$CONFIG = "install-windows.conf.yaml"
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

py "$BASEDIR/$DOTBOT_DIR/$DOTBOT_BIN" "--plugin" "dotbot-windows/dotbot_windows.py" "-d" "$BASEDIR" "-c" "$CONFIG" @args
