# test-device-collectors.ps1 — focused fixtures for the Windows device evidence
# collector (.ci/collect-device-evidence.ps1). Proves the collector emits a
# well-formed record on the happy path and fails closed — writing no record —
# on every trust violation. Runs natively on the Windows x64 hosted leg.
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

$repoRoot = Split-Path -Parent $PSScriptRoot
$collector = Join-Path $repoRoot '.ci/collect-device-evidence.ps1'
if (-not (Test-Path -LiteralPath $collector)) { Write-Error "collector missing: $collector"; exit 1 }
if (-not (Get-Command chezmoi -ErrorAction SilentlyContinue)) { Write-Error 'chezmoi is required (render-smoke probe)'; exit 1 }
if (-not (Get-Command git -ErrorAction SilentlyContinue)) { Write-Error 'git is required'; exit 1 }
if (-not (Get-Command node -ErrorAction SilentlyContinue)) { Write-Error 'node is required (schema validator)'; exit 1 }

function Fail([string] $Message) { Write-Host "test-device-collectors: $Message"; exit 1 }

$scratch = Join-Path ([IO.Path]::GetTempPath()) ("device-collector-test-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $scratch | Out-Null
try {
  $candidateCommit = (& git -C $repoRoot rev-parse HEAD).Trim()
  $workflowSha = (& git -C $repoRoot hash-object .github/workflows/device-smoke.yml).Trim()
  $repository = 'example/dotfiles'
  $workflowRef = "$repository/.github/workflows/device-smoke.yml@refs/heads/main"
  $snapshot = Join-Path $scratch 'support-matrix.json'
  '{"schemaVersion":1,"targets":[]}' | Set-Content -LiteralPath $snapshot -Encoding utf8NoBOM
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
  $canonicalSnapshot = ConvertTo-CanonicalJson (Get-Content -Raw -LiteralPath $snapshot | ConvertFrom-Json)
  $snapshotSha = ([System.BitConverter]::ToString(
    [System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($canonicalSnapshot))
  ) -replace '-', '').ToLowerInvariant()
  $collectorSha = (Get-FileHash -LiteralPath $collector -Algorithm SHA256).Hash.ToLowerInvariant()

  $baseArgs = @{
    DeviceId         = 'windows-x64'
    OS               = 'windows'
    Arch             = 'x64'
    CandidateDir     = $repoRoot
    CandidateCommit  = $candidateCommit
    SupportSnapshot  = $snapshot
    Repository       = $repository
    WorkflowRef      = $workflowRef
    WorkflowSha      = $workflowSha
    Environment      = 'device-evidence'
    RunnerClass      = 'github-hosted'
    RunnerLabels     = @('github-hosted', 'windows', 'x64')
  }

  function Expect-Fail([string] $Name, [hashtable] $Overrides) {
    $out = Join-Path $scratch 'negative.json'
    Remove-Item -Force $out -ErrorAction SilentlyContinue
    $args = $baseArgs.Clone()
    foreach ($key in $Overrides.Keys) { $args[$key] = $Overrides[$key] }
    & $collector @args -Output $out *> (Join-Path $scratch 'neg.log')
    if ($LASTEXITCODE -eq 0) { Fail "negative case '$Name' unexpectedly succeeded" }
    if (Test-Path -LiteralPath $out) { Fail "negative case '$Name' wrote a record anyway" }
    Write-Host "ok: fails closed — $Name"
  }

  # --- positive -----------------------------------------------------------------
  $evidence = Join-Path $scratch 'evidence.json'
  & $collector @baseArgs -Output $evidence *> (Join-Path $scratch 'pos.log')
  if ($LASTEXITCODE -ne 0) { Fail "positive case failed: $(Get-Content -Raw (Join-Path $scratch 'pos.log'))" }
  $record = Get-Content -LiteralPath $evidence -Raw | ConvertFrom-Json
  if ($record.schemaVersion -ne 1) { Fail 'schemaVersion != 1' }
  if ($record.device.id -ne 'windows-x64') { Fail 'device id mismatch' }
  if ($record.device.os -ne 'windows' -or $record.device.arch -ne 'x64') { Fail 'device os/arch mismatch' }
  if ($record.device.runnerClass -ne 'github-hosted') { Fail 'runner class mismatch' }
  if (@(Compare-Object @($record.device.runnerLabels) @('github-hosted', 'windows', 'x64')).Count -ne 0) { Fail 'runner labels mismatch' }
  if ($record.collector.path -ne '.ci/collect-device-evidence.ps1') { Fail 'collector path mismatch' }
  if ($record.collector.sha256 -ne $collectorSha) { Fail 'collector digest mismatch' }
  if ($record.candidate.commit -ne $candidateCommit) { Fail 'candidate commit mismatch' }
  if ($record.supportSnapshot.sha256 -ne $snapshotSha) { Fail 'support snapshot digest mismatch' }
  if ($record.supportSnapshot.path -ne '.ci/support-matrix.json') { Fail 'support snapshot path mismatch' }
  if ($record.attestation.kind -ne 'github-artifact-attestation') { Fail 'attestation kind mismatch' }
  if ($record.attestation.issuer -ne 'https://token.actions.githubusercontent.com') { Fail 'attestation issuer mismatch' }
  if ($record.attestation.repository -ne $repository) { Fail 'attestation repository mismatch' }
  if ($record.attestation.workflowRef -ne $workflowRef) { Fail 'attestation workflow ref mismatch' }
  if ($record.attestation.workflowSha -ne $workflowSha) { Fail 'attestation workflow sha mismatch' }
  if ($record.attestation.environment -ne 'device-evidence') { Fail 'attestation environment mismatch' }
  $expectedRaw = if ($env:PROCESSOR_ARCHITECTURE) { $env:PROCESSOR_ARCHITECTURE } else { 'x86_64' }
  if ($record.measurements.runtimeArch -ne $expectedRaw) { Fail "runtime arch mismatch: $($record.measurements.runtimeArch) != $expectedRaw" }
  $expectedChecks = @('candidate-commit', 'render-smoke', 'runtime-arch', 'support-snapshot')
  $actualChecks = @($record.measurements.checks | ForEach-Object { $_.name } | Sort-Object)
  if (@(Compare-Object $actualChecks $expectedChecks).Count -ne 0) { Fail "check names mismatch: $($actualChecks -join ',')" }
  foreach ($check in $record.measurements.checks) {
    if ($check.status -ne 'pass') { Fail "check $($check.name) did not pass" }
  }
  Write-Host 'ok: positive record is well-formed and fully bound'

  # Exercise the emitted bytes through the repository's schema interpreter
  # after a JSON serialize/parse round trip.
  $roundTripScript = Join-Path $scratch 'schema-roundtrip.mjs'
  @'
import { readFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
const [evidencePath, schemaPath, validatorPath] = process.argv.slice(2);
const { validateSchema } = await import(pathToFileURL(validatorPath));
const schema = JSON.parse(readFileSync(schemaPath, 'utf8'));
const record = JSON.parse(JSON.stringify(JSON.parse(readFileSync(evidencePath, 'utf8'))));
const errors = validateSchema(record, schema);
if (errors.length) {
  console.error(errors.join('\n'));
  process.exit(1);
}
'@ | Set-Content -LiteralPath $roundTripScript -Encoding utf8NoBOM
  & node $roundTripScript $evidence `
    (Join-Path $repoRoot '.ci/device-evidence.schema.json') `
    (Join-Path $repoRoot '.ci/validate-device-evidence.mjs')
  if ($LASTEXITCODE -ne 0) { Fail 'positive record failed schema/validator round trip' }
  Write-Host 'ok: positive record survives schema/validator round trip'

  # Human-only G1b claims require an external proof whose identity and result
  # are folded into the evidence record.
  $proofPath = Join-Path $scratch 'g1b-proof.json'
  $proof = [ordered]@{
    schemaVersion = 1
    device = [ordered]@{ id = 'windows-x64' }
    candidate = [ordered]@{ commit = $candidateCommit }
    supportSnapshot = [ordered]@{ path = '.ci/support-matrix.json'; sha256 = $snapshotSha }
    checks = @([ordered]@{
      name = 'inline-image-renders-in-tmux'
      status = 'pass'
      detail = 'operator observed the protected device'
    })
  }
  $proof | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $proofPath -Encoding utf8NoBOM
  $visualEvidence = Join-Path $scratch 'visual-evidence.json'
  $visualArgs = $baseArgs.Clone()
  $visualArgs.Claim = @('inline-image-renders-in-tmux')
  $visualArgs.ProofFile = $proofPath
  & $collector @visualArgs -Output $visualEvidence *> (Join-Path $scratch 'visual.log')
  if ($LASTEXITCODE -ne 0) { Fail "bound visual proof was rejected: $(Get-Content -Raw (Join-Path $scratch 'visual.log'))" }
  $visualRecord = Get-Content -Raw -LiteralPath $visualEvidence | ConvertFrom-Json
  if ($visualRecord.measurements.checks.Count -ne 1 -or
      $visualRecord.measurements.checks[0].detail -ne 'operator observed the protected device') {
    Fail 'visual proof was not folded into evidence'
  }
  Write-Host 'ok: bound visual proof is folded into evidence'

  $wrongProofPath = Join-Path $scratch 'wrong-proof.json'
  $proof.candidate.commit = '0000000000000000000000000000000000000000'
  $proof | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $wrongProofPath -Encoding utf8NoBOM
  Expect-Fail 'visual proof candidate mismatch' @{
    Claim = @('inline-image-renders-in-tmux')
    ProofFile = $wrongProofPath
  }
  Expect-Fail 'missing visual proof' @{ Claim = @('inline-image-renders-in-tmux') }

  # A candidate template is executable during rendering, so prove the child
  # cannot observe an ambient credential even when it deliberately probes it.
  $credentialCandidate = Join-Path $scratch 'credential-candidate'
  $probeTemplate = '.chezmoiscripts/20-windows/run_onchange_before_winget.ps1.tmpl'
  $probePath = Join-Path $credentialCandidate $probeTemplate
  New-Item -ItemType Directory -Force -Path (Split-Path $probePath) | Out-Null
  @'
{{ if eq (env "GITHUB_TOKEN") "device-evidence-sentinel-credential" }}function LeakedCredential {
{{ end }}
Write-Output 'ok'
'@ | Set-Content -LiteralPath $probePath -Encoding utf8NoBOM
  & git -C $credentialCandidate init -q
  & git -C $credentialCandidate add $probeTemplate
  & git -C $credentialCandidate `
    -c user.name=device-evidence -c user.email=device-evidence@example.invalid `
    commit -qm credential-isolation-fixture
  $credentialArgs = $baseArgs.Clone()
  $credentialArgs.CandidateDir = $credentialCandidate
  $credentialArgs.CandidateCommit = (& git -C $credentialCandidate rev-parse HEAD).Trim()
  $credentialEvidence = Join-Path $scratch 'credential-isolation.json'
  $originalGithubToken = $env:GITHUB_TOKEN
  try {
    $env:GITHUB_TOKEN = 'device-evidence-sentinel-credential'
    & $collector @credentialArgs -Output $credentialEvidence *> (Join-Path $scratch 'credential.log')
  } finally {
    $env:GITHUB_TOKEN = $originalGithubToken
  }
  if ($LASTEXITCODE -ne 0) {
    Fail "candidate template observed injected sentinel credential: $(Get-Content -Raw (Join-Path $scratch 'credential.log'))"
  }
  Write-Host 'ok: render child cannot read injected sentinel credential'

  # --- negatives ------------------------------------------------------------------
  Expect-Fail 'wrong runtime arch' @{ Arch = 'arm64' }
  Expect-Fail 'candidate commit mismatch' @{ CandidateCommit = '0000000000000000000000000000000000000000' }
  Expect-Fail 'missing support snapshot' @{ SupportSnapshot = (Join-Path $scratch 'no-such-snapshot.json') }
  Expect-Fail 'malformed workflow sha' @{ WorkflowSha = 'nothex' }
  Expect-Fail 'unknown claim' @{ Claim = @('candidate-invented-claim') }
  Expect-Fail 'workflow ref outside repository' @{
    WorkflowRef = 'evil/repo/.github/workflows/device-smoke.yml@refs/heads/main'
  }
  $notARepo = Join-Path $scratch 'not-a-repo'
  New-Item -ItemType Directory -Force -Path $notARepo | Out-Null
  Expect-Fail 'candidate dir is not a git work tree' @{ CandidateDir = $notARepo }

  Write-Host 'test-device-collectors: all fixtures passed (windows/x64)'
} finally {
  Remove-Item -Recurse -Force $scratch -ErrorAction SilentlyContinue
}
