param(
  [Parameter(Mandatory = $true)][string]$Reconciler,
  [Parameter(Mandatory = $true)][string]$HapticPackage
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw "test-omp-agent-reconcile: $Message" }
}

$root = if ([string]::IsNullOrWhiteSpace($env:XDG_RUNTIME_DIR)) {
  Join-Path $HOME '.cache'
} else {
  $env:XDG_RUNTIME_DIR
}
New-Item -ItemType Directory -Force -Path $root | Out-Null
$scratch = Join-Path $root ('omp-agent-reconcile-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch | Out-Null
$oldPath = $env:PATH
$oldHome = $env:HOME
$oldProfile = $env:USERPROFILE

try {
  $managedHome = Join-Path $scratch 'home'
  $fakeBin = Join-Path $scratch 'bin'
  $source = Join-Path $managedHome '.local\share\omp-plugins'
  $ceSource = Join-Path $managedHome '.local\share\compound-engineering\v-test'
  New-Item -ItemType Directory -Force -Path (Join-Path $source '.omp-plugin'), (Join-Path $source 'plugins'), (Join-Path $ceSource '.claude-plugin'), $fakeBin | Out-Null
  Copy-Item -LiteralPath $HapticPackage -Destination (Join-Path $source 'plugins\mxm4-haptic') -Recurse
  [IO.File]::WriteAllText((Join-Path $source '.omp-plugin\marketplace.json'), '{"name":"h82-dotfiles","owner":{"name":"test"},"plugins":[{"name":"mxm4-haptic","source":"./plugins/mxm4-haptic"}]}')
  [IO.File]::WriteAllText((Join-Path $ceSource '.claude-plugin\marketplace.json'), '{"name":"compound-engineering-plugin"}')

  $rendered = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $Reconciler))
  $versionMatch = [regex]::Match($rendered, '(?m)^\$expectedOmpVersion = ''([^'']+)''$')
  Assert $versionMatch.Success 'rendered reconciler has no expected OMP version'
  $env:EXPECTED_OMP_VERSION = $versionMatch.Groups[1].Value
  $hapticMatch = [regex]::Match($rendered, "Name = 'mxm4-haptic'; Market = 'h82-dotfiles'; Kind = 'localDir'; Source = '([^']+)'" )
  $ceMatch = [regex]::Match($rendered, "Name = 'compound-engineering'; Market = 'compound-engineering-plugin'; Kind = 'localArchive'; Source = '([^']+)'" )
  Assert ($hapticMatch.Success -and $ceMatch.Success) 'rendered reconciler is missing canonical plugin rows'
  $rendered = $rendered.Replace($hapticMatch.Groups[1].Value, $source).Replace($ceMatch.Groups[1].Value, $ceSource)
  $testReconciler = Join-Path $scratch 'plugins.ps1'
  [IO.File]::WriteAllText($testReconciler, $rendered, [Text.UTF8Encoding]::new($false))

  $stub = @'
$ErrorActionPreference = 'Stop'
$argsText = $args -join ' '
Add-Content -LiteralPath $env:OMP_CALLS -Value $argsText
if ($args.Count -eq 1 -and $args[0] -eq '--version') { Write-Output $env:EXPECTED_OMP_VERSION; exit 0 }
if ($env:OMP_FAIL_MATCH -and $argsText.Contains($env:OMP_FAIL_MATCH)) { exit 72 }
$pluginRoot = Join-Path $HOME '.omp\plugins'
New-Item -ItemType Directory -Force -Path $pluginRoot | Out-Null
if ($args.Count -eq 4 -and $args[0] -eq 'plugin' -and $args[1] -eq 'marketplace' -and $args[2] -eq 'add') {
  $manifest = Join-Path $args[3] '.omp-plugin\marketplace.json'
  if (Test-Path -LiteralPath $manifest) { [IO.File]::WriteAllText((Join-Path $HOME '.haptic-source'), $args[3]) }
}
if ($argsText -eq 'plugin install --scope user --force mxm4-haptic@h82-dotfiles') {
  $marketplace = [IO.File]::ReadAllText((Join-Path $HOME '.haptic-source'))
  $install = Join-Path $pluginRoot 'cache\plugins\h82-dotfiles___mxm4-haptic___0.0.0'
  Remove-Item -LiteralPath $install -Recurse -Force -ErrorAction SilentlyContinue
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $install) | Out-Null
  Copy-Item -LiteralPath (Join-Path $marketplace 'plugins\mxm4-haptic') -Destination $install -Recurse
  if ($env:OMP_TAMPER_PAYLOAD) { Add-Content -LiteralPath (Join-Path $install 'dist\index.js') -Value '// tampered after install' }
  $linkParent = Join-Path $pluginRoot 'node_modules\@h82'
  $link = Join-Path $linkParent 'omp-mxm4-haptic'
  New-Item -ItemType Directory -Force -Path $linkParent | Out-Null
  Remove-Item -LiteralPath $link -Recurse -Force -ErrorAction SilentlyContinue
  New-Item -ItemType Junction -Path $link -Target $install | Out-Null
  $state = @{ version = 2; plugins = @{ 'mxm4-haptic@h82-dotfiles' = @(@{ scope = 'user'; installPath = $install; version = '0.0.0' }) } }
  [IO.File]::WriteAllText((Join-Path $pluginRoot 'installed_plugins.json'), ($state | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
}
if ($argsText -eq 'plugin enable --scope user mxm4-haptic@h82-dotfiles') {
  $lock = @{ plugins = @{ '@h82/omp-mxm4-haptic' = @{ version = '0.0.0'; enabled = $true } }; settings = @{} }
  [IO.File]::WriteAllText((Join-Path $pluginRoot 'omp-plugins.lock.json'), ($lock | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
}
exit 0
'@
  $stubPath = Join-Path $fakeBin 'omp-stub.ps1'
  [IO.File]::WriteAllText($stubPath, $stub, [Text.UTF8Encoding]::new($false))
  $cmd = "@`"$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe`" -NoProfile -ExecutionPolicy Bypass -File `"%~dp0omp-stub.ps1`" %*`r`n"
  [IO.File]::WriteAllText((Join-Path $fakeBin 'omp.cmd'), $cmd, [Text.ASCIIEncoding]::new())

  # The child PowerShell must derive its automatic $HOME from this relocated profile.
  $env:PATH = "$fakeBin;$oldPath"
  $env:HOME = $managedHome
  $env:USERPROFILE = $managedHome
  $hostExe = (Get-Process -Id $PID).Path
  $legacy = Join-Path $managedHome '.omp\agent\extensions\mxm4-haptic.ts'
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $legacy) | Out-Null

  function Invoke-Reconciler([string]$Label, [string]$FailMatch = '', [bool]$Tamper = $false) {
    $env:OMP_CALLS = Join-Path $scratch "$Label.calls"
    $env:OMP_FAIL_MATCH = $FailMatch
    $env:OMP_TAMPER_PAYLOAD = if ($Tamper) { '1' } else { '' }
    $output = Join-Path $scratch "$Label.out"
    & $hostExe -NoProfile -File $testReconciler *> $output
    return $LASTEXITCODE
  }

  [IO.File]::WriteAllText($legacy, 'legacy owner')
  Assert ((Invoke-Reconciler 'enable-failure' 'plugin enable --scope user mxm4-haptic@h82-dotfiles') -ne 0) 'injected enable failure unexpectedly succeeded'
  Assert (Test-Path -LiteralPath $legacy -PathType Leaf) 'enable failure removed the legacy owner'

  Assert ((Invoke-Reconciler 'digest-failure' '' $true) -ne 0) 'tampered installed payload passed digest proof'
  Assert (Test-Path -LiteralPath $legacy -PathType Leaf) 'digest failure removed the legacy owner'

  $entry = Join-Path $source 'plugins\mxm4-haptic\dist\index.js'
  $entryBytes = [IO.File]::ReadAllBytes($entry)
  [IO.File]::WriteAllText($entry, 'export default function (api) { api.on("unexpected", () => {}); }')
  try {
    Assert ((Invoke-Reconciler 'loader-failure') -ne 0) 'invalid handler ownership passed loader proof'
    Assert (Test-Path -LiteralPath $legacy -PathType Leaf) 'loader failure removed the legacy owner'
  } finally {
    [IO.File]::WriteAllBytes($entry, $entryBytes)
  }

  Assert ((Invoke-Reconciler 'success') -eq 0) 'strict reconciliation failed'
  Assert (-not (Test-Path -LiteralPath $legacy)) 'successful final proof retained the legacy owner'
  Assert ((Invoke-Reconciler 'retry') -eq 0) 'repeat reconciliation failed'
  Assert (-not (Test-Path -LiteralPath $legacy)) 'repeat reconciliation recreated the legacy owner'
  $retryCalls = Get-Content -LiteralPath (Join-Path $scratch 'retry.calls')
  Assert (($retryCalls | Where-Object { $_ -eq 'plugin install --scope user --force mxm4-haptic@h82-dotfiles' }).Count -eq 1) 'retry did not force exactly one haptic install'
  Assert (($retryCalls | Where-Object { $_ -eq 'plugin enable --scope user mxm4-haptic@h82-dotfiles' }).Count -eq 1) 'retry did not enable exactly one haptic plugin'

  $installed = Get-Content -LiteralPath (Join-Path $managedHome '.omp\plugins\installed_plugins.json') -Raw | ConvertFrom-Json
  Assert ($installed.plugins.'mxm4-haptic@h82-dotfiles'.Count -eq 1) 'installed state is not canonical and singular'
  Assert ($installed.plugins.'mxm4-haptic@h82-dotfiles'[0].scope -eq 'user') 'installed state is not user scoped'
  $lock = Get-Content -LiteralPath (Join-Path $managedHome '.omp\plugins\omp-plugins.lock.json') -Raw | ConvertFrom-Json
  Assert ($lock.plugins.'@h82/omp-mxm4-haptic'.enabled -eq $true) 'enabled state is absent'
  $installRoot = $installed.plugins.'mxm4-haptic@h82-dotfiles'[0].installPath
  Assert ((Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $installRoot 'package.json')).Hash -eq (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $source 'plugins\mxm4-haptic\package.json')).Hash) 'installed package manifest differs from staged payload'
  Assert ((Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $installRoot 'dist\index.js')).Hash -eq (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $source 'plugins\mxm4-haptic\dist\index.js')).Hash) 'installed extension differs from staged payload'

  Write-Host 'PowerShell OMP reconciliation strict, failure, digest, loader, legacy, and retry fixture passed'
} finally {
  $env:PATH = $oldPath
  $env:HOME = $oldHome
  $env:USERPROFILE = $oldProfile
  Remove-Item Env:OMP_CALLS, Env:OMP_FAIL_MATCH, Env:OMP_TAMPER_PAYLOAD, Env:EXPECTED_OMP_VERSION -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}
