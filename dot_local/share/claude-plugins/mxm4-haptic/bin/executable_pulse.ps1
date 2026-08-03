# pulse.ps1 <WAVEFORM> — fire-and-forget MX Master 4 haptic buzz (Windows).
#
# Invoked by the sibling hooks/hooks.json (generated from .chezmoidata/haptic.yaml
# -> haptic.claude) on Claude Code lifecycle events, on Windows renders only (the
# POSIX renders use the sibling `pulse` sh wrapper). It hands the waveform name to
# the mxm4-hapticd user daemon through the one-shot `mxm4-haptic` client; all
# device I/O, discovery, debounce and pacing live in the daemon.
#
# CONTRACT: this script ALWAYS exits 0 and always prints nothing — the exact
# Windows counterpart of bin/pulse. A Claude Code hook that exits non-zero
# surfaces an error to the user, and exit 2 BLOCKS the event outright. A buzz
# that cannot be delivered — daemon stopped, mouse asleep or unpaired, binary
# not built yet, waveform typo'd — must do neither. Every failure path here is
# a silent no-op. Do not "improve" this by letting an error escape.
param([string]$Waveform = '')

$ErrorActionPreference = 'SilentlyContinue'
trap { exit 0 }

if ([string]::IsNullOrWhiteSpace($Waveform)) { exit 0 }

# Prefer the absolute path (the phase-60 build installs the client beside the
# daemon at ~/.local/bin/mxm4-haptic.exe). Fall back to PATH only if the
# well-known location is missing — same rule as the POSIX wrapper.
$haptic = Join-Path $env:USERPROFILE '.local\bin\mxm4-haptic.exe'
if (-not (Test-Path -LiteralPath $haptic -PathType Leaf)) {
  $onPath = Get-Command 'mxm4-haptic' -ErrorAction SilentlyContinue
  if ($null -eq $onPath -or [string]::IsNullOrWhiteSpace($onPath.Source)) { exit 0 }
  $haptic = $onPath.Source
}

# The client is non-blocking and silent on success. Exit 1 = daemon
# unreachable, 2 = unknown waveform. Swallow both: the buzz is a nicety,
# never a failure mode.
try {
  & $haptic $Waveform *>$null
} catch {
  exit 0
}

exit 0
