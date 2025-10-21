
# Get list of .conf files in environment.d and parse as [KEY]=[VALUE] pairs
$envDir = Join-Path $(Split-Path -Parent $MyInvocation.MyCommand.Path) "environment.d"
$windowsEnvDir = Join-Path $(Split-Path -Parent $MyInvocation.MyCommand.Path) "environment.windows.d"
if (Test-Path $envDir || Test-Path $windowsEnvDir) {
    Get-ChildItem -Path $envDir,$windowsEnvDir -Filter "*.conf" | ForEach-Object {
        $lines = Get-Content $_.FullName
        foreach ($line in $lines) {
            if ($line -match '^\s*([A-Z0-9_]+)\s*=\s*"?([^"]*)"?\s*$') {
                $key = $matches[1]
                $value = $matches[2]
                [System.Environment]::SetEnvironmentVariable($key, $value, "User")
                Write-Host "Set environment variable: $key=$value"
            }
        }
    }
} else {
    Write-Host "No environment.d or environment.windows.d directory found at $envDir"
}
