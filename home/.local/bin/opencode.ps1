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

    If the manifest fetch fails (offline, GitHub down, `gh` not authenticated),
    the wrapper degrades gracefully to running `mise exec` against the unpinned
    `github:anomalyco/opencode` backend instead of aborting — so opencode still
    launches (mise reuses whatever it last installed) when version resolution
    is unavailable.

    Mirrors the writeShellApplication wrapper from the legacy nix-config
    (home/modules/dev/opencode/default.nix); see AGENTS.md for the rule that
    migrated files become the source of truth here.

    Manifest: the `latest.json` asset attached to anomalyco/opencode's latest
    release — fetched via the GitHub CLI (`gh release download`), which injects
    auth itself and follows any redirects/rate-limit handling for us.
        { "version": "X.Y.Z", "platforms": { ... } }

    Install path: %USERPROFILE%\.local\bin\opencode.ps1 (linked from
    install.windows.yaml). PowerShell resolves `opencode` as a bare command
    once %USERPROFILE%\.local\bin is on PATH — that PATH entry is the user's
    responsibility (we don't mutate PATH from bootstrap).

    Dependencies: `mise`, `gh` on PATH. The manifest is fetched with `gh` and
    parsed with built-in ConvertFrom-Json, so curl / jq are not required on
    Windows.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

foreach ($cmd in @('mise', 'gh')) {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
        Write-Error "opencode: required dependency ``$cmd`` not found on PATH"
        exit 1
    }
}

$resolvedVersion = $null
try {
    $manifestJson = & gh release download --repo anomalyco/opencode --pattern latest.json --output -
    if ($LASTEXITCODE -ne 0) {
        throw "gh release download exited with code $LASTEXITCODE"
    }
    $resolvedVersion = ($manifestJson | ConvertFrom-Json).version
}
catch {
    $resolvedVersion = $null
}

if (-not [string]::IsNullOrWhiteSpace($resolvedVersion)) {
    $backend = "github:anomalyco/opencode@$resolvedVersion"
}
else {
    Write-Warning 'opencode: could not resolve latest version from GitHub manifest; falling back to unpinned opencode'
    $backend = 'github:anomalyco/opencode'
}

& mise exec -q $backend -- opencode @args
exit $LASTEXITCODE
