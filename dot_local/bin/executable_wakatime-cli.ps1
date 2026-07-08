#!/usr/bin/env pwsh
#Requires -Version 5.1
<#
.SYNOPSIS
    wakatime-cli.ps1 — mise wrapper for the WakaTime CLI.

.DESCRIPTION
    Windows counterpart to ~/.local/bin/wakatime-cli. Resolves the
    platform-specific wakatime-cli binary (windows-amd64 or windows-arm64)
    at invocation time and hands it to `mise exec` against the
    github:wakatime/wakatime-cli backend.

    Mirrors the POSIX wrapper: `mise exec` fetches the backend on first run
    (`-yq` auto-installs quietly), then runs the platform-tagged binary
    (`wakatime-cli-windows-<arch>.exe`) with the passed arguments. The
    binary name follows WakaTime's goreleaser convention — the archive
    `wakatime-cli-windows-<arch>.zip` ships a single
    `wakatime-cli-windows-<arch>.exe` inside.

    Install path: %USERPROFILE%\.local\bin\wakatime-cli.ps1. PowerShell
    resolves `wakatime-cli` as a bare command once %USERPROFILE%\.local\bin
    is on PATH — that PATH entry is the user's responsibility (we don't
    mutate PATH from bootstrap).

    Dependencies: `mise` on PATH.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not (Get-Command 'mise' -ErrorAction SilentlyContinue)) {
    Write-Error 'wakatime-cli: required dependency ``mise`` not found on PATH'
    exit 1
}

$arch = switch ($env:PROCESSOR_ARCHITECTURE) {
    'AMD64' { 'amd64' }
    'ARM64' { 'arm64' }
    default {
        Write-Error "wakatime-cli: unsupported architecture '$env:PROCESSOR_ARCHITECTURE'"
        exit 1
    }
}

& mise --no-config --no-env --no-hooks exec -yq 'github:wakatime/wakatime-cli' -- "wakatime-cli-windows-$arch.exe" @args
exit $LASTEXITCODE
