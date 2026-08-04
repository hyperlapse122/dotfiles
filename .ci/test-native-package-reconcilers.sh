#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
scratch_root="${XDG_RUNTIME_DIR:-$HOME/.cache}/agent-scratch"
mkdir -p "$scratch_root"
scratch=$(mktemp -d "$scratch_root/native-packages.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
mkdir -p "$scratch/bin"
printf '#!/usr/bin/env bash\nprintf dummy-secret\n' >"$scratch/bin/op"
chmod 700 "$scratch/bin/op"
printf '[data]\n' >"$scratch/empty.toml"

render() {
  local os=$1 arch=$2 template=$3 output=$4
  PATH="$scratch/bin:$PATH" chezmoi --config "$scratch/empty.toml" --source "$repo_root" \
    --override-data "{\"chezmoi\":{\"os\":\"$os\",\"arch\":\"$arch\"}}" \
    execute-template <"$repo_root/$template" >"$output"
}
fail() { printf 'native package reconcilers: %s\n' "$*" >&2; exit 1; }
requires() { grep -F -- "$2" "$1" >/dev/null || fail "$1 is missing: $2"; }

render windows amd64 .chezmoiscripts/20-windows/run_onchange_before_winget.ps1.tmpl "$scratch/winget-x64.ps1"
render windows arm64 .chezmoiscripts/20-windows/run_onchange_before_winget.ps1.tmpl "$scratch/winget-arm64.ps1"
render darwin arm64 .chezmoiscripts/20-darwin/run_onchange_before_homebrew.sh.tmpl "$scratch/homebrew.sh"
bash -n "$scratch/homebrew.sh"
SCRIPT_PATH="$scratch/winget-x64.ps1" pwsh -NoProfile -Command '[void][scriptblock]::Create([IO.File]::ReadAllText($env:SCRIPT_PATH))'
# Exercise the native Invoke-Winget contract without touching App Installer:
# extract only that rendered function, inject a PowerShell winget function,
# and prove repeated no-update applies converge while an unrelated failure
# remains fatal.
WINGET_SCRIPT="$scratch/winget-x64.ps1" pwsh -NoProfile -Command - <<'PS'
$ErrorActionPreference = 'Stop'
$source = [IO.File]::ReadAllText($env:WINGET_SCRIPT)
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$errors)
if ($errors.Count -ne 0) { throw "rendered winget script has parse errors: $errors" }
$functionAst = $ast.Find({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-Winget'
}, $true)
if ($null -eq $functionAst) { throw 'Invoke-Winget was not rendered' }
. ([scriptblock]::Create($functionAst.Extent.Text))

$global:FixtureWingetExit = -1978335189
function global:winget {
    $global:LASTEXITCODE = $global:FixtureWingetExit
}
1..2 | ForEach-Object {
    $result = Invoke-Winget -Arguments @('upgrade', '--id', 'Fixture.Package') `
        -AcceptedExitCodes @(0, -1978335189)
    if ($result.ExitCode -ne -1978335189) { throw "apply $_ did not preserve the converged HRESULT" }
}
$global:FixtureWingetExit = 42
try {
    Invoke-Winget -Arguments @('upgrade', '--id', 'Fixture.Package') `
        -AcceptedExitCodes @(0, -1978335189) | Out-Null
    throw 'unrelated nonzero winget exit was accepted'
} catch {
    if ($_.Exception.Message -eq 'unrelated nonzero winget exit was accepted') { throw }
    if ($_.Exception.Message -notmatch 'exit code 42') { throw }
}
PS

requires "$scratch/winget-x64.ps1" "'--exact', '--id', \$row.Id, '--source', 'winget'"
requires "$scratch/winget-x64.ps1" "--accept-package-agreements"
requires "$scratch/winget-x64.ps1" "--accept-source-agreements"
requires "$scratch/winget-x64.ps1" "--disable-interactivity"
requires "$scratch/winget-x64.ps1" 'https://cdn.winget.microsoft.com/cache'
requires "$scratch/winget-x64.ps1" "RESULT \$(\$row.Id)"
requires "$scratch/winget-arm64.ps1" "Architecture = 'x64'"
requires "$scratch/winget-arm64.ps1" "Architecture = 'arm64'"
requires "$scratch/winget-arm64.ps1" "Id = 'CiderCollective.Cider'"

requires "$scratch/homebrew.sh" '39a0c068274254a7658fd9761d59bce9d0e2151f/install.sh'
requires "$scratch/homebrew.sh" '8ff338091a5e10bb5fc040b38316648110f42feff057ecf9feaab51fd0a13ef9'
requires "$scratch/homebrew.sh" 'brew bundle --file="$brewfile"'
requires "$scratch/homebrew.sh" 'brew bundle check --verbose --file="$brewfile"'
requires "$scratch/homebrew.sh" 'greedy: true'
if grep -E '^(mas|whalebrew|vscode) ' "$scratch/homebrew.sh" >/dev/null; then
  fail 'Brewfile emitted an unsupported entry kind'
fi

# Missing App Management permission must fail before any package-manager call.
manager_log="$scratch/manager.log"
cat >"$scratch/bin/brew" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$MANAGER_LOG"
exit 0
SH
chmod 700 "$scratch/bin/brew"
if MANAGER_LOG="$manager_log" PATH="$scratch/bin:$PATH" bash "$scratch/homebrew.sh" >"$scratch/preflight.out" 2>"$scratch/preflight.err"; then
  fail 'missing App Management permission was accepted'
fi
grep -F 'named human step required' "$scratch/preflight.err" >/dev/null || {
  cat "$scratch/preflight.err" >&2
  fail 'permission failure lacks a named human step'
}
[[ ! -e "$manager_log" ]] || fail 'Homebrew ran before authorization preflight completed'
printf '%s\n' 'native package reconciler validation passed'
