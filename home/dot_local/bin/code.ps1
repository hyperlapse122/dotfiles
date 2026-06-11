#!/usr/bin/env pwsh
#Requires -Version 5.1
<#
.SYNOPSIS
    code.ps1 — VS Codium shim.

.DESCRIPTION
    Windows counterpart to ~/.local/bin/code. Runs `codium` so the `code`
    command keeps working after migrating from VS Code to VS Codium.

    Replaces the former `alias code=codium` (a Unix-shell-only construct): a
    real script on PATH also covers tools that shell out to `code`, such as
    `git config core.editor` or `$EDITOR` / `$VISUAL`.

    Install path: %USERPROFILE%\.local\bin\code.ps1 (linked from the Windows
    bootstrap config). PowerShell resolves `code` as a bare command once
    %USERPROFILE%\.local\bin is on PATH — that PATH entry is the user's
    responsibility (we don't mutate PATH from bootstrap).

    Dependencies: `codium` on PATH (VS Codium install).
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not (Get-Command 'codium' -ErrorAction SilentlyContinue)) {
    Write-Error 'code: `codium` not found on PATH (install VS Codium)'
    exit 127
}

& codium @args
exit $LASTEXITCODE
