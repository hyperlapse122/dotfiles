#!/usr/bin/env pwsh
#Requires -Version 5.1

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$scratchRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("dotfiles-op-auth-test-{0}" -f ([Guid]::NewGuid().ToString('N')))
$stubDir = Join-Path $scratchRoot 'bin'
$emptyDir = Join-Path $scratchRoot 'empty'
$logFile = Join-Path $scratchRoot 'op.log'
$pathSeparator = [System.IO.Path]::PathSeparator
$isWindowsHost = [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT
$pathVariableName = if ($isWindowsHost) { 'Path' } else { 'PATH' }
$originalPath = [Environment]::GetEnvironmentVariable($pathVariableName, 'Process')
function Set-ProcessPath {
    param([Parameter(Mandatory = $true)][string] $Value)
    [Environment]::SetEnvironmentVariable($pathVariableName, $Value, 'Process')
}

try {
    New-Item -ItemType Directory -Path $stubDir, $emptyDir -Force | Out-Null
    @'
@echo off
>>"%OP_STUB_LOG%" echo %*
echo vault-metadata-sentinel
echo approval-diagnostic-sentinel 1>&2
if "%~1"=="vault" if "%~2"=="list" if "%~3"=="" exit /b %OP_STUB_VAULT_EXIT%
exit /b 97
'@ | Set-Content -Path (Join-Path $stubDir 'op.cmd') -Encoding Ascii
    if (-not $isWindowsHost) {
        @'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$OP_STUB_LOG"
printf 'vault-metadata-sentinel\n'
printf 'approval-diagnostic-sentinel\n' >&2
if [[ "${1-}" == vault && "${2-}" == list && $# -eq 2 ]]; then
  exit "${OP_STUB_VAULT_EXIT:-0}"
fi
exit 97
'@ | Set-Content -Path (Join-Path $stubDir 'op') -Encoding Ascii
        & chmod 0700 (Join-Path $stubDir 'op')
        if ($LASTEXITCODE -ne 0) { throw 'chmod failed for the POSIX op stub.' }
    }

    $env:_INSTALL_PREREQUISITES_TEST_SOURCE = '1'
    . (Join-Path $repoRoot '.install-prerequisites.ps1')
    Remove-Item Env:_INSTALL_PREREQUISITES_TEST_SOURCE

    Set-ProcessPath "${stubDir}${pathSeparator}${originalPath}"
    $env:OP_STUB_LOG = $logFile

    function Assert-Probe {
        param(
            [Parameter(Mandatory = $true)][string] $Label,
            [Parameter(Mandatory = $true)][bool] $Expected
        )

        Set-Content -Path $logFile -Value '' -NoNewline
        $result = @(Test-OpReady)
        if ($result.Count -ne 1 -or $result[0] -isnot [bool] -or $result[0] -ne $Expected) {
            throw "${Label}: Test-OpReady returned '$($result -join ',')', expected $Expected without leaked output."
        }
        $calls = Get-Content -Path $logFile -Raw
        if ($null -eq $calls) {
            $calls = ''
        } else {
            $calls = $calls.Trim()
        }
        if ($calls -ne 'vault list') {
            throw "${Label}: unexpected op command '$calls'."
        }
    }

    $env:OP_STUB_VAULT_EXIT = '0'
    Remove-Item Env:OP_SERVICE_ACCOUNT_TOKEN -ErrorAction SilentlyContinue
    Assert-Probe -Label 'desktop integration' -Expected $true

    $env:OP_SERVICE_ACCOUNT_TOKEN = 'fixture-token'
    Assert-Probe -Label 'service account' -Expected $true
    Remove-Item Env:OP_SERVICE_ACCOUNT_TOKEN

    $env:OP_STUB_VAULT_EXIT = '1'
    Assert-Probe -Label 'unauthenticated CLI' -Expected $false

    Set-Content -Path $logFile -Value '' -NoNewline
    $hookPath = (Join-Path $repoRoot '.install-prerequisites.ps1').Replace("'", "''")
    $missingScript = @"
`$env:_INSTALL_PREREQUISITES_TEST_SOURCE = '1'
. '$hookPath'
Test-OpReady
"@
    Set-ProcessPath $emptyDir
    $runspace = [PowerShell]::Create()
    try {
        $missingResult = @($runspace.AddScript($missingScript).Invoke())
        if ($runspace.HadErrors -or $missingResult.Count -ne 1 -or $missingResult[0] -ne $false) {
            throw "missing CLI: isolated Test-OpReady returned '$($missingResult -join ',')', expected False."
        }
    } finally {
        $runspace.Dispose()
        Set-ProcessPath "${stubDir}${pathSeparator}${originalPath}"
    }
    if ((Get-Item $logFile).Length -ne 0) {
        throw 'missing CLI: an op command was invoked.'
    }

    Write-Output 'install-prerequisites op auth Windows fixture: PASS'
} finally {
    Set-ProcessPath $originalPath
    Remove-Item Env:OP_STUB_LOG -ErrorAction SilentlyContinue
    Remove-Item Env:OP_STUB_VAULT_EXIT -ErrorAction SilentlyContinue
    Remove-Item Env:OP_SERVICE_ACCOUNT_TOKEN -ErrorAction SilentlyContinue
    Remove-Item Env:_INSTALL_PREREQUISITES_TEST_SOURCE -ErrorAction SilentlyContinue
    Remove-Item -Path $scratchRoot -Recurse -Force -ErrorAction SilentlyContinue
}
exit 0
