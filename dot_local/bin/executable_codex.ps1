
#!/usr/bin/env pwsh
#Requires -Version 5.1
<#
.SYNOPSIS
    codex.ps1 — Codex CLI shim (Windows).

.DESCRIPTION
    Windows counterpart to ~/.local/bin/codex. Resolves the real Codex binary
    through the releases/current junction that
    .chezmoiscripts/00-tools/run_onchange_after_codex.ps1.tmpl maintains, so
    the public `codex` command always tracks the release-lock-pinned version.

    The POSIX wrapper routes `codex exec` through tokscale for headless usage
    tracking. tokscale is a bash/mise wrapper with no Windows port, so the
    `exec` subcommand fails closed here with an explicit diagnostic rather
    than silently dropping the tracking contract — run it on a POSIX host.

    Install path: %USERPROFILE%\.local\bin\codex.ps1. PowerShell resolves
    `codex` as a bare command once %USERPROFILE%\.local\bin is on PATH —
    that PATH entry is the user's responsibility (same convention as
    code.ps1).

    Dependencies: the codex external (extracted standalone release) plus the
    00-tools linking script (the current junction).
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$realBin = Join-Path $HOME '.codex\packages\standalone\releases\current\bin'
$realCodex = $null
foreach ($candidate in @('codex.exe', 'codex.cmd', 'codex')) {
  $path = Join-Path $realBin $candidate
  if (Test-Path -LiteralPath $path -PathType Leaf) {
    $realCodex = $path
    break
  }
}

if (-not $realCodex) {
  Write-Error 'codex: real binary not found under releases\current\bin (run chezmoi apply to link the pinned release)'
  exit 127
}

if ($args.Count -gt 0 -and $args[0] -eq 'exec') {
  Write-Error "codex: 'exec' routes through the POSIX-only tokscale wrapper; run it on a POSIX host"
  exit 127
}

& $realCodex @args
exit $LASTEXITCODE
