param(
  [Parameter(Mandatory = $true)][string]$Provisioner,
  [Parameter(Mandatory = $true)][string]$Daemon,
  [Parameter(Mandatory = $true)][string]$ClientModule
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw "test-mxm4-haptic-provision: $Message" }
}

function Invoke-Native([string]$Stage, [scriptblock]$Command) {
  & $Command
  if ($LASTEXITCODE -ne 0) { throw "$Stage exited with code $LASTEXITCODE" }
}

function Assert-ProvisionFailure([string]$ExpectedPattern) {
  $failed = $false
  try {
    & $Provisioner
  } catch {
    $failed = $true
    Assert ($_.Exception.Message -match $ExpectedPattern) "expected $ExpectedPattern failure, got: $($_.Exception.Message)"
  }
  Assert $failed "$ExpectedPattern boundary did not fail"
}

function Get-Digest([string]$Path) {
  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}
function Resolve-Sid([string]$Value) {
  try {
    return [Security.Principal.SecurityIdentifier]::new($Value)
  } catch {
    return [Security.Principal.NTAccount]::new($Value).Translate(
      [Security.Principal.SecurityIdentifier]
    )
  }
}
function Wait-FileWritable([string]$Path, [int]$Seconds = 15) {
  $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
  do {
    try {
      $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
      $stream.Dispose()
      return
    } catch {
      Start-Sleep -Milliseconds 100
    }
  } while ([DateTime]::UtcNow -lt $deadline)
  throw "file $Path did not become writable"
}

function Wait-TaskState($Folder, [string]$Name, [int]$State, [int]$Seconds = 15) {
  $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
  do {
    try { $task = $Folder.GetTask($Name) } catch { $task = $null }
    if ($null -ne $task -and $task.State -eq $State) { return $task }
    Start-Sleep -Milliseconds 100
  } while ([DateTime]::UtcNow -lt $deadline)
  $actual = if ($null -eq $task) { 'absent' } else { $task.State }
  throw "task $Name did not reach state $State (state $actual)"
}

$fixtureParent = if ([string]::IsNullOrWhiteSpace($env:XDG_RUNTIME_DIR)) {
  Join-Path $HOME '.cache'
} else {
  $env:XDG_RUNTIME_DIR
}
New-Item -ItemType Directory -Force -Path $fixtureParent | Out-Null
$fixture = Join-Path $fixtureParent ('mxm4-haptic-test-' + [Guid]::NewGuid().ToString('N'))
$taskName = '\mxm4-haptic-fixture-' + [Guid]::NewGuid().ToString('N')
$prebound = $null
$blocker = $null
$daemonProcess = $null
$lockedDestination = $null
$manifestPath = $null
$global:FixtureRealSchtasks = (Get-Command schtasks.exe -CommandType Application).Source
$global:FixtureBuildMode = 'copy'
$global:FixtureTaskMode = 'real'
$global:FixtureVpCount = 0
$global:FixtureCargoCount = 0
$global:FixtureDaemon = [IO.Path]::GetFullPath($Daemon)
$global:FixturePlugin = [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $ClientModule) 'omp-plugin\index.js'))
$global:FixtureSourceRoot = $null

function global:vp {
  $global:FixtureVpCount++
  switch ($global:FixtureBuildMode) {
    { $_ -in @('forbid-vp', 'forbid-all') } { throw 'vp unexpectedly invoked' }
    'build-fail' { $global:LASTEXITCODE = 41; return }
    'invalid-plugin' {
      $output = Join-Path $global:FixtureSourceRoot 'packages\mxm4-haptic\dist\omp-plugin\index.js'
      New-Item -ItemType Directory -Force -Path (Split-Path -Parent $output) | Out-Null
      [IO.File]::WriteAllText($output, '')
      $global:LASTEXITCODE = 0
      return
    }
    default {
      $output = Join-Path $global:FixtureSourceRoot 'packages\mxm4-haptic\dist\omp-plugin\index.js'
      New-Item -ItemType Directory -Force -Path (Split-Path -Parent $output) | Out-Null
      Copy-Item -LiteralPath $global:FixturePlugin -Destination $output -Force
      $global:LASTEXITCODE = 0
    }
  }
}

function global:cargo {
  $global:FixtureCargoCount++
  if ($global:FixtureBuildMode -in @('forbid-cargo', 'forbid-all')) { throw 'cargo unexpectedly invoked' }
  if ($global:FixtureBuildMode -eq 'daemon-build-fail') { $global:LASTEXITCODE = 42; return }
  $output = Join-Path $env:CARGO_TARGET_DIR 'release\mxm4-hapticd.exe'
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $output) | Out-Null
  Copy-Item -LiteralPath $global:FixtureDaemon -Destination $output -Force
  $global:LASTEXITCODE = 0
}

function global:schtasks.exe {
  $operation = if ($args.Count -gt 0) { [string]$args[0] } else { '' }
  if ($global:FixtureTaskMode -eq 'register-fail' -and $operation -eq '/Create') {
    $global:LASTEXITCODE = 51
    return
  }
  if ($global:FixtureTaskMode -eq 'start-fail' -and $operation -eq '/Run') {
    $global:LASTEXITCODE = 52
    return
  }
  if ($global:FixtureTaskMode -eq 'start-noop' -and $operation -eq '/Run') {
    $global:LASTEXITCODE = 0
    return
  }
  & $global:FixtureRealSchtasks @args
}

try {
  New-Item -ItemType Directory -Path $fixture | Out-Null
  $managedHome = Join-Path $fixture 'home'
  $sourceRoot = Join-Path $fixture 'source'
  New-Item -ItemType Directory -Path $managedHome | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $sourceRoot 'packages\mxm4-haptic') | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $sourceRoot 'crates\mxm4-haptic') | Out-Null
  $global:FixtureSourceRoot = $sourceRoot
  $env:MXM4_HAPTIC_SOURCE_ROOT = $sourceRoot
  $env:MXM4_HAPTIC_MANAGED_HOME = $managedHome
  $env:MXM4_HAPTIC_TASK_NAME = $taskName

  $pluginRoot = Join-Path $managedHome '.local\share\omp-plugins\plugins\mxm4-haptic'
  New-Item -ItemType Directory -Force -Path $pluginRoot | Out-Null
  $manifestPath = Join-Path $pluginRoot 'package.json'
  [IO.File]::WriteAllText($manifestPath, '{invalid')

  # Preserve the XML, preflight mutation, privilege, identity, and endpoint proof.
  $xmlPath = Join-Path $fixture 'task.xml'
  $managedPaths = @(
    (Join-Path $pluginRoot 'dist\index.js'),
    (Join-Path $managedHome '.local\bin\mxm4-hapticd.exe'),
    (Join-Path $managedHome '.local\state\mxm4-haptic\plugin.sha256'),
    (Join-Path $managedHome '.local\state\mxm4-haptic\daemon.sha256')
  )
  $managedBefore = $managedPaths | ForEach-Object { Test-Path -LiteralPath $_ }
  $failedXml = Join-Path $fixture 'failed-task.xml'
  $env:MXM4_HAPTIC_PREFLIGHT_XML_OUT = $failedXml
  $preflightFailed = $false
  try { & $Provisioner } catch { $preflightFailed = $true } finally { Remove-Item Env:MXM4_HAPTIC_PREFLIGHT_XML_OUT -ErrorAction SilentlyContinue }
  Assert $preflightFailed 'invalid manifest did not fail preflight'
  Assert (-not (Test-Path -LiteralPath $failedXml)) 'failed preflight emitted task XML'

  [IO.File]::WriteAllText($manifestPath, '{"name":"@h82/omp-mxm4-haptic","type":"module","omp":{"extensions":["./dist/index.js"]}}')
  $env:MXM4_HAPTIC_PREFLIGHT_XML_OUT = $xmlPath
  try { & $Provisioner } finally { Remove-Item Env:MXM4_HAPTIC_PREFLIGHT_XML_OUT -ErrorAction SilentlyContinue }
  Assert (Test-Path -LiteralPath $xmlPath -PathType Leaf) 'preflight-only provisioner did not emit task XML'
  $managedAfter = $managedPaths | ForEach-Object { Test-Path -LiteralPath $_ }
  Assert (($managedBefore -join ',') -eq ($managedAfter -join ',')) 'preflight-only path mutated managed component state'

  [xml]$taskXml = Get-Content -LiteralPath $xmlPath -Raw
  $ns = New-Object Xml.XmlNamespaceManager($taskXml.NameTable)
  $ns.AddNamespace('t', 'http://schemas.microsoft.com/windows/2004/02/mit/task')
  $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  $expected = @{
    '/t:Task/t:Triggers/t:LogonTrigger/t:UserId' = $sid
    '/t:Task/t:Principals/t:Principal/t:UserId' = $sid
    '/t:Task/t:Principals/t:Principal/t:LogonType' = 'InteractiveToken'
    '/t:Task/t:Principals/t:Principal/t:RunLevel' = 'LeastPrivilege'
    '/t:Task/t:Settings/t:MultipleInstancesPolicy' = 'IgnoreNew'
    '/t:Task/t:Settings/t:ExecutionTimeLimit' = 'PT0S'
    '/t:Task/t:Settings/t:DisallowStartIfOnBatteries' = 'false'
    '/t:Task/t:Settings/t:StopIfGoingOnBatteries' = 'false'
    '/t:Task/t:Settings/t:RestartOnFailure/t:Interval' = 'PT1M'
    '/t:Task/t:Settings/t:RestartOnFailure/t:Count' = '3'
  }
  foreach ($entry in $expected.GetEnumerator()) {
    $node = $taskXml.SelectSingleNode($entry.Key, $ns)
    Assert ($null -ne $node -and $node.InnerText -eq $entry.Value) "task XML mismatch at $($entry.Key)"
  }
  Assert ($null -eq $taskXml.SelectSingleNode('//t:BootTrigger', $ns)) 'task XML contains a boot trigger'
  Assert ($null -eq $taskXml.SelectSingleNode('//t:Password', $ns)) 'task XML contains stored credentials'
  Assert ($taskXml.OuterXml -notmatch 'HighestAvailable|SYSTEM') 'task XML requests elevation or SYSTEM'
  Assert ([IO.Path]::IsPathFullyQualified($taskXml.SelectSingleNode('/t:Task/t:Actions/t:Exec/t:Command', $ns).InnerText)) 'task action is not absolute'

  # Invoke the rendered production provisioner through its complete transaction.
  & $Provisioner
  $pluginDestination = $managedPaths[0]
  $daemonDestination = $managedPaths[1]
  $pluginStamp = $managedPaths[2]
  $daemonStamp = $managedPaths[3]
  Assert ((Get-Digest $pluginDestination) -eq (Get-Digest $global:FixturePlugin)) 'installed plugin bytes differ from validated build output'
  Assert ((Get-Digest $daemonDestination) -eq (Get-Digest $Daemon)) 'installed daemon bytes differ from validated release output'
  Assert ((Get-Content -LiteralPath $pluginStamp -Raw).Trim() -match '^[0-9a-f]{64}$') 'plugin stamp is not a component digest'
  Assert ((Get-Content -LiteralPath $daemonStamp -Raw).Trim() -match '^[0-9a-f]{64}$') 'daemon stamp is not a component digest'

  $scheduler = New-Object -ComObject 'Schedule.Service'
  $scheduler.Connect()
  $taskFolder = $scheduler.GetFolder('\')
  $registered = Wait-TaskState $taskFolder $taskName 4
  Assert $registered.Enabled 'registered task is disabled'
  Assert ((Resolve-Sid $registered.Definition.Principal.UserId).Value -eq $sid) 'registered task belongs to a different identity'
  Assert ([IO.Path]::GetFullPath($registered.Definition.Actions.Item(1).Path) -eq [IO.Path]::GetFullPath($daemonDestination)) 'registered task endpoint drifted'
  $pipe = [IO.Pipes.NamedPipeClientStream]::new('.', 'mxm4-haptic', [IO.Pipes.PipeDirection]::Out)
  try { $pipe.Connect(15000) } finally { $pipe.Dispose() }
  Assert ((Wait-TaskState $taskFolder $taskName 4).State -eq 4) 'task stopped after first fixed-pipe acceptance'

  # Identical convergence must reconcile live state without invoking either build.
  $vpAfterFirst = $global:FixtureVpCount
  $cargoAfterFirst = $global:FixtureCargoCount
  $componentSnapshot = $managedPaths | ForEach-Object { "$(Get-Digest $_):$((Get-Item -LiteralPath $_).LastWriteTimeUtc.Ticks)" }
  $global:FixtureBuildMode = 'forbid-all'
  & $Provisioner
  Assert ($global:FixtureVpCount -eq $vpAfterFirst) 'unchanged convergence rebuilt the plugin'
  Assert ($global:FixtureCargoCount -eq $cargoAfterFirst) 'unchanged convergence rebuilt the daemon'
  Assert (($componentSnapshot -join ',') -eq (($managedPaths | ForEach-Object { "$(Get-Digest $_):$((Get-Item -LiteralPath $_).LastWriteTimeUtc.Ticks)" }) -join ',')) 'unchanged convergence replaced an artifact or stamp'
  Assert ((Wait-TaskState $taskFolder $taskName 4).State -eq 4) 'unchanged convergence did not preserve Running state'

  # Repair stopped and incorrectly registered task drift without rebuilding.
  $global:FixtureBuildMode = 'forbid-all'
  & $global:FixtureRealSchtasks /End /TN $taskName 2>$null | Out-Null
  & $Provisioner
  Assert ((Wait-TaskState $taskFolder $taskName 4).State -eq 4) 'stopped task was not restarted'
  & $global:FixtureRealSchtasks /End /TN $taskName 2>$null | Out-Null
  $driftXml = [xml]$taskXml.OuterXml
  $driftXml.SelectSingleNode('/t:Task/t:Actions/t:Exec/t:Command', $ns).InnerText = (Get-Command powershell.exe -CommandType Application).Source
  $driftPath = Join-Path $fixture 'drift-task.xml'
  $driftXml.Save($driftPath)
  Invoke-Native 'install task drift' { & $global:FixtureRealSchtasks /Create /TN $taskName /XML $driftPath /F }
  & $Provisioner
  $registered = Wait-TaskState $taskFolder $taskName 4
  Assert ([IO.Path]::GetFullPath($registered.Definition.Actions.Item(1).Path) -eq [IO.Path]::GetFullPath($daemonDestination)) 'incorrect task endpoint was not repaired'

  # Selective component drift rebuilds only the missing component.
  $global:FixtureBuildMode = 'forbid-cargo'
  $daemonSnapshot = "$(Get-Digest $daemonDestination):$((Get-Content -LiteralPath $daemonStamp -Raw).Trim())"
  Remove-Item -LiteralPath $pluginDestination -Force
  & $Provisioner
  Assert ((Get-Digest $pluginDestination) -eq (Get-Digest $global:FixturePlugin)) 'plugin-only drift did not restore exact bytes'
  Assert ($daemonSnapshot -eq "$(Get-Digest $daemonDestination):$((Get-Content -LiteralPath $daemonStamp -Raw).Trim())") 'plugin-only drift changed daemon state'

  $global:FixtureBuildMode = 'forbid-vp'
  $pluginSnapshot = "$(Get-Digest $pluginDestination):$((Get-Content -LiteralPath $pluginStamp -Raw).Trim())"
  Invoke-Native 'stop before daemon drift' { & $global:FixtureRealSchtasks /End /TN $taskName }
  Wait-TaskState $taskFolder $taskName 3 | Out-Null
  Wait-FileWritable $daemonDestination
  Remove-Item -LiteralPath $daemonDestination -Force
  & $Provisioner
  Assert ((Get-Digest $daemonDestination) -eq (Get-Digest $Daemon)) 'daemon-only drift did not restore exact bytes'
  Assert ($pluginSnapshot -eq "$(Get-Digest $pluginDestination):$((Get-Content -LiteralPath $pluginStamp -Raw).Trim())") 'daemon-only drift changed plugin state'

  # Fatal build and validation boundaries happen before manager mutation.
  $taskEndpoint = [IO.Path]::GetFullPath($taskFolder.GetTask($taskName).Definition.Actions.Item(1).Path)
  $savedPluginStamp = Get-Content -LiteralPath $pluginStamp -Raw
  [IO.File]::WriteAllText($pluginStamp, "force-plugin-build`n")
  $global:FixtureBuildMode = 'build-fail'
  Assert-ProvisionFailure 'plugin-build'
  Assert ([IO.Path]::GetFullPath($taskFolder.GetTask($taskName).Definition.Actions.Item(1).Path) -eq $taskEndpoint) 'build failure mutated task registration'
  $global:FixtureBuildMode = 'invalid-plugin'
  Assert-ProvisionFailure 'plugin-validate'
  Assert ([IO.Path]::GetFullPath($taskFolder.GetTask($taskName).Definition.Actions.Item(1).Path) -eq $taskEndpoint) 'validation failure mutated task registration'
  [IO.File]::WriteAllText($pluginStamp, $savedPluginStamp)

  # Atomic replacement failure preserves the previously installed bytes.
  $priorPluginDigest = Get-Digest $pluginDestination
  [IO.File]::WriteAllText($pluginStamp, "force-atomic-replacement`n")
  $lockedDestination = [IO.File]::Open($pluginDestination, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
  $global:FixtureBuildMode = 'copy'
  Assert-ProvisionFailure 'Move-Item|being used|access|already exists'
  $lockedDestination.Dispose()
  $lockedDestination = $null
  Assert ((Get-Digest $pluginDestination) -eq $priorPluginDigest) 'atomic replacement failure changed prior plugin bytes'
  [IO.File]::WriteAllText($pluginStamp, $savedPluginStamp)

  # Task registration, start, state, and readiness boundaries are all fatal.
  Invoke-Native 'restore task drift' { & $global:FixtureRealSchtasks /Create /TN $taskName /XML $driftPath /F }
  $global:FixtureTaskMode = 'register-fail'
  Assert-ProvisionFailure 'task-register'
  $global:FixtureTaskMode = 'real'
  & $Provisioner

  Invoke-Native 'stop before start failure' { & $global:FixtureRealSchtasks /End /TN $taskName }
  Wait-TaskState $taskFolder $taskName 3 | Out-Null
  $global:FixtureTaskMode = 'start-fail'
  Assert-ProvisionFailure 'task-start'
  $global:FixtureTaskMode = 'start-noop'
  Assert-ProvisionFailure 'task-state'
  $global:FixtureTaskMode = 'real'
  & $Provisioner

  $blocker = [IO.Pipes.NamedPipeClientStream]::new('.', 'mxm4-haptic', [IO.Pipes.PipeDirection]::Out)
  $blocker.Connect(15000)
  Assert-ProvisionFailure 'readiness'
  $blocker.Dispose()
  $blocker = $null

  # Exercise disposable current-user XML update semantics independently.
  Invoke-Native 'stop production task' { & $global:FixtureRealSchtasks /End /TN $taskName }
  $taskXml.SelectSingleNode('/t:Task/t:RegistrationInfo/t:URI', $ns).InnerText = $taskName
  $taskXml.SelectSingleNode('/t:Task/t:Actions/t:Exec/t:Command', $ns).InnerText = (Get-Command powershell.exe -CommandType Application).Source
  $exec = $taskXml.SelectSingleNode('/t:Task/t:Actions/t:Exec', $ns)
  $arguments = $taskXml.CreateElement('Arguments', $taskXml.DocumentElement.NamespaceURI)
  $arguments.InnerText = '-NoProfile -NonInteractive -Command "Start-Sleep -Seconds 20"'
  [void]$exec.AppendChild($arguments)
  $fixtureXml = Join-Path $fixture 'fixture-task.xml'
  $taskXml.Save($fixtureXml)
  Invoke-Native 'task create' { & $global:FixtureRealSchtasks /Create /TN $taskName /XML $fixtureXml /F }
  Invoke-Native 'task query' { & $global:FixtureRealSchtasks /Query /TN $taskName /XML 1>$null }
  Invoke-Native 'task update' { & $global:FixtureRealSchtasks /Create /TN $taskName /XML $fixtureXml /F }
  Invoke-Native 'task start' { & $global:FixtureRealSchtasks /Run /TN $taskName }
  Assert ((Wait-TaskState $taskFolder $taskName 4 10).State -eq 4) 'fixture task did not reach Running'

  Invoke-Native 'stop fixture task' { & $global:FixtureRealSchtasks /End /TN $taskName }
  Wait-TaskState $taskFolder $taskName 3 | Out-Null

  # A foreign first instance must reject a second machine-global pipe owner.
  $prebound = [IO.Pipes.NamedPipeServerStream]::new('mxm4-haptic', [IO.Pipes.PipeDirection]::In, 1)
  $collision = Start-Process -FilePath $Daemon -PassThru -WindowStyle Hidden
  Assert ($collision.WaitForExit(5000)) 'daemon did not fail promptly against a prebound pipe'
  Assert ($collision.ExitCode -ne 0) 'daemon accepted a foreign prebound pipe collision'
  $prebound.Dispose()
  $prebound = $null

  # The real daemon and built TypeScript client retain transport coverage.
  $daemonProcess = Start-Process -FilePath $Daemon -PassThru -WindowStyle Hidden
  $clientScript = Join-Path $fixture 'client.mjs'
  $moduleUri = ([Uri]::new([IO.Path]::GetFullPath($ClientModule))).AbsoluteUri
  [IO.File]::WriteAllText($clientScript, "import { sendCommand } from '$moduleUri'; await sendCommand('LONG PRESS');`n")
  $sent = $false
  $deadline = [DateTime]::UtcNow.AddSeconds(15)
  do {
    & node $clientScript 2>$null
    if ($LASTEXITCODE -eq 0) { $sent = $true; break }
    Start-Sleep -Milliseconds 200
  } while ([DateTime]::UtcNow -lt $deadline)
  Assert $sent 'TypeScript client could not write to the owned fixed pipe'
  Assert (-not $daemonProcess.HasExited) 'daemon exited after the transport round trip'

  try {
    $acl = Get-Acl -LiteralPath '\\.\pipe\mxm4-haptic'
    $sddl = $acl.Sddl
    Assert ($sddl -match [regex]::Escape($sid)) 'pipe DACL omits current-user SID'
    Assert ($sddl -notmatch ';;;WD\)|;;;AU\)|;;;BU\)|;;;BA\)') 'pipe DACL grants another-user group write access'
  } catch [System.Management.Automation.ItemNotFoundException] {
    Write-Host 'named-pipe ACL provider unavailable; different-user DACL assertion not testable on this runner'
  } catch [System.NotSupportedException] {
    Write-Host 'named-pipe ACL provider unavailable; different-user DACL assertion not testable on this runner'
  }

  Write-Host 'Windows haptic full transaction, convergence, drift, failure, task, collision, ACL, and transport fixture passed'
} finally {
  $global:FixtureTaskMode = 'real'
  if ($lockedDestination) { $lockedDestination.Dispose() }
  if ($blocker) { $blocker.Dispose() }
  if ($daemonProcess -and -not $daemonProcess.HasExited) { Stop-Process -Id $daemonProcess.Id -Force -ErrorAction SilentlyContinue }
  if ($prebound) { $prebound.Dispose() }
  & $global:FixtureRealSchtasks /End /TN $taskName 2>$null | Out-Null
  & $global:FixtureRealSchtasks /Delete /TN $taskName /F 2>$null | Out-Null
  Remove-Item Function:global:vp -ErrorAction SilentlyContinue
  Remove-Item Function:global:cargo -ErrorAction SilentlyContinue
  Remove-Item Function:global:schtasks.exe -ErrorAction SilentlyContinue
  foreach ($name in @('MXM4_HAPTIC_SOURCE_ROOT', 'MXM4_HAPTIC_MANAGED_HOME', 'MXM4_HAPTIC_TASK_NAME', 'MXM4_HAPTIC_PREFLIGHT_XML_OUT')) {
    Remove-Item "Env:$name" -ErrorAction SilentlyContinue
  }
  Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
}
