[CmdletBinding()]
param(
  [string]$Root = (Split-Path -Parent $PSScriptRoot),
  [string]$RenderedScript
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
function Fail([string]$Message) { throw "figma reconcile fixture: $Message" }
function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { Fail $Message } }
$base = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [IO.Path]::GetTempPath() }
$scratch = Join-Path $base ('figma-skills-reconcile.' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch | Out-Null
try {
  $script = Join-Path $scratch 'reconcile.ps1'
  if ($RenderedScript) {
    Copy-Item -LiteralPath $RenderedScript -Destination $script
  } else {
    $config = Join-Path $scratch 'empty.toml'; [IO.File]::WriteAllText($config, '')
    $rendered = & chezmoi --config $config --source $Root --override-data '{"chezmoi":{"os":"windows"}}' execute-template --file (Join-Path $Root '.chezmoiscripts/70-agents/run_after_install-figma-skills.ps1.tmpl')
    if ($LASTEXITCODE -ne 0) { Fail 'PowerShell reconciler did not render' }
    [IO.File]::WriteAllText($script, (($rendered -join "`n") + "`n"), [Text.UTF8Encoding]::new($false))
  }
  Assert ((Get-Item -LiteralPath $script).Length -gt 0) 'PowerShell reconciler rendered empty'
  $lock = Get-Content -Raw -LiteralPath (Join-Path $Root '.chezmoidata/releases.json') | ConvertFrom-Json
  [string[]]$skills = @($lock.releases.tools.'figma/mcp-server-guide'.skills)
  Assert ($skills.Count -ge 2) 'fixture requires at least two locked skills'
  $expectedJson = ConvertTo-Json -Compress -InputObject @($skills)
  Assert ((Get-Content -Raw -LiteralPath $script).Contains("`$desiredSkillsJson = '$expectedJson'")) 'rendered inventory differs from lock'

  $caseRoot = Join-Path $scratch 'case'
  $fixtureHome = Join-Path $caseRoot 'home'
  $stage = Join-Path $caseRoot 'stage'
  $live = Join-Path $fixtureHome '.agents/skills'
  $ownership = Join-Path $caseRoot 'state/ownership.json'
  New-Item -ItemType Directory -Force -Path (Join-Path $live 'personal-skill'), (Join-Path $live 'figma-personal') | Out-Null
  [IO.File]::WriteAllText((Join-Path $live 'personal-skill/keep.txt'), 'personal')
  [IO.File]::WriteAllText((Join-Path $live 'figma-personal/keep.txt'), 'unowned')
  function Reset-Stage {
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    foreach ($skill in $skills) {
      $skillRoot = Join-Path $stage $skill
      New-Item -ItemType Directory -Force -Path (Join-Path $skillRoot 'references'), (Join-Path $skillRoot 'assets') | Out-Null
      [IO.File]::WriteAllText((Join-Path $skillRoot 'SKILL.md'), "# $skill`n")
      [IO.File]::WriteAllText((Join-Path $skillRoot 'references/guide.md'), "sibling: ../$skill/assets/icon.txt`n")
      [IO.File]::WriteAllText((Join-Path $skillRoot 'assets/icon.txt'), "asset $skill`n")
    }
  }
  function Invoke-Reconcile([hashtable]$Extra = @{}) {
    $saved = @{}
    $values = @{ HOME=$fixtureHome; FIGMA_SKILLS_ROOT=$live; FIGMA_SKILLS_STAGE=$stage; FIGMA_SKILLS_OWNERSHIP=$ownership }
    foreach ($entry in $Extra.GetEnumerator()) { $values[$entry.Key] = $entry.Value }
    foreach ($entry in $values.GetEnumerator()) { $saved[$entry.Key] = [Environment]::GetEnvironmentVariable($entry.Key, 'Process'); [Environment]::SetEnvironmentVariable($entry.Key, [string]$entry.Value, 'Process') }
    try { & $script } finally { foreach ($entry in $saved.GetEnumerator()) { [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, 'Process') } }
  }
  function Invoke-CrashedChild([string]$Injection) {
    $names = @('HOME','FIGMA_SKILLS_ROOT','FIGMA_SKILLS_STAGE','FIGMA_SKILLS_OWNERSHIP','FIGMA_SKILLS_INJECT_FAILURE')
    $saved = @{}
    foreach ($name in $names) { $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
    try {
      $env:HOME=$fixtureHome
      $env:FIGMA_SKILLS_ROOT=$live
      $env:FIGMA_SKILLS_STAGE=$stage
      $env:FIGMA_SKILLS_OWNERSHIP=$ownership
      $env:FIGMA_SKILLS_INJECT_FAILURE=$Injection
      $process = Start-Process -FilePath (Get-Command pwsh -CommandType Application).Source -ArgumentList @('-NoProfile','-NonInteractive','-File',$script) -PassThru
      $process.WaitForExit()
      return $process.ExitCode
    } finally {
      foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process') }
    }
  }
  function Get-Snapshot {
    $rows = foreach ($basePath in @($fixtureHome, (Split-Path -Parent $ownership))) {
      if (Test-Path -LiteralPath $basePath) {
        Get-ChildItem -LiteralPath $basePath -File -Recurse -Force | Sort-Object FullName | ForEach-Object {
          '{0}:{1}' -f $_.FullName.Substring($caseRoot.Length), (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
        }
      }
    }
    return ($rows -join "`n")
  }
  function Assert-PreflightFailure([string]$Label) {
    $before = Get-Snapshot; $failed = $false
    try { Invoke-Reconcile } catch { $failed = $true }
    Assert $failed "$Label unexpectedly succeeded"
    Assert ((Get-Snapshot) -ceq $before) "$Label mutated managed state"
  }
  function Get-ManifestSkills { return @((Get-Content -Raw -LiteralPath $ownership | ConvertFrom-Json).skills) }
  Reset-Stage

  # First install and complete supporting subtrees.
  Invoke-Reconcile
  Assert (((Get-ManifestSkills) -join "`n") -ceq ($skills -join "`n")) 'first install ownership differs from lock'
  foreach ($skill in $skills) {
    foreach ($relative in @('SKILL.md','references/guide.md','assets/icon.txt')) { Assert (Test-Path -LiteralPath (Join-Path $live "$skill/$relative") -PathType Leaf) "incomplete subtree for $skill" }
  }
  Assert (Test-Path -LiteralPath (Join-Path $live 'personal-skill/keep.txt')) 'personal sibling was removed'
  Assert (Test-Path -LiteralPath (Join-Path $live 'figma-personal/keep.txt')) 'unowned figma sibling was removed'

  # Matching apply is byte- and mtime-preserving.
  $manifestHash = (Get-FileHash -LiteralPath $ownership -Algorithm SHA256).Hash
  $manifestTime = (Get-Item -LiteralPath $ownership).LastWriteTimeUtc.Ticks
  $skillTime = (Get-Item -LiteralPath (Join-Path $live "$($skills[0])/SKILL.md")).LastWriteTimeUtc.Ticks
  Invoke-Reconcile
  Assert ((Get-FileHash -LiteralPath $ownership -Algorithm SHA256).Hash -ceq $manifestHash) 'no-op rewrote ownership'
  Assert ((Get-Item -LiteralPath $ownership).LastWriteTimeUtc.Ticks -eq $manifestTime) 'no-op changed manifest mtime'
  Assert ((Get-Item -LiteralPath (Join-Path $live "$($skills[0])/SKILL.md")).LastWriteTimeUtc.Ticks -eq $skillTime) 'no-op changed skill mtime'

  # Drift repair, addition collision adoption, and prior-manifest-only removal.
  [IO.File]::WriteAllText((Join-Path $live "$($skills[0])/SKILL.md"), 'tampered')
  $newSkill = $skills[-1]
  $oldSkills = @($skills[0..($skills.Count - 2)])
  $oldManifest = [ordered]@{ schema='figma-skills-ownership/v1'; transactionId='prior-fixture'; skills=$oldSkills } | ConvertTo-Json -Compress
  [IO.File]::WriteAllText($ownership, $oldManifest + "`n", [Text.UTF8Encoding]::new($false))
  Remove-Item -LiteralPath (Join-Path $live $newSkill) -Recurse -Force
  New-Item -ItemType Directory -Path (Join-Path $live $newSkill) | Out-Null
  [IO.File]::WriteAllText((Join-Path $live "$newSkill/user.txt"), 'collision')
  New-Item -ItemType Directory -Force -Path (Join-Path $live 'figma-retired-unowned') | Out-Null
  [IO.File]::WriteAllText((Join-Path $live 'figma-retired-unowned/file'), 'keep')
  Invoke-Reconcile
  Assert ((Get-Content -Raw -LiteralPath (Join-Path $live "$($skills[0])/SKILL.md")).StartsWith('# ')) 'drift was not repaired'
  Assert (-not (Test-Path -LiteralPath (Join-Path $live "$newSkill/user.txt"))) 'desired collision was not adopted'
  Assert (Test-Path -LiteralPath (Join-Path $live 'figma-retired-unowned/file')) 'prefix-wide deletion occurred'
  $retired = 'figma-fixture-retired'
  New-Item -ItemType Directory -Path (Join-Path $live $retired) | Out-Null
  [IO.File]::WriteAllText((Join-Path $live "$retired/SKILL.md"), 'retired')
  $current = Get-Content -Raw -LiteralPath $ownership | ConvertFrom-Json
  $retiredManifest = [ordered]@{ schema=$current.schema; transactionId=$current.transactionId; skills=@($current.skills + $retired | Sort-Object) } | ConvertTo-Json -Compress
  [IO.File]::WriteAllText($ownership, $retiredManifest + "`n", [Text.UTF8Encoding]::new($false))
  Invoke-Reconcile
  Assert (-not (Test-Path -LiteralPath (Join-Path $live $retired))) 'prior-owned retired skill was preserved'

  # Invalid staging, ownership, destination types, reparse points, and ambiguity fail before mutation.
  Remove-Item -LiteralPath (Join-Path $stage "$($skills[0])/SKILL.md"); Assert-PreflightFailure 'missing staging'; Reset-Stage
  Remove-Item -LiteralPath $stage -Recurse -Force; New-Item -ItemType Directory -Path $stage | Out-Null; Assert-PreflightFailure 'empty staging'; Reset-Stage
  New-Item -ItemType Directory -Path (Join-Path $stage 'extra') | Out-Null; [IO.File]::WriteAllText((Join-Path $stage 'extra/SKILL.md'),'x'); Assert-PreflightFailure 'extra staging'; Reset-Stage
  $savedOwnership = Join-Path $scratch 'ownership.saved'; Copy-Item -LiteralPath $ownership -Destination $savedOwnership; Remove-Item -LiteralPath $ownership; Assert-PreflightFailure 'missing ownership'; Move-Item -LiteralPath $savedOwnership -Destination $ownership
  [IO.File]::WriteAllText($ownership, '{bad'); Assert-PreflightFailure 'corrupt ownership'
  [IO.File]::WriteAllText($ownership, '{"schema":"figma-skills-ownership/v0","transactionId":"x","skills":[]}'); Assert-PreflightFailure 'schema ownership'
  $valid = [ordered]@{ schema='figma-skills-ownership/v1'; transactionId='reset'; skills=$skills } | ConvertTo-Json -Compress
  [IO.File]::WriteAllText($ownership, $valid + "`n", [Text.UTF8Encoding]::new($false))
  Remove-Item -LiteralPath (Join-Path $live $skills[0]) -Recurse -Force; [IO.File]::WriteAllText((Join-Path $live $skills[0]), 'file'); Assert-PreflightFailure 'destination file'
  Remove-Item -LiteralPath (Join-Path $live $skills[0]) -Force; Copy-Item -LiteralPath (Join-Path $stage $skills[0]) -Destination (Join-Path $live $skills[0]) -Recurse
  $caseAmbiguous = @($skills[0], $skills[0].ToUpperInvariant()) | Sort-Object -CaseSensitive
  $ambiguousManifest = [ordered]@{ schema='figma-skills-ownership/v1'; transactionId='case-ambiguity'; skills=$caseAmbiguous } | ConvertTo-Json -Compress
  [IO.File]::WriteAllText($ownership, $ambiguousManifest + "`n", [Text.UTF8Encoding]::new($false)); Assert-PreflightFailure 'case ambiguity'
  [IO.File]::WriteAllText($ownership, $valid + "`n", [Text.UTF8Encoding]::new($false))
  $referent = Join-Path $scratch 'referent'; New-Item -ItemType Directory -Path $referent | Out-Null
  Remove-Item -LiteralPath (Join-Path $live $skills[0]) -Recurse -Force
  $linkType = if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }
  try { New-Item -ItemType $linkType -Path (Join-Path $live $skills[0]) -Target $referent | Out-Null; Assert-PreflightFailure 'destination reparse point' } finally { Remove-Item -LiteralPath (Join-Path $live $skills[0]) -Recurse -Force -Confirm:$false -ErrorAction SilentlyContinue }
  Copy-Item -LiteralPath (Join-Path $stage $skills[0]) -Destination (Join-Path $live $skills[0]) -Recurse

  # Exclusive lock.
  $oldHome=$env:HOME; $oldRoot=$env:FIGMA_SKILLS_ROOT; $oldStage=$env:FIGMA_SKILLS_STAGE; $oldOwnership=$env:FIGMA_SKILLS_OWNERSHIP; $oldHold=$env:FIGMA_SKILLS_HOLD_LOCK_SECONDS
  $env:HOME=$fixtureHome; $env:FIGMA_SKILLS_ROOT=$live; $env:FIGMA_SKILLS_STAGE=$stage; $env:FIGMA_SKILLS_OWNERSHIP=$ownership; $env:FIGMA_SKILLS_HOLD_LOCK_SECONDS='2'
  $holder = Start-Process -FilePath (Get-Command pwsh -CommandType Application).Source -ArgumentList @('-NoProfile','-NonInteractive','-File',$script) -PassThru
  try {
    $observedLock = $false
    $deadline=[DateTime]::UtcNow.AddSeconds(5)
    while (-not $observedLock -and [DateTime]::UtcNow -lt $deadline) {
      try {
        $probe = [IO.File]::Open("$ownership.lock", [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        $probe.Dispose()
        Start-Sleep -Milliseconds 50
      } catch { $observedLock = $true }
    }
    Assert $observedLock 'lock holder did not acquire the process-lifetime lock'
    $failed=$false; try { Invoke-Reconcile } catch { $failed=$true }; Assert $failed 'exclusive lock admitted a contender'
  } finally { $holder.WaitForExit(); $env:HOME=$oldHome; $env:FIGMA_SKILLS_ROOT=$oldRoot; $env:FIGMA_SKILLS_STAGE=$oldStage; $env:FIGMA_SKILLS_OWNERSHIP=$oldOwnership; $env:FIGMA_SKILLS_HOLD_LOCK_SECONDS=$oldHold }
  Assert ($holder.ExitCode -eq 0) 'lock holder failed'

  # Handled rollback and phase-aware crash recovery.
  [IO.File]::WriteAllText((Join-Path $live "$($skills[0])/SKILL.md"), 'old-live')
  $rollbackBefore=Get-Snapshot; $failed=$false; try { Invoke-Reconcile @{FIGMA_SKILLS_INJECT_FAILURE='after-first-replacement'} } catch { $failed=$true }; Assert $failed 'rollback injection succeeded'; Assert ((Get-Snapshot) -ceq $rollbackBefore) 'handled failure did not restore prior state'

  # Hard process termination leaves an unlockable journal, and rollback can
  # itself be interrupted without consuming any sole backup.
  [IO.File]::WriteAllText((Join-Path $live "$($skills[0])/SKILL.md"), 'rollback-original-one')
  [IO.File]::WriteAllText((Join-Path $live "$($skills[1])/SKILL.md"), 'rollback-original-two')
  Assert ((Invoke-CrashedChild 'hard-crash-after-first-replacement') -ne 0) 'hard-crash injection succeeded'
  Assert (Test-Path -LiteralPath "$ownership.lock" -PathType Leaf) 'hard crash left no persistent lock file'
  Assert (Test-Path -LiteralPath "$ownership.journal" -PathType Leaf) 'hard crash left no recovery journal'
  $crashTxn = [string](Get-Content -Raw -LiteralPath "$ownership.journal" | ConvertFrom-Json).transactionDir
  Assert (Test-Path -LiteralPath (Join-Path $crashTxn "backups/$($skills[0])/SKILL.md") -PathType Leaf) 'hard crash lost first rollback backup'
  Assert (Test-Path -LiteralPath (Join-Path $crashTxn "backups/$($skills[1])/SKILL.md") -PathType Leaf) 'hard crash lost second rollback backup'
  Assert ((Invoke-CrashedChild 'rollback-hard-crash') -ne 0) 'rollback hard-crash injection succeeded'
  Assert (Test-Path -LiteralPath "$ownership.journal" -PathType Leaf) 'interrupted rollback lost recovery journal'
  Assert (Test-Path -LiteralPath (Join-Path $crashTxn "backups/$($skills[0])/SKILL.md") -PathType Leaf) 'interrupted rollback consumed first backup'
  Assert (Test-Path -LiteralPath (Join-Path $crashTxn "backups/$($skills[1])/SKILL.md") -PathType Leaf) 'interrupted rollback consumed second backup'
  Assert ((Get-Content -Raw -LiteralPath (Join-Path $live "$($skills[0])/SKILL.md")) -ceq 'rollback-original-one') 'interrupted rollback did not restore its first destination'
  Invoke-Reconcile
  Assert (-not (Test-Path -LiteralPath "$ownership.journal")) 'restartable rollback recovery left a journal'
  Assert (-not (Test-Path -LiteralPath $crashTxn)) 'restartable rollback recovery left its transaction directory'
  Assert ((Get-Content -Raw -LiteralPath (Join-Path $live "$($skills[0])/SKILL.md")).StartsWith('# ')) 'post-rollback reconciliation did not converge'
  [IO.File]::WriteAllText((Join-Path $live "$($skills[0])/SKILL.md"), 'pre-commit drift')
  $failed=$false; try { Invoke-Reconcile @{FIGMA_SKILLS_INJECT_FAILURE='pre-commit-crash'} } catch { $failed=$true }; Assert $failed 'pre-commit crash injection succeeded'; Assert (Test-Path -LiteralPath "$ownership.journal") 'pre-commit crash left no journal'
  Invoke-Reconcile; Assert (-not (Test-Path -LiteralPath "$ownership.journal")) 'pre-commit recovery left a journal'
  [IO.File]::WriteAllText((Join-Path $live "$($skills[0])/SKILL.md"), 'post-commit drift')
  $failed=$false; try { Invoke-Reconcile @{FIGMA_SKILLS_INJECT_FAILURE='post-commit-crash'} } catch { $failed=$true }; Assert $failed 'post-commit crash injection succeeded'; Assert (Test-Path -LiteralPath "$ownership.journal") 'post-commit crash left no journal'
  $manifestId=(Get-Content -Raw -LiteralPath $ownership|ConvertFrom-Json).transactionId; $journalId=(Get-Content -Raw -LiteralPath "$ownership.journal"|ConvertFrom-Json).transactionId; Assert ($manifestId -ceq $journalId) 'post-commit transaction IDs differ'
  Invoke-Reconcile; Assert (-not (Test-Path -LiteralPath "$ownership.journal")) 'forward recovery left a journal'
  Assert (((Get-ManifestSkills) -join "`n") -ceq ($skills -join "`n")) 'final ownership differs from lock'
  Assert (Test-Path -LiteralPath (Join-Path $live 'figma-retired-unowned/file')) 'final unrelated preservation failed'

  Write-Output "figma skills PowerShell transaction, recovery, lock, idempotence, drift, adoption, removal-authority, reparse, parity, and subtree fixture passed ($($skills.Count) skills)"
} finally {
  Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}
