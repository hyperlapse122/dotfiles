param(
    [string]$Payload = 'e30='
)

$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot 'check-wsl2.ps1')

$previous = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Payload)) | ConvertFrom-Json
if ($previous.command) {
    $arguments = @($previous.args | ForEach-Object { [string]$_ })
    $global:LASTEXITCODE = 0
    & $previous.command @arguments
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
