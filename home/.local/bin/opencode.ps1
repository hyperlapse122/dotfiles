#!/usr/bin/env pwsh
#Requires -Version 5.1
<#
.SYNOPSIS
    opencode.ps1 — mise wrapper that pins opencode to the latest published release.

.DESCRIPTION
    Windows counterpart to ~/.local/bin/opencode. Resolves the latest version
    from anomalyco/opencode's GitHub release manifest at invocation time, then
    hands it to `mise exec`. Avoids editing ~/.config/mise/config.toml every
    time upstream publishes a new build, while still pinning the executed
    version reproducibly within a single invocation.

    Mirrors the writeShellApplication wrapper from the legacy nix-config
    (home/modules/dev/opencode/default.nix); see AGENTS.md for the rule that
    migrated files become the source of truth here.

    Manifest: https://github.com/anomalyco/opencode/releases/latest/download/latest.json
        { "version": "X.Y.Z", "platforms": { ... } }

    Install path: %USERPROFILE%\.local\bin\opencode.ps1 (linked from
    install.windows.yaml). PowerShell resolves `opencode` as a bare command
    once %USERPROFILE%\.local\bin is on PATH — that PATH entry is the user's
    responsibility (we don't mutate PATH from bootstrap).

    Dependencies: `mise` on PATH. HTTP + JSON parsing use built-in
    Invoke-RestMethod, so curl / jq are not required on Windows.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not (Get-Command 'mise' -ErrorAction SilentlyContinue)) {
    Write-Error 'opencode: required dependency `mise` not found on PATH'
    exit 1
}

try {
    $manifest = Invoke-RestMethod -Uri 'https://github.com/anomalyco/opencode/releases/latest/download/latest.json'
}
catch {
    Write-Error "opencode: failed to fetch latest version manifest: $_"
    exit 1
}

$resolvedVersion = $manifest.version
if ([string]::IsNullOrWhiteSpace($resolvedVersion)) {
    Write-Error 'opencode: failed to resolve latest version from GitHub manifest'
    exit 1
}

& mise exec -q "github:anomalyco/opencode@$resolvedVersion" --command "opencode $($args -join " ")"
exit $LASTEXITCODE
