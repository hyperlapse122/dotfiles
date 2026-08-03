#Requires -Version 5.1
<#
.SYNOPSIS
    test-wifi-import-windows.ps1 — hermetic runtime fixture for
    import-wifi-1password.ps1.

.DESCRIPTION
    Renders the tool with fixture 1Password values, injects typed CIM-style
    adapter records (including localized aliases), then drives it against a
    FAKE netsh (.ci/fixtures/wifi-secret-handoff/netsh.cmd, shadowing the real
    netsh via PATH) proving deployed-mode behavior, transient-profile cleanup
    on every exit path (success / command failure / Ctrl+C-style cancellation
    via runspace Stop), and zero secret leakage into argv, logs, or residue.
    Never queries live adapters or touches live Wi-Fi.

    Requires Windows + pwsh + chezmoi on PATH (mirrors the Windows CI jobs).
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Fail([string]$Message) {
  [Console]::Error.WriteLine("wifi-import windows fixture: $Message")
  exit 1
}

if ($env:OS -ne 'Windows_NT') {
  Write-Output 'wifi-import windows fixture: skipped on non-Windows host'
  exit 0
}
if (-not (Get-Command 'chezmoi' -ErrorAction SilentlyContinue)) { Fail 'chezmoi not found on PATH' }

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Fixtures = Join-Path $RepoRoot '.ci/fixtures/wifi-secret-handoff'
$PwshExe = (Get-Process -Id $PID).Path

$Scratch = Join-Path ([IO.Path]::GetTempPath()) ('wifi-import-win-test-{0}' -f [Guid]::NewGuid().ToString('N').Substring(0, 12))
New-Item -ItemType Directory -Path $Scratch | Out-Null
New-Item -ItemType Directory -Path (Join-Path $Scratch 'home') | Out-Null
New-Item -ItemType Directory -Path (Join-Path $Scratch 'bin') | Out-Null

try {
  # chezmoi config + op stub (deterministic per-item fixture values; see
  # test-wifi-import-gates.sh). onepasswordRead invokes `op read "<ref>"`.
  $emptyConfig = Join-Path $Scratch 'empty.toml'
  [IO.File]::WriteAllText($emptyConfig, "[data]`n")
  $opStub = Join-Path $Scratch 'bin/op.cmd'
  [IO.File]::WriteAllText($opStub, @'
@echo off
set "args= %* "
echo %args%| findstr /C:"KT HomeHub 5G/name" >nul && (<nul set /p=fixture-ssid-home& exit /b 0)
echo %args%| findstr /C:"KT HomeHub 5G/password" >nul && (<nul set /p=fixture-psk-home& exit /b 0)
echo %args%| findstr /C:"CPS-01/name" >nul && (<nul set /p=fixture-ssid-cps& exit /b 0)
echo %args%| findstr /C:"CPS-01/password" >nul && (<nul set /p=fixture-psk-cps& exit /b 0)
<nul set /p=fixture-dummy
exit /b 0
'@)

  # Render the deployed-mode tool (os=windows) with fixture secrets resolved.
  $Tool = Join-Path $Scratch 'import-wifi-1password.ps1'
  $renderBin = Join-Path $Scratch 'bin'
  $tmpl = Join-Path $RepoRoot 'dot_local/bin/private_executable_import-wifi-1password.ps1.tmpl'
  $savedRenderPath = $env:PATH
  $savedRenderHome = $env:HOME
  $env:PATH = "$renderBin;$env:PATH"
  $env:HOME = Join-Path $Scratch 'home'
  try {
    Get-Content -LiteralPath $tmpl -Raw |
      chezmoi --config $emptyConfig --source $RepoRoot `
        --destination (Join-Path $Scratch 'target') `
        --override-data '{"chezmoi":{"os":"windows"}}' execute-template |
      Set-Content -LiteralPath $Tool -Encoding utf8
  } finally {
    $env:PATH = $savedRenderPath
    $env:HOME = $savedRenderHome
  }
  if ($LASTEXITCODE -ne 0) { Fail "chezmoi render exited $LASTEXITCODE" }

  # Resolution proof: the rendered owner-only artifact embeds the fixture
  # values (render-time resolution design; the artifact itself is private_).
  $rendered = Get-Content -LiteralPath $Tool -Raw
  if ($rendered -notmatch [regex]::Escape('fixture-psk-home')) { Fail 'render did not resolve op:// password refs' }
  if ($rendered -notmatch [regex]::Escape('fixture-ssid-home')) { Fail 'render did not resolve op:// ssid refs' }

  # The production manifest currently declares no Windows priority. Add
  # fixture-only ranks to the rendered copy so typed, localized interface
  # discovery and profile-order calls stay covered without changing user data.
  $rendered = [regex]::Replace(
    $rendered,
    '("ssid"\s*:\s*"fixture-ssid-home"\s*,)',
    '$1' + "`n      `"priority`": 10,"
  )
  $rendered = [regex]::Replace(
    $rendered,
    '("ssid"\s*:\s*"fixture-ssid-cps"\s*,)',
    '$1' + "`n      `"priority`": 5,"
  )
  [IO.File]::WriteAllText($Tool, $rendered)

  # Fake netsh shadows the real one on PATH for every tool run below.
  Copy-Item -LiteralPath (Join-Path $Fixtures 'netsh.cmd') -Destination (Join-Path $Scratch 'bin/netsh.cmd')
  $toolBin = Join-Path $Scratch 'bin'

  # Invoke-Tool <label> <args...> : run the tool in a CHILD pwsh process with
  # an isolated TEMP, argv log, and injected typed adapter provider. The
  # localized aliases prove discovery has no dependency on netsh prose.
  function Invoke-Tool([string]$Label, [string[]]$ToolArgs) {
    $tmp = Join-Path $Scratch "tmp-$Label"
    $state = Join-Path $Scratch "state-$Label"
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    New-Item -ItemType Directory -Path $state -Force | Out-Null
    $log = Join-Path $Scratch "log-$Label"
    [IO.File]::WriteAllText($log, '')
    $out = Join-Path $Scratch "out-$Label"
    $saved = @{}
    foreach ($name in 'TMP', 'TEMP', 'TEST_LOG', 'TEST_STATE_DIR', 'WIFI_FAKE_FAIL_STAGE', 'WIFI_FAKE_NO_INTERFACE', 'WIFI_FAKE_BLOCK', 'PATH') {
      $saved[$name] = [Environment]::GetEnvironmentVariable($name)
    }
    try {
      $env:TMP = $tmp; $env:TEMP = $tmp
      $env:TEST_LOG = $log; $env:TEST_STATE_DIR = $state
      $env:PATH = "$toolBin;" + $saved['PATH']
      $provider = if ($env:WIFI_FAKE_NO_INTERFACE -eq '1') {
        '{ @() }'
      } else {
        "{ @([pscustomobject]@{ AdapterTypeID = 9; NetConnectionID = '무선랜' }, [pscustomobject]@{ AdapterTypeID = 0; NetConnectionID = '이더넷' }) }"
      }
      $escapedTool = $Tool -replace "'", "''"
      $argumentText = $ToolArgs -join ' '
      & $PwshExe -NoProfile -Command "& '$escapedTool' $argumentText -WirelessInterfaceProvider $provider" *> $out
      $script:ToolRc = $LASTEXITCODE
    } finally {
      foreach ($name in $saved.Keys) {
        [Environment]::SetEnvironmentVariable($name, $saved[$name])
      }
    }
  }

  function Count-Calls([string]$Label, [string]$Verb) {
    $content = [string](Get-Content -LiteralPath (Join-Path $Scratch "log-$Label") -Raw)
    $matches = [regex]::Matches($content, "(?m)^netsh wlan $Verb ")
    return $matches.Count
  }

  function Assert-NoLeak([string]$Label) {
    $log = Get-Content -LiteralPath (Join-Path $Scratch "log-$Label") -Raw
    if ($log -match 'fixture-psk') { Fail "${Label}: fixture PSK appeared on a netsh command line" }
    $out = Get-Content -LiteralPath (Join-Path $Scratch "out-$Label") -Raw
    if ($out -match 'fixture-psk') { Fail "${Label}: fixture PSK appeared in tool output" }
    $residue = Get-ChildItem -LiteralPath (Join-Path $Scratch "tmp-$Label") -Force
    if ($residue) { Fail "${Label}: transient residue left under scenario TEMP ($($residue.Name -join ', '))" }
  }

  # --- scenario 1: dry run (deployed mode, no changes) -------------------
  Invoke-Tool 'dry' @('-DryRun')
  if ($script:ToolRc -ne 0) { Fail "dry-run exit $($script:ToolRc), expected 0: $(Get-Content "$Scratch/out-dry" -Raw)" }
  if ((Count-Calls 'dry' 'add') -ne 0) { Fail 'dry-run must not add profiles' }
  if ((Count-Calls 'dry' 'delete') -ne 0) { Fail 'dry-run must not delete profiles' }
  if (-not (Select-String -LiteralPath "$Scratch/out-dry" -SimpleMatch 'would add/update "fixture-ssid-home"' -Quiet)) {
    Fail "dry-run must plan the KT HomeHub network: $(Get-Content "$Scratch/out-dry" -Raw)"
  }
  if (-not (Select-String -LiteralPath "$Scratch/out-dry" -SimpleMatch 'cannot carry DNS' -Quiet)) {
    Fail 'dry-run must warn that manifest DNS is ignored on Windows'
  }
  Assert-NoLeak 'dry'

  # --- scenario 2: real run (deployed mode) -------------------------------
  Invoke-Tool 'real' @()
  if ($script:ToolRc -ne 0) { Fail "real run exit $($script:ToolRc), expected 0: $(Get-Content "$Scratch/out-real" -Raw)" }
  if ((Count-Calls 'real' 'add') -ne 2) { Fail 'real run must add both profiles' }
  if ((Count-Calls 'real' 'delete') -ne 0) { Fail 'real run must not delete (overwrite is in place)' }
  if (-not (Select-String -LiteralPath "$Scratch/out-real" -SimpleMatch 'added/updated "fixture-ssid-cps"' -Quiet)) {
    Fail 'real run must report both imports'
  }
  Assert-NoLeak 'real'
  if ((Count-Calls 'real' 'set') -ne 2) {
    Fail "localized typed wireless interface discovery must apply both profile priorities: $(Get-Content "$Scratch/log-real" -Raw)"
  }

  # --- scenario 3: --force deletes before adding ---------------------------
  Invoke-Tool 'force' @('-Force')
  if ($script:ToolRc -ne 0) { Fail "force run exit $($script:ToolRc), expected 0: $(Get-Content "$Scratch/out-force" -Raw)" }
  if ((Count-Calls 'force' 'delete') -ne 2) { Fail 'force run must delete both profiles first' }
  if ((Count-Calls 'force' 'add') -ne 2) { Fail 'force run must add both profiles' }
  Assert-NoLeak 'force'

  # --- scenario 4: command failure — nonzero exit, cleanup still happens ---
  $env:WIFI_FAKE_FAIL_STAGE = 'add'
  try { Invoke-Tool 'fail2' @() } finally { Remove-Item Env:WIFI_FAKE_FAIL_STAGE }
  if ($script:ToolRc -ne 1) { Fail "failing run exit $($script:ToolRc), expected 1" }
  if ((Count-Calls 'fail2' 'add') -ne 2) { Fail 'failing run must attempt both adds' }
  if (-not (Select-String -LiteralPath "$Scratch/out-fail2" -SimpleMatch 'failed to add' -Quiet)) {
    Fail 'failing run must report the failures'
  }
  Assert-NoLeak 'fail2'

  # --- scenario 5: no wireless interface — environment bail -----------------
  $env:WIFI_FAKE_NO_INTERFACE = '1'
  try { Invoke-Tool 'noiface' @() } finally { Remove-Item Env:WIFI_FAKE_NO_INTERFACE }
  if ($script:ToolRc -ne 1) { Fail "no-interface run exit $($script:ToolRc), expected 1" }
  if (-not (Select-String -LiteralPath "$Scratch/out-noiface" -SimpleMatch 'no wireless interface' -Quiet)) {
    Fail 'no-interface run must explain the environment bail'
  }
  $env:WIFI_FAKE_NO_INTERFACE = '1'
  try { Invoke-Tool 'noifaceapply' @('-FromApply') } finally { Remove-Item Env:WIFI_FAKE_NO_INTERFACE }
  if ($script:ToolRc -ne 0) { Fail "no-interface -FromApply exit $($script:ToolRc), expected 0 (clean skip)" }

  # --- scenario 6: cancellation — runspace Stop during a blocked add --------
  # The fake netsh parks on `add`; Stop() unwinds the pipeline
  # (PipelineStoppedException) through the tool's single finally path.
  $cancelTmp = Join-Path $Scratch 'tmp-cancel'
  $cancelState = Join-Path $Scratch 'state-cancel'
  New-Item -ItemType Directory -Path $cancelTmp -Force | Out-Null
  New-Item -ItemType Directory -Path $cancelState -Force | Out-Null
  [IO.File]::WriteAllText((Join-Path $Scratch 'log-cancel'), '')
  $savedCancel = @{}
  foreach ($name in 'TMP', 'TEMP', 'TEST_LOG', 'TEST_STATE_DIR', 'WIFI_FAKE_BLOCK', 'PATH') {
    $savedCancel[$name] = [Environment]::GetEnvironmentVariable($name)
  }
  $env:TMP = $cancelTmp; $env:TEMP = $cancelTmp
  $env:TEST_LOG = Join-Path $Scratch 'log-cancel'
  $env:TEST_STATE_DIR = $cancelState
  $env:WIFI_FAKE_BLOCK = 'add'
  $env:PATH = "$toolBin;" + $savedCancel['PATH']
  $runspace = [runspacefactory]::CreateRunspace()
  $runspace.Open()
  $pipeline = [powershell]::Create()
  $pipeline.Runspace = $runspace
  try {
    $pipeline.AddScript("Set-Location -LiteralPath '$($RepoRoot -replace "'","''")'; & '$($Tool -replace "'","''")' -WirelessInterfaceProvider { @([pscustomobject]@{ AdapterTypeID = 9; NetConnectionID = '무선랜' }) }") | Out-Null
    $async = $pipeline.BeginInvoke()
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    while (-not (Test-Path -LiteralPath (Join-Path $cancelState 'blocked'))) {
      if ([DateTime]::UtcNow -gt $deadline) { Fail 'cancellation fixture never reached the blocking add' }
      Start-Sleep -Milliseconds 100
    }
    $pipeline.Stop()
    # The parked fake netsh may outlive the stop; release it, then wait for
    # the tool's finally to remove the transient directory.
    [IO.File]::WriteAllText((Join-Path $cancelState 'unblock'), '')
    $waitDeadline = [DateTime]::UtcNow.AddSeconds(10)
    while ((Get-ChildItem -LiteralPath $cancelTmp -Force -Filter 'wifi-import-*' -ErrorAction SilentlyContinue) `
        -and [DateTime]::UtcNow -lt $waitDeadline) {
      Start-Sleep -Milliseconds 100
    }
  } finally {
    $pipeline.Dispose()
    $runspace.Dispose()
    foreach ($name in $savedCancel.Keys) {
      [Environment]::SetEnvironmentVariable($name, $savedCancel[$name])
    }
  }
  $cancelResidue = Get-ChildItem -LiteralPath $cancelTmp -Force -ErrorAction SilentlyContinue
  if ($cancelResidue) { Fail "cancellation: transient residue left under scenario TEMP ($($cancelResidue.Name -join ', ')) — the finally path did not run" }
  if ((Get-Content -LiteralPath (Join-Path $Scratch 'log-cancel') -Raw) -match 'fixture-psk') {
    Fail 'cancellation: fixture PSK appeared on a netsh command line'
  }

  # --- global leak + residue scan across every scenario ---------------------
  $allLogs = Get-ChildItem -LiteralPath $Scratch -Filter 'log-*' | ForEach-Object { $_.FullName }
  $allOuts = Get-ChildItem -LiteralPath $Scratch -Filter 'out-*' | ForEach-Object { $_.FullName }
  foreach ($file in ($allLogs + $allOuts)) {
    if ((Get-Content -LiteralPath $file -Raw) -match 'fixture-psk') {
      Fail "fixture PSK leaked into $([IO.Path]::GetFileName($file))"
    }
  }
  $globalResidue = Get-ChildItem -LiteralPath $Scratch -Recurse -Force -Filter 'wifi-import-*'
  if ($globalResidue) { Fail "transient wifi-import directory left behind: $($globalResidue.FullName -join ', ')" }
  $xmlResidue = Get-ChildItem -LiteralPath $Scratch -Recurse -Force -Filter 'profile-*.xml'
  if ($xmlResidue) { Fail "transient WLAN profile XML left behind: $($xmlResidue.FullName -join ', ')" }

  Write-Host 'wifi-import windows fixture: ok'
} finally {
  Remove-Item -LiteralPath $Scratch -Recurse -Force -ErrorAction SilentlyContinue
}
