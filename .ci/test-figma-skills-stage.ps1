# Isolated, network-free proof of the exact official Figma collection external.
[CmdletBinding()]
param([string]$Root = (Get-Location).Path)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Fail([string]$Message) { throw "figma staging fixture: $Message" }

$base = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [IO.Path]::GetTempPath() }
$scratch = Join-Path $base ("figma-skills-stage.{0}" -f [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch | Out-Null
try {
  foreach ($command in @('chezmoi', 'tar')) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) { Fail "$command is required" }
  }

  $lock = Get-Content -Raw -LiteralPath (Join-Path $Root '.chezmoidata/releases.json') | ConvertFrom-Json
  $entry = $lock.releases.tools.'figma/mcp-server-guide'
  $revision = [string]$entry.revision
  if ($revision -notmatch '^[0-9a-f]{40}$') { Fail 'locked revision is invalid' }
  [string[]]$skills = @($entry.skills)
  if ($skills.Count -eq 0) { Fail 'locked inventory is empty' }

  $archiveRoot = Join-Path $scratch "mcp-server-guide-$revision"
  foreach ($skill in $skills) {
    $skillRoot = Join-Path $archiveRoot "skills/$skill"
    New-Item -ItemType Directory -Path (Join-Path $skillRoot 'references'), (Join-Path $skillRoot 'assets') | Out-Null
    Set-Content -LiteralPath (Join-Path $skillRoot 'SKILL.md') -Value "# $skill"
    Set-Content -LiteralPath (Join-Path $skillRoot 'references/guide.md') -Value "nested reference for $skill"
    Set-Content -LiteralPath (Join-Path $skillRoot 'assets/icon.txt') -Value "supporting asset for $skill"
  }
  New-Item -ItemType Directory -Path (Join-Path $archiveRoot 'skills/not-figma'), (Join-Path $archiveRoot 'docs') | Out-Null
  Set-Content -LiteralPath (Join-Path $archiveRoot 'skills/not-figma/SKILL.md') -Value 'excluded'
  Set-Content -LiteralPath (Join-Path $archiveRoot 'docs/repository.md') -Value 'excluded'
  $archive = Join-Path $scratch 'figma.tar.gz'
  & tar -C $scratch -czf $archive (Split-Path -Leaf $archiveRoot)
  if ($LASTEXITCODE -ne 0) { Fail 'could not create local archive' }

  $config = Join-Path $scratch 'empty.toml'
  [IO.File]::WriteAllText($config, '')
  $rendered = (& chezmoi --config $config --source $Root execute-template --file (Join-Path $Root '.chezmoiexternals/ai-agents.toml')) -join "`n"
  if ($LASTEXITCODE -ne 0) { Fail 'external template did not render' }
  $match = [regex]::Match($rendered, '(?ms)^\["\.local/share/figma-skills-stage"\]\r?\n.*?(?=\r?\n\r?\n|\z)')
  if (-not $match.Success) { Fail 'rendered Figma external stanza is missing' }
  $stanza = $match.Value
  if ($stanza -notmatch [regex]::Escape("archive/$revision.tar.gz")) { Fail 'external does not use the locked revision' }
  if ($stanza -notmatch '(?m)^exact = true$') { Fail 'external is not exact' }
  if ($stanza -notmatch '(?m)^stripComponents = 2$') { Fail 'external has the wrong archive root stripping' }
  $archiveUrl = [uri]::new((Resolve-Path -LiteralPath $archive).Path, [UriKind]::Absolute).AbsoluteUri
  $stanza = [regex]::Replace($stanza, '(?m)^url = .*$', "url = '$archiveUrl'")

  $sourceDir = Join-Path $scratch 'source'
  $externalDir = Join-Path $sourceDir '.chezmoiexternals'
  $destination = Join-Path $scratch 'home'
  $stage = Join-Path $destination '.local/share/figma-skills-stage'
  New-Item -ItemType Directory -Path $externalDir, (Join-Path $stage 'stale/nested') | Out-Null
  Set-Content -LiteralPath (Join-Path $stage 'stale/nested/file.txt') -Value 'staging residue'
  [IO.File]::WriteAllText((Join-Path $externalDir 'figma.toml'), $stanza + "`n")
  & chezmoi --config $config --source $sourceDir --destination $destination `
    --cache (Join-Path $scratch 'cache') --persistent-state (Join-Path $scratch 'state.boltdb') apply
  if ($LASTEXITCODE -ne 0) { Fail 'local archive materialization failed' }

  if (Test-Path -LiteralPath (Join-Path $stage 'stale')) { Fail 'exact materialization retained staging residue' }
  if ((Test-Path -LiteralPath (Join-Path $stage 'not-figma')) -or (Test-Path -LiteralPath (Join-Path $stage 'docs'))) {
    Fail 'unrelated archive content was staged'
  }
  foreach ($skill in $skills) {
    foreach ($relative in @('SKILL.md', 'references/guide.md', 'assets/icon.txt')) {
      if (-not (Test-Path -LiteralPath (Join-Path $stage "$skill/$relative") -PathType Leaf)) {
        Fail "missing $skill/$relative"
      }
    }
  }
  [string[]]$staged = @(Get-ChildItem -LiteralPath $stage -Directory | ForEach-Object Name | Sort-Object)
  [string[]]$expected = @($skills | Sort-Object)
  if (($staged -join "`n") -cne ($expected -join "`n")) { Fail 'staged direct children differ from the locked inventory' }

  Write-Output "figma skills PowerShell staging fixture passed ($($skills.Count) skills)"
}
finally {
  Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}
