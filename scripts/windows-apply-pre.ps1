param(
    [string]$Payload = 'e30='
)

$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot 'check-wsl2.ps1')

$previous = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Payload)) | ConvertFrom-Json
if ($previous.command) {
    $command = Get-Command $previous.command -CommandType Application -ErrorAction Stop |
        Select-Object -First 1
    # PowerShell 5.1 native invocation drops empty arguments and embedded quotes.
    $arguments = @($previous.args | ForEach-Object {
        $escaped = [regex]::Replace([string]$_, '(\\*)"', '$1$1\"')
        $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
        '"' + $escaped + '"'
    })
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $command.Source
    $start.Arguments = $arguments -join ' '
    $start.UseShellExecute = $false
    $start.WorkingDirectory = (Get-Location).ProviderPath
    $process = [Diagnostics.Process]::Start($start)
    try {
        $process.WaitForExit()
        $exitCode = $process.ExitCode
    } finally {
        $process.Dispose()
    }
    exit $exitCode
}
