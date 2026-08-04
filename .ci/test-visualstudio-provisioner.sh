#!/usr/bin/env bash
# Deterministic Visual Studio 2026 provisioner fixture. All rendering and
# PowerShell effects are confined to a task-scoped scratch directory.
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
scratch_root="${XDG_RUNTIME_DIR:-$HOME/.cache}/agent-scratch"
mkdir -p "$scratch_root"
scratch=$(mktemp -d "$scratch_root/visualstudio-provisioner.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
mkdir -p "$scratch/bin" "$scratch/home" "$scratch/temp"
printf '#!/usr/bin/env bash\nprintf dummy-secret\n' >"$scratch/bin/op"
chmod 700 "$scratch/bin/op"
printf '[data]\n' >"$scratch/empty.toml"

fail() { printf 'visual studio provisioner: %s\n' "$*" >&2; exit 1; }
render() {
  local arch=$1 output=$2
  HOME="$scratch/home" PATH="$scratch/bin:$PATH" \
    chezmoi --config "$scratch/empty.toml" --source "$repo_root" \
      --override-data "{\"chezmoi\":{\"os\":\"windows\",\"arch\":\"$arch\"}}" \
      execute-template \
      <"$repo_root/.chezmoiscripts/30-windows/run_onchange_after_install-visual-studio.ps1.tmpl" \
      >"$output"
}

render amd64 "$scratch/visualstudio-amd64.ps1"
render arm64 "$scratch/visualstudio-arm64.ps1"

DECLARED=()
while IFS= read -r id; do
  DECLARED+=("$id")
done < <(sed -n '/^  workloads:/,/^  components:/s/^    - //p; /^  components:/,$s/^    - //p' \
  "$repo_root/.chezmoidata/visualstudio.yaml")
((${#DECLARED[@]} > 0)) || fail 'no declared workload/component IDs were parsed'
EXPECTED_DECLARED=(
  Microsoft.VisualStudio.Workload.NativeDesktop
  Microsoft.VisualStudio.Workload.ManagedDesktop
  Microsoft.VisualStudio.Component.VC.Tools.x86.x64
  Microsoft.VisualStudio.Component.Windows11SDK.26100
  Microsoft.VisualStudio.Component.VC.CMake.Project
  Microsoft.Net.Component.4.8.TargetingPack
)
if ! diff -u <(printf '%s\n' "${EXPECTED_DECLARED[@]}" | sort) <(printf '%s\n' "${DECLARED[@]}" | sort) >/dev/null; then
  fail 'declared workload/component IDs do not satisfy the Windows toolchain contract'
fi

for rendered in "$scratch/visualstudio-amd64.ps1" "$scratch/visualstudio-arm64.ps1"; do
  for id in "${DECLARED[@]}"; do
    grep -F -- "\"$id\"" "$rendered" >/dev/null || fail "$rendered is missing declared ID $id"
  done
  if grep -F 'Windows10SDK' "$rendered" >/dev/null; then
    fail "$rendered contains a forbidden Windows 10 SDK component"
  fi
  if grep -E '[A-Za-z]:\\Program Files( \(x86\))?\\Microsoft Visual Studio' "$rendered" >/dev/null; then
    fail "$rendered contains a hard-coded Visual Studio installation root"
  fi
done

# Rendering must reject a malformed workload ID before any script can run.
malformed_data='{"chezmoi":{"os":"windows","arch":"amd64"},"visualstudio":{"product":"Microsoft.VisualStudio.Product.Community","versionRange":"[18.0,19.0)","bootstrapperUrl":"https://aka.ms/vs/stable/vs_community.exe","workloads":["Microsoft.VisualStudio.Workload.NativeDesktop;invalid"],"components":["Microsoft.VisualStudio.Component.VC.Tools.x86.x64"]}}'
if HOME="$scratch/home" PATH="$scratch/bin:$PATH" \
  chezmoi --config "$scratch/empty.toml" --source "$repo_root" --override-data "$malformed_data" \
    execute-template \
    <"$repo_root/.chezmoiscripts/30-windows/run_onchange_after_install-visual-studio.ps1.tmpl" \
    >"$scratch/malformed.ps1" 2>"$scratch/malformed.err"; then
  fail 'malformed workload ID rendered successfully'
fi
grep -F 'is not a valid Visual Studio component ID' "$scratch/malformed.err" >/dev/null || \
  fail 'malformed workload render did not report the schema violation'

DECLARED_CSV=$(IFS=,; printf '%s' "${DECLARED[*]}")
RENDERED_SCRIPTS="$scratch/visualstudio-amd64.ps1;$scratch/visualstudio-arm64.ps1" \
DECLARED_CSV="$DECLARED_CSV" FIXTURE_SCRATCH="$scratch" HOME="$scratch/home" TEMP="$scratch/temp" \
  pwsh -NoProfile -Command - <<'PS'
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-Fixture([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
}
function Assert-Sequence([object[]] $Actual, [object[]] $Expected, [string] $Label) {
    $actualText = @($Actual | ForEach-Object { "$_" }) -join "`n"
    $expectedText = @($Expected | ForEach-Object { "$_" }) -join "`n"
    if ($actualText -cne $expectedText) {
        throw "$Label mismatch. expected=[$($expectedText -replace "`n", '; ')] actual=[$($actualText -replace "`n", '; ')]"
    }
}
function New-FixtureInstance([string] $Path) {
    [pscustomobject]@{
        installationVersion = '18.2.0.0'
        productId = 'Microsoft.VisualStudio.Product.Community'
        installationPath = $Path
        channelId = 'VisualStudio.18.Release'
    }
}
function New-FixtureDiscovery([object[]] $Instances) {
    [pscustomobject]@{ Instances = @($Instances) }
}

try {
    $declaredAuthority = @($env:DECLARED_CSV -split ',')
    foreach ($renderedScript in @($env:RENDERED_SCRIPTS -split ';')) {
        $source = [IO.File]::ReadAllText($renderedScript)
        $tokens = $null
        $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref] $tokens, [ref] $parseErrors)
        if ($parseErrors.Count -ne 0) { throw "$renderedScript has parse errors: $parseErrors" }

        # The fixture seam is deliberately narrow: remove exactly the terminal
        # entrypoint statement, then load every rendered definition unchanged.
        $statements = @($ast.EndBlock.Statements)
        Assert-Fixture ($statements.Count -gt 0) "$renderedScript rendered no statements"
        $entrypoint = $statements[-1]
        Assert-Fixture ($entrypoint.Extent.Text.Trim() -ceq 'Invoke-VisualStudioConvergence') `
            "$renderedScript terminal statement is not the convergence entrypoint"
        Assert-Fixture ([string]::IsNullOrWhiteSpace($source.Substring($entrypoint.Extent.EndOffset))) `
            "$renderedScript contains content after its entrypoint"
        $definitions = $source.Remove(
            $entrypoint.Extent.StartOffset,
            $entrypoint.Extent.EndOffset - $entrypoint.Extent.StartOffset
        )
        . ([scriptblock]::Create($definitions))

        Assert-Sequence (@($VisualStudioWorkloads) + @($VisualStudioComponents)) $declaredAuthority `
            "$renderedScript runtime authority"

        $global:FixtureInstancePath = Join-Path $env:FIXTURE_SCRATCH 'existing-community'
        $global:FixtureInstallerRoot = Join-Path $env:FIXTURE_SCRATCH 'program-files-x86'
        ${env:ProgramFiles(x86)} = $global:FixtureInstallerRoot
        $global:FixtureSetupPath = Join-Path (Join-Path $global:FixtureInstallerRoot 'Microsoft Visual Studio\Installer') 'setup.exe'
        New-Item -ItemType Directory -Path $global:FixtureInstancePath -Force | Out-Null
        New-Item -ItemType Directory -Path (Split-Path -Parent $global:FixtureSetupPath) -Force | Out-Null
        Set-Content -LiteralPath $global:FixtureSetupPath -Value 'fixture setup executable'
        $global:FixtureInstance = New-FixtureInstance $global:FixtureInstancePath
        $missingVsWhere = Get-VisualStudioInstances -Product $VisualStudioProduct -VersionRange $VisualStudioVersionRange
        Assert-Fixture ($missingVsWhere.Instances.Count -eq 0) 'missing vswhere did not return an empty instance set'

        function Reset-Fixture {
            $global:FixtureAdmin = $true
            $global:FixturePendingReboot = $false
            $global:FixtureSetupExit = 0
            $global:FixtureDiscovery = [Collections.Generic.Queue[object]]::new()
            $global:FixtureDiscoveryCalls = [Collections.Generic.List[object]]::new()
            $global:FixtureSetupCalls = [Collections.Generic.List[object]]::new()
            $global:FixtureDownloadCalls = [Collections.Generic.List[object]]::new()
            $global:FixtureSignatureCalls = [Collections.Generic.List[string]]::new()
            $global:FixtureIdentityCalls = [Collections.Generic.List[string]]::new()
            $global:FixtureStagingRemovals = [Collections.Generic.List[string]]::new()
        }
        function Test-VisualStudioAdministrator { return $global:FixtureAdmin }
        function Test-VisualStudioPendingReboot { return $global:FixturePendingReboot }
        function Get-VisualStudioInstances {
            param([string] $Product, [string] $VersionRange, [string[]] $RequiredIds = @())
            $global:FixtureDiscoveryCalls.Add([pscustomobject]@{
                Product = $Product; VersionRange = $VersionRange; RequiredIds = @($RequiredIds)
            })
            if ($global:FixtureDiscovery.Count -eq 0) { throw 'fixture discovery response queue is empty' }
            return $global:FixtureDiscovery.Dequeue()
        }
        function New-VisualStudioBootstrapperStaging {
            $directory = Join-Path $env:FIXTURE_SCRATCH ([Guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $directory | Out-Null
            [pscustomobject]@{ Directory = $directory; BootstrapperPath = (Join-Path $directory 'vs_community.exe') }
        }
        function Invoke-VisualStudioBootstrapperDownload {
            param([string] $Uri, [string] $Destination)
            $global:FixtureDownloadCalls.Add([pscustomobject]@{ Uri = $Uri; Destination = $Destination })
            Set-Content -LiteralPath $Destination -Value 'fixture bootstrapper'
            [pscustomobject]@{ ResolvedUri = $Uri; Attempts = 1 }
        }
        function Assert-VisualStudioBootstrapperAuthenticode {
            param([string] $Path)
            $global:FixtureSignatureCalls.Add($Path)
            [pscustomobject]@{ SignerCertificate = [pscustomobject]@{ Thumbprint = 'FIXTURE' } }
        }
        function Assert-VisualStudioBootstrapperIdentity {
            param([string] $Path)
            $global:FixtureIdentityCalls.Add($Path)
        }
        function Invoke-VisualStudioSetup {
            param([string] $ExecutablePath, [string[]] $Arguments)
            $global:FixtureSetupCalls.Add([pscustomobject]@{
                ExecutablePath = $ExecutablePath; Arguments = @($Arguments)
            })
            [pscustomobject]@{ ExitCode = $global:FixtureSetupExit }
        }
        function Remove-VisualStudioBootstrapperStaging {
            param([string] $Directory)
            $global:FixtureStagingRemovals.Add($Directory)
            Remove-Item -LiteralPath $Directory -Recurse -Force -ErrorAction SilentlyContinue
        }

        $expectedAddArguments = @()
        foreach ($id in $declaredAuthority) { $expectedAddArguments += @('--add', $id) }
        $expectedInstallArguments = @('--passive', '--wait', '--norestart', '--includeRecommended') + $expectedAddArguments
        $expectedModifyArguments = @(
            'modify', '--installPath', $global:FixtureInstancePath,
            '--channelId', 'VisualStudio.18.Release'
        ) + $expectedAddArguments + @('--includeRecommended', '--passive', '--norestart')

        # Non-administrator preflight fails before discovery or mutation.
        Reset-Fixture
        $global:FixtureAdmin = $false
        try { Invoke-VisualStudioConvergence; throw 'non-administrator preflight was accepted' }
        catch {
            if ($_.Exception.Message -eq 'non-administrator preflight was accepted') { throw }
            Assert-Fixture ($_.Exception.Message -match 'elevated PowerShell') 'non-admin failure lacked its remediation'
        }
        Assert-Fixture ($global:FixtureDiscoveryCalls.Count -eq 0) 'non-admin preflight performed discovery'
        Assert-Fixture ($global:FixtureSetupCalls.Count -eq 0) 'non-admin preflight invoked setup'

        # Pending reboot also fails before discovery or mutation.
        Reset-Fixture
        $global:FixturePendingReboot = $true
        try { Invoke-VisualStudioConvergence; throw 'pending reboot preflight was accepted' }
        catch {
            if ($_.Exception.Message -eq 'pending reboot preflight was accepted') { throw }
            Assert-Fixture ($_.Exception.Message -match 'pending reboot') 'pending reboot failure lacked its remediation'
        }
        Assert-Fixture ($global:FixtureDiscoveryCalls.Count -eq 0) 'pending reboot preflight performed discovery'

        # Clean fresh install: vswhere exists but reports no instance.
        Reset-Fixture
        $global:FixtureDiscovery.Enqueue((New-FixtureDiscovery @()))
        $global:FixtureDiscovery.Enqueue((New-FixtureDiscovery @()))
        $global:FixtureDiscovery.Enqueue((New-FixtureDiscovery @($global:FixtureInstance)))
        Invoke-VisualStudioConvergence | Out-Null
        Assert-Fixture ($global:FixtureSetupCalls.Count -eq 1) 'fresh install did not invoke setup once'
        Assert-Fixture ($global:FixtureDownloadCalls.Count -eq 1) 'fresh install did not download once'
        Assert-Fixture ($global:FixtureSignatureCalls.Count -eq 1) 'fresh install did not verify Authenticode once'
        Assert-Fixture ($global:FixtureIdentityCalls.Count -eq 1) 'fresh install did not verify bootstrapper identity once'
        Assert-Sequence $global:FixtureSetupCalls[0].Arguments $expectedInstallArguments 'fresh bootstrapper arguments'
        Assert-Sequence $global:FixtureDiscoveryCalls[0].RequiredIds $declaredAuthority 'fresh compliance discovery IDs'
        Assert-Fixture ($global:FixtureStagingRemovals.Count -eq 1) 'fresh install did not clean staging'

        # An empty discovery response, including missing vswhere, enters fresh install.
        Reset-Fixture
        $global:FixtureDiscovery.Enqueue((New-FixtureDiscovery @()))
        $global:FixtureDiscovery.Enqueue((New-FixtureDiscovery @()))
        $global:FixtureDiscovery.Enqueue((New-FixtureDiscovery @($global:FixtureInstance)))
        Invoke-VisualStudioConvergence | Out-Null
        Assert-Fixture ($global:FixtureSetupCalls.Count -eq 1) 'missing vswhere did not take the fresh install path'
        Assert-Fixture ($global:FixtureDownloadCalls.Count -eq 1) 'missing vswhere did not use the bootstrapper'

        # Existing Community 18.x uses Installer setup.exe in additive modify mode.
        Reset-Fixture
        $global:FixtureDiscovery.Enqueue((New-FixtureDiscovery @()))
        $global:FixtureDiscovery.Enqueue((New-FixtureDiscovery @($global:FixtureInstance)))
        $global:FixtureDiscovery.Enqueue((New-FixtureDiscovery @($global:FixtureInstance)))
        Invoke-VisualStudioConvergence | Out-Null
        Assert-Fixture ($global:FixtureSetupCalls.Count -eq 1) 'existing instance did not invoke setup once'
        Assert-Fixture ($global:FixtureSetupCalls[0].ExecutablePath -ceq $global:FixtureSetupPath) 'modify used the wrong setup.exe'
        Assert-Sequence $global:FixtureSetupCalls[0].Arguments $expectedModifyArguments 'modify arguments'
        Assert-Fixture ($global:FixtureDownloadCalls.Count -eq 0) 'modify downloaded a bootstrapper'

        # All declared IDs already present: a single compliant query and no-op.
        Reset-Fixture
        $global:FixtureDiscovery.Enqueue((New-FixtureDiscovery @($global:FixtureInstance)))
        Invoke-VisualStudioConvergence | Out-Null
        Assert-Fixture ($global:FixtureDiscoveryCalls.Count -eq 1) 'all-present path queried more than once'
        Assert-Fixture ($global:FixtureSetupCalls.Count -eq 0) 'all-present path invoked setup'
        Assert-Fixture ($global:FixtureDownloadCalls.Count -eq 0) 'all-present path downloaded a bootstrapper'

        # Exit 3010 is successful with an explicit reboot warning.
        Reset-Fixture
        $global:FixtureSetupExit = 3010
        $global:FixtureDiscovery.Enqueue((New-FixtureDiscovery @()))
        $global:FixtureDiscovery.Enqueue((New-FixtureDiscovery @()))
        $global:FixtureDiscovery.Enqueue((New-FixtureDiscovery @($global:FixtureInstance)))
        $warningOutput = @(& { Invoke-VisualStudioConvergence } 3>&1)
        Assert-Fixture (($warningOutput | ForEach-Object { "$_" }) -match 'restart is required') 'exit 3010 emitted no reboot warning'

        # An unrelated setup failure is fatal and preserves its numeric exit.
        Reset-Fixture
        $global:FixtureSetupExit = 42
        $global:FixtureDiscovery.Enqueue((New-FixtureDiscovery @()))
        $global:FixtureDiscovery.Enqueue((New-FixtureDiscovery @()))
        try { Invoke-VisualStudioConvergence; throw 'fatal setup exit was accepted' }
        catch {
            if ($_.Exception.Message -eq 'fatal setup exit was accepted') { throw }
            Assert-Fixture ($_.Exception.Message -match 'exit code 42') 'fatal setup exit was not propagated'
        }

        # A successful setup is still failure when the declared postcondition is absent.
        Reset-Fixture
        $global:FixtureDiscovery.Enqueue((New-FixtureDiscovery @()))
        $global:FixtureDiscovery.Enqueue((New-FixtureDiscovery @()))
        $global:FixtureDiscovery.Enqueue((New-FixtureDiscovery @()))
        try { Invoke-VisualStudioConvergence; throw 'missing postcondition was accepted' }
        catch {
            if ($_.Exception.Message -eq 'missing postcondition was accepted') { throw }
            Assert-Fixture ($_.Exception.Message -match 'postcondition failed') 'missing postcondition lacked a precise failure'
        }

        # Runtime validation independently rejects invalid scalar and list authority.
        try {
            Assert-VisualStudioAuthority -Product 'Microsoft.VisualStudio.Product.Enterprise' `
                -VersionRange '[18.0,19.0)' -BootstrapperUrl 'https://aka.ms/vs/stable/vs_community.exe' `
                -Workloads @('Microsoft.VisualStudio.Workload.NativeDesktop') `
                -Components @('Microsoft.VisualStudio.Component.VC.Tools.x86.x64')
            throw 'invalid runtime scalar authority was accepted'
        } catch {
            if ($_.Exception.Message -eq 'invalid runtime scalar authority was accepted') { throw }
            Assert-Fixture ($_.Exception.Message -match 'invalid product') 'invalid runtime scalar failure was imprecise'
        }
        try {
            Assert-VisualStudioAuthority -Product 'Microsoft.VisualStudio.Product.Community' `
                -VersionRange '[18.0,19.0)' -BootstrapperUrl 'https://aka.ms/vs/stable/vs_community.exe' `
                -Workloads @('not-a-visual-studio-id') `
                -Components @('Microsoft.VisualStudio.Component.VC.Tools.x86.x64')
            throw 'invalid runtime list authority was accepted'
        } catch {
            if ($_.Exception.Message -eq 'invalid runtime list authority was accepted') { throw }
            Assert-Fixture ($_.Exception.Message -match 'not a valid Visual Studio component ID') 'invalid runtime list failure was imprecise'
        }
    }
} catch {
    Write-Host "FIXTURE FAILED: $($_.Exception.Message)"
    exit 1
}
exit 0
PS

printf '%s\n' 'visual studio provisioner fixture passed'
