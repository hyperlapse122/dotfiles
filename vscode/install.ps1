$ExtensionsPath = "$(Split-Path -Parent $MyInvocation.MyCommand.Path)\extensions.txt";

if (Test-Path $ExtensionsPath) {
    Get-Content $ExtensionsPath | ForEach-Object { code --install-extension $_ }
} else {
    Write-Host "No extensions file found at $ExtensionsPath"
}
