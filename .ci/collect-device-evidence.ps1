# collect-device-evidence.ps1 — Windows device evidence collector.
#
# Measures a CANDIDATE checkout on a protected Windows device and emits one
# attestation-ready record without applying it to the live profile or changing
# device state. Foundational identity/render checks use isolated scratch state.
#
# Claims come only from the protected workflow via -Claim. G1a claims execute
# concrete read-only GitHub release and winget channel probes; availability may
# be pass or fail. Human-only G1b visual claims require -ProofFile outside the
# candidate checkout. Its strict JSON must bind each claim, device, candidate
# commit, canonical snapshot identity and digest, observed pass/fail status,
# and non-empty detail. Those checks are folded into this record before its
# bytes are attested. Unknown, duplicate, missing, or unmeasured claims fail
# before record write.
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)] [string] $DeviceId,
  [Parameter(Mandatory = $true)] [ValidateSet('windows')] [string] $OS,
  [Parameter(Mandatory = $true)] [ValidateSet('x64', 'arm64')] [string] $Arch,
  [Parameter(Mandatory = $true)] [string] $CandidateDir,
  [Parameter(Mandatory = $true)] [string] $CandidateCommit,
  [Parameter(Mandatory = $true)] [string] $SupportSnapshot,
  [Parameter(Mandatory = $true)] [string] $Repository,
  [Parameter(Mandatory = $true)] [string] $WorkflowRef,
  [Parameter(Mandatory = $true)] [string] $WorkflowSha,
  [Parameter(Mandatory = $true)] [string] $Environment,
  [Parameter(Mandatory = $true)] [ValidateSet('github-hosted', 'self-hosted')] [string] $RunnerClass,
  [Parameter(Mandatory = $true)] [string[]] $RunnerLabels,
  [Parameter(Mandatory = $true)] [string] $Output,
  [string[]] $Claim = @(),
  [string] $ProofFile
)

$ErrorActionPreference = 'Stop'

function Fail([string] $Message) {
  Write-Host "collect-device-evidence: $Message"
  exit 1
}

# --- claim validation (fail closed on anything the registry cannot measure) -----
$automatedRegistry = @(
  'runtime-arch', 'candidate-commit', 'support-snapshot', 'render-smoke',
  'wezterm-stable-release-published',
  'wezterm-kitty-unicode-placeholders-in-stable',
  'wezterm-stable-winget-package'
)
$visualRegistry = @(
  'inline-image-renders-in-tmux', 'inline-image-survives-scroll',
  'inline-image-survives-redraw', 'inline-image-survives-resize',
  'inline-image-survives-split', 'inline-image-over-ssh-to-fedora-vm'
)
if ($Claim.Count -eq 0) { $Claim = @('runtime-arch', 'candidate-commit', 'support-snapshot', 'render-smoke') }
if (@($Claim | Select-Object -Unique).Count -ne $Claim.Count) { Fail 'duplicate claims are not allowed' }
foreach ($c in $Claim) {
  if ($automatedRegistry -notcontains $c -and $visualRegistry -notcontains $c) {
    Fail "unknown claim '$c' — no trusted probe measures it"
  }
}

# --- input shape validation (fail closed) ----------------------------------------
if ($CandidateCommit -notmatch '^[0-9a-f]{40}$') { Fail "--CandidateCommit is not a 40-hex SHA: $CandidateCommit" }
if ($WorkflowSha -notmatch '^[0-9a-f]{40}$') { Fail "--WorkflowSha is not a 40-hex SHA: $WorkflowSha" }
if ($Repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { Fail "--Repository is not OWNER/REPO: $Repository" }
$expectedRefPrefix = "$Repository/.github/workflows/device-smoke.yml@refs/heads/"
if (-not $WorkflowRef.StartsWith($expectedRefPrefix)) {
  Fail "--WorkflowRef must pin device-smoke.yml on a branch of $Repository, got: $WorkflowRef"
}
if (-not (Test-Path -LiteralPath $SupportSnapshot -PathType Leaf)) { Fail "support snapshot not found: $SupportSnapshot" }
if (-not (Test-Path -LiteralPath $CandidateDir -PathType Container)) { Fail "candidate checkout not found: $CandidateDir" }
if (-not (Get-Command git -ErrorAction SilentlyContinue)) { Fail 'git is required' }

# --- probe: runtime-arch ------------------------------------------------------------
$runtimeArch = switch ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture) {
  'X64'   { 'x64' }
  'Arm64' { 'arm64' }
  default { Fail "unsupported runtime architecture: $_" }
}
if ($runtimeArch -ne $Arch) {
  Fail "runtime architecture $runtimeArch ($($env:PROCESSOR_ARCHITECTURE)) does not match declared -Arch $Arch"
}
# Raw machine identity for the record (schema: observed PROCESSOR_ARCHITECTURE
# or uname-style value; must normalize to device.arch).
$machineRaw = $env:PROCESSOR_ARCHITECTURE
if (-not $machineRaw) {
  $machineRaw = switch ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture) {
    'X64'   { 'x86_64' }
    'Arm64' { 'aarch64' }
  }
}

# --- probe: candidate-commit ----------------------------------------------------------
$actualCommit = (& git -C $CandidateDir rev-parse HEAD 2>$null)
if ($LASTEXITCODE -ne 0 -or -not $actualCommit) { Fail "candidate dir is not a git work tree: $CandidateDir" }
if ($actualCommit.Trim() -ne $CandidateCommit) {
  Fail "candidate checkout is at $($actualCommit.Trim()), expected $CandidateCommit"
}

# --- probe: support-snapshot ------------------------------------------------------------
# Candidate-controlled files are measured subjects only: the collector hashes
# ITSELF (the default-branch-pinned copy the protected workflow fetches) and
# the canonical support snapshot; the candidate never supplies the collector
# or the policy that judges it.
# sha256 over the validator's canonical JSON form (sorted keys, compact) —
# .ci/validate-device-evidence.mjs canonicalJson.
function ConvertTo-CanonicalJson($Value) {
  if ($null -eq $Value) { return 'null' }
  if ($Value -is [bool]) { return $Value.ToString().ToLowerInvariant() }
  if ($Value -is [string]) { return ($Value | ConvertTo-Json -Compress) }
  if ($Value -is [System.Collections.IList]) {
    return '[' + ((@($Value) | ForEach-Object { ConvertTo-CanonicalJson $_ }) -join ',') + ']'
  }
  if ($Value -is [pscustomobject]) {
    $props = $Value.PSObject.Properties | Sort-Object Name
    return '{' + ((@($props) | ForEach-Object {
      ($_.Name | ConvertTo-Json -Compress) + ':' + (ConvertTo-CanonicalJson $_.Value)
    }) -join ',') + '}'
  }
  return ($Value | ConvertTo-Json -Compress)
}

$collectorSha = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant()
$canonicalSnapshot = ConvertTo-CanonicalJson (Get-Content -Raw -LiteralPath $SupportSnapshot | ConvertFrom-Json)
$snapshotSha = ([System.BitConverter]::ToString(
  [System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($canonicalSnapshot))
) -replace '-', '').ToLowerInvariant()

# --- probe: render-smoke (never touches the live profile) ---------------------------------
$probeTemplate = '.chezmoiscripts/20-windows/run_onchange_before_winget.ps1.tmpl'
if ($Claim -contains 'render-smoke') {
  if (-not (Get-Command chezmoi -ErrorAction SilentlyContinue)) { Fail 'chezmoi is required on PATH (render-smoke was claimed)' }
  $probePath = Join-Path $CandidateDir $probeTemplate
  if (-not (Test-Path -LiteralPath $probePath -PathType Leaf)) {
    Fail "candidate is missing the render probe template: $probeTemplate"
  }

  $scratch = Join-Path ([IO.Path]::GetTempPath()) ("device-evidence-" + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Force -Path $scratch | Out-Null
  $savedRenderEnvironment = @{}
  $originalPath = $env:PATH
  try {
    $bindir = Join-Path $scratch 'bin'
    $target = Join-Path $scratch 'target'
    New-Item -ItemType Directory -Force -Path $bindir, $target | Out-Null
    $empty = Join-Path $scratch 'empty.toml'
    New-Item -ItemType File -Force -Path $empty | Out-Null
    $op = @(
      '@echo off',
      'if /I "%~1"=="whoami" (echo dummy@example.invalid & exit /b 0)',
      '<nul set /p "=dummy-secret"',
      'exit /b 0'
    ) -join "`r`n"
    Set-Content -LiteralPath (Join-Path $bindir 'op.cmd') -Value $op -Encoding Ascii

    $rendered = Join-Path $scratch 'rendered.ps1'
    $renderErr = Join-Path $scratch 'render.err.txt'
    # Candidate templates execute as code during rendering. Remove ambient
    # GitHub OIDC/action tokens and common credential variables from the child
    # environment, while retaining the OS environment chezmoi needs to start.
    foreach ($entry in [Environment]::GetEnvironmentVariables().GetEnumerator()) {
      $name = [string]$entry.Key
      if ($name -match '(?i)(TOKEN|SECRET|PASSWORD|PASSWD|CREDENTIAL|API[_-]?KEY|ACCESS[_-]?KEY|PRIVATE[_-]?KEY|AUTH)') {
        $savedRenderEnvironment[$name] = [string]$entry.Value
        [Environment]::SetEnvironmentVariable($name, $null, 'Process')
      }
    }
    $env:PATH = "$bindir;$originalPath"
    Get-Content -Raw -LiteralPath $probePath |
      & chezmoi --config $empty --source $CandidateDir --destination $target execute-template `
        1> $rendered 2> $renderErr
    if ($LASTEXITCODE -ne 0) {
      Fail "render smoke measurement failed — chezmoi execute-template exited $LASTEXITCODE`: $(Get-Content -Raw $renderErr)"
    }
    try {
      [void][ScriptBlock]::Create([IO.File]::ReadAllText($rendered))
    } catch {
      Fail "render smoke measurement failed — rendered probe does not parse: $($_.Exception.Message)"
    }
  } finally {
    $env:PATH = $originalPath
    foreach ($entry in $savedRenderEnvironment.GetEnumerator()) {
      [Environment]::SetEnvironmentVariable([string]$entry.Key, [string]$entry.Value, 'Process')
    }
    Remove-Item -Recurse -Force $scratch -ErrorAction SilentlyContinue
  }
}
# --- bind requested claims to measured or human-attested proof ----------------
function Test-ExactProperties($Value, [string[]] $Names) {
  $actual = @($Value.PSObject.Properties.Name | Sort-Object)
  $expected = @($Names | Sort-Object)
  return @(Compare-Object $actual $expected).Count -eq 0
}

$visualClaims = @($Claim | Where-Object { $visualRegistry -contains $_ })
$proofChecks = @{}
if ($visualClaims.Count -gt 0) {
  if (-not $ProofFile -or -not (Test-Path -LiteralPath $ProofFile -PathType Leaf)) {
    Fail 'requested visual claims require -ProofFile'
  }
  $proofPath = [IO.Path]::GetFullPath($ProofFile)
  $candidatePath = [IO.Path]::GetFullPath($CandidateDir).TrimEnd('\', '/')
  if ($proofPath -eq $candidatePath -or
      $proofPath.StartsWith($candidatePath + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    Fail 'proof file must be outside the candidate checkout'
  }
  try { $proof = Get-Content -Raw -LiteralPath $proofPath | ConvertFrom-Json } catch {
    Fail "proof file is not valid JSON: $($_.Exception.Message)"
  }
  if (-not (Test-ExactProperties $proof @('schemaVersion', 'device', 'candidate', 'supportSnapshot', 'checks')) -or
      $proof.schemaVersion -ne 1 -or
      -not (Test-ExactProperties $proof.device @('id')) -or $proof.device.id -ne $DeviceId -or
      -not (Test-ExactProperties $proof.candidate @('commit')) -or $proof.candidate.commit -ne $CandidateCommit -or
      -not (Test-ExactProperties $proof.supportSnapshot @('path', 'sha256')) -or
      $proof.supportSnapshot.path -ne '.ci/support-matrix.json' -or
      $proof.supportSnapshot.sha256 -ne $snapshotSha) {
    Fail 'proof file identity is not exactly bound to device/commit/snapshot'
  }
  $proofNames = @($proof.checks | ForEach-Object { $_.name })
  if (@(Compare-Object $proofNames $visualClaims).Count -ne 0 -or
      @($proofNames | Select-Object -Unique).Count -ne $proofNames.Count) {
    Fail 'proof checks do not exactly match requested visual claims'
  }
  foreach ($check in @($proof.checks)) {
    if (-not (Test-ExactProperties $check @('name', 'status', 'detail')) -or
        $check.status -notin @('pass', 'fail') -or [string]::IsNullOrWhiteSpace($check.detail) -or
        $check.detail.Length -gt 500) {
      Fail "visual proof check '$($check.name)' is malformed"
    }
    if ($check.detail -match '(?i)BEGIN .*PRIVATE KEY|ghp_[A-Za-z0-9]{20,}|github_pat_|Bearer [A-Za-z0-9._~+/=-]{10,}|password\s*[:=]|secret\s*[:=]') {
      Fail "visual proof check '$($check.name)' contains secret-shaped data"
    }
    $proofChecks[$check.name] = $check
  }
} elseif ($ProofFile) {
  Fail '-ProofFile was supplied but no visual claim was requested'
}

$weztermReleaseLoaded = $false
$weztermRelease = $null
function Get-WezTermStableRelease {
  if ($script:weztermReleaseLoaded) { return $script:weztermRelease }
  $script:weztermReleaseLoaded = $true
  try {
    $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/wezterm/wezterm/releases/latest' `
      -Method Get -TimeoutSec 30
    if (-not $release.draft -and -not $release.prerelease -and $release.tag_name) {
      $script:weztermRelease = $release
    }
  } catch {
    $script:weztermRelease = $null
  }
  return $script:weztermRelease
}

$checks = foreach ($c in $Claim) {
  if ($visualRegistry -contains $c) {
    [ordered]@{ name = $c; status = [string]$proofChecks[$c].status; detail = [string]$proofChecks[$c].detail }
    continue
  }
  $status = 'fail'
  $detail = switch ($c) {
    'runtime-arch' { $status = 'pass'; "OSArchitecture = $runtimeArch ($machineRaw)" }
    'candidate-commit' { $status = 'pass'; "checkout HEAD = $CandidateCommit" }
    'support-snapshot' { $status = 'pass'; "sha256 = $snapshotSha" }
    'render-smoke' { $status = 'pass'; "isolated execute-template of $probeTemplate rendered parseable PowerShell; live profile untouched" }
    'wezterm-stable-release-published' {
      $release = Get-WezTermStableRelease
      if ($release) { $status = 'pass'; "GitHub latest release is stable tag $($release.tag_name)" }
      else { 'GitHub latest release probe found no stable WezTerm release' }
    }
    'wezterm-kitty-unicode-placeholders-in-stable' {
      $release = Get-WezTermStableRelease
      if ($release -and [string]$release.body -match '(?is)kitty.{0,120}unicode.{0,40}placeholder|unicode.{0,40}placeholder.{0,120}kitty') {
        $status = 'pass'; 'stable WezTerm release notes explicitly document Kitty Unicode placeholders'
      } else { 'stable WezTerm release notes do not document Kitty Unicode placeholders' }
    }
    'wezterm-stable-winget-package' {
      $winget = Get-Command winget -ErrorAction SilentlyContinue
      if ($winget) {
        $wingetResult = & $winget.Source show --id wez.wezterm --source winget --exact --disable-interactivity 2>&1
        if ($LASTEXITCODE -eq 0 -and ($wingetResult -join "`n") -match '(?im)^Version:\s*\S+') {
          $status = 'pass'; 'winget source publishes a versioned stable wez.wezterm package'
        } else { 'winget source did not return a versioned stable wez.wezterm package' }
      } else { 'winget is unavailable for the stable package probe' }
    }
    default { Fail "claim '$c' has no automated probe" }
  }
  [ordered]@{ name = $c; status = $status; detail = $detail }
}

$record = [ordered]@{
  schemaVersion = 1
  device = [ordered]@{
    id           = $DeviceId
    os           = $OS
    arch         = $Arch
    runnerClass  = $RunnerClass
    runnerLabels = $RunnerLabels
  }
  collector = [ordered]@{ path = '.ci/collect-device-evidence.ps1'; sha256 = $collectorSha }
  candidate = [ordered]@{ commit = $CandidateCommit }
  supportSnapshot = [ordered]@{ path = '.ci/support-matrix.json'; sha256 = $snapshotSha }
  attestation = [ordered]@{
    kind         = 'github-artifact-attestation'
    bundlePath   = 'attestation.sigstore.json'
    issuer       = 'https://token.actions.githubusercontent.com'
    repository   = $Repository
    workflowRef  = $WorkflowRef
    workflowSha  = $WorkflowSha
    environment  = $Environment
  }
  measurements = [ordered]@{
    runtimeArch = $machineRaw
    checks      = @($checks)
  }
  collectedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
}

$outDir = Split-Path $Output
if ($outDir) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }
$record | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Output -Encoding utf8NoBOM
Write-Host ("collect-device-evidence: wrote {0} (device={1} arch={2} candidate={3} snapshot={4} claims={5})" -f `
  $Output, $DeviceId, $runtimeArch, $CandidateCommit, $snapshotSha, ($Claim -join ','))
