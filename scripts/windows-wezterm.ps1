#requires -Version 5.1
param(
    [string] $ClassesRoot = 'Software\Classes',
    [string] $WezTermPath
)
$ErrorActionPreference = 'Stop'

if (-not $WezTermPath) {
    $command = Get-Command wezterm-gui.exe -CommandType Application -ErrorAction SilentlyContinue
    if ($command) { $WezTermPath = $command.Source }
    if (-not $WezTermPath) {
        # The installer updates PATH, but the applying process may still have the old PATH.
        foreach ($base in @($env:ProgramW6432, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA)) {
            if (-not $base) { continue }
            $candidate = Join-Path $base 'WezTerm\wezterm-gui.exe'
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                $WezTermPath = $candidate
                break
            }
        }
    }
}
if (-not $WezTermPath -or -not (Test-Path -LiteralPath $WezTermPath -PathType Leaf)) {
    throw 'WezTerm is unavailable. Install wez.wezterm with WinGet, then rerun chezmoi apply.'
}
$WezTermPath = (Resolve-Path -LiteralPath $WezTermPath).ProviderPath

foreach ($entry in @(
    @{ Path = 'Directory\shell'; Directory = '%1' },
    @{ Path = 'Directory\Background\shell'; Directory = '%V' }
)) {
    $verbPath = '{0}\{1}\Open WezTerm here' -f $ClassesRoot, $entry.Path
    $verb = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($verbPath)
    try {
        $verb.SetValue('', 'Open WezTerm Here', [Microsoft.Win32.RegistryValueKind]::String)
        $verb.SetValue('Icon', ('"{0}"' -f $WezTermPath), [Microsoft.Win32.RegistryValueKind]::String)
        $commandKey = $verb.CreateSubKey('command')
        try {
            # A final dot keeps a drive-root backslash from escaping the closing quote.
            $launch = '"{0}" start --no-auto-connect --cwd "{1}\."' -f $WezTermPath, $entry.Directory
            $commandKey.SetValue('', $launch, [Microsoft.Win32.RegistryValueKind]::String)
        } finally { $commandKey.Dispose() }
    } finally { $verb.Dispose() }
}
