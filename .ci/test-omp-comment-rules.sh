#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
rules_dir="$repo_root/dot_omp/private_agent/rules"
fixtures_dir="$repo_root/.ci/fixtures/comment-checker"
locked_version=$(jq -er '.releases.tools.omp.version | sub("^v"; "")' "$repo_root/.chezmoidata/releases.json")
actual_version=$(omp --version)
[[ $actual_version == "omp/$locked_version" ]] || {
  printf 'expected omp/%s, got %s\n' "$locked_version" "$actual_version" >&2
  exit 1
}

scratch_root=${XDG_RUNTIME_DIR:-"$HOME/.cache"}/omp-comment-rules
mkdir -p -- "$scratch_root"
chmod 0700 -- "$scratch_root"
scratch=$(mktemp -d "$scratch_root/run.XXXXXX")
cleanup() { rm -rf -- "$scratch"; }
trap cleanup EXIT

fail() {
  printf 'comment-rule test failed: %s\n' "$*" >&2
  exit 1
}

run_case() {
  local label=$1 rule=$2 file=$3 source=$4 tool=$5 path=$6 expected=$7 output count
  if [[ $source == tool ]]; then
    output=$(omp ttsr test --rule "$rule" --file "$file" --source tool --tool "$tool" --path "$path" --json)
  else
    output=$(omp ttsr test --rule "$rule" --file "$file" --source "$source" --path "$path" --json)
  fi
  count=$(jq -er '.triggered | length' <<<"$output")
  if [[ $expected == trigger ]]; then
    [[ $count -gt 0 ]] || fail "$label did not trigger"
    jq -r '.triggered[].defined.regex[]?' <<<"$output" >>"$scratch/defined.$(basename "$rule")"
    jq -r '.triggered[].matched.regex[]?' <<<"$output" >>"$scratch/matched.$(basename "$rule")"
  else
    [[ $count -eq 0 ]] || fail "$label triggered unexpectedly"
  fi
}

run_snippet() {
  local label=$1 rule=$2 snippet=$3 source=$4 tool=$5 path=$6 expected=$7 file="$scratch/snippet"
  printf '%s\n' "$snippet" >"$file"
  run_case "$label" "$rule" "$file" "$source" "$tool" "$path" "$expected"
}

rule() { printf '%s/readonly_comment-%s.md' "$rules_dir" "$1"; }
fixture() { printf '%s/%s/%s' "$fixtures_dir" "$1" "$2"; }

for family in c-family hash dash html ocaml python-docstring; do
  [[ -f $(rule "$family") ]] || fail "missing $family rule"
done

run_case 'c line write' "$(rule c-family)" "$(fixture c-family trigger-line.ts)" tool write trigger-line.ts trigger
run_case 'c line edit' "$(rule c-family)" "$(fixture c-family trigger-line.ts)" tool edit trigger-line.ts trigger
run_case 'c block' "$(rule c-family)" "$(fixture c-family trigger-block.css)" tool write trigger-block.css trigger
run_case 'hash trigger' "$(rule hash)" "$(fixture hash trigger-todo.py)" tool write trigger-todo.py trigger
run_case 'dash line' "$(rule dash)" "$(fixture dash trigger-line.lua)" tool write trigger-line.lua trigger
run_case 'dash SQL block' "$(rule dash)" "$(fixture dash trigger-block.sql)" tool write trigger-block.sql trigger
run_case 'dash Elm block' "$(rule dash)" "$(fixture dash trigger-elm.elm)" tool write trigger-elm.elm trigger
run_case 'HTML trigger' "$(rule html)" "$(fixture html trigger-todo.html)" tool write trigger-todo.html trigger
run_case 'OCaml trigger' "$(rule ocaml)" "$(fixture ocaml trigger-todo.ml)" tool write trigger-todo.ml trigger
run_case 'docstring trigger' "$(rule python-docstring)" "$(fixture python-docstring trigger-docstring.py)" tool write trigger-docstring.py trigger

# Every declared path alias must admit the syntax family it belongs to under
# both tool scopes, edit and write. Python, PHP, and Svelte deliberately appear
# in two family rows and are tested twice.
declare -A aliases=(
  [c-family]='js jsx ts tsx go java kt scala c h cpp cc cxx hpp rs cs swift proto groovy cue php svelte css'
  [hash]='py rb sh bash yaml yml toml hcl tf Dockerfile ex exs php'
  [dash]='lua sql elm'
  [html]='html htm svelte'
  [ocaml]='ml mli'
  [python-docstring]='py'
)
declare -A scope_fixture=(
  [c-family]='c-family/trigger-line.ts'
  [hash]='hash/trigger-todo.py'
  [dash]='dash/trigger-line.lua'
  [html]='html/trigger-todo.html'
  [ocaml]='ocaml/trigger-todo.ml'
  [python-docstring]='python-docstring/trigger-docstring.py'
)
for family in "${!aliases[@]}"; do
  for alias in ${aliases[$family]}; do
    if [[ $alias == Dockerfile ]]; then
      path=Dockerfile
    else
      path="scope.$alias"
    fi
    for tool in write edit; do
      run_case "$family scope $alias $tool" "$(rule "$family")" "$fixtures_dir/${scope_fixture[$family]}" tool "$tool" "$path" trigger
    done
  done
done

# Scope must be limited to tool edits and writes, not ordinary text or thinking.
run_case 'text source scope' "$(rule c-family)" "$(fixture c-family trigger-line.ts)" text '' trigger-line.ts pass
run_case 'thinking source scope' "$(rule c-family)" "$(fixture c-family trigger-line.ts)" thinking '' trigger-line.ts pass
run_case 'wrong path scope' "$(rule c-family)" "$(fixture c-family trigger-line.ts)" tool write fixture.py pass

# Exceptions are checked through the production TTSR matcher, not a copied
# regex. Every family shares one exception vocabulary and every condition is
# case-insensitive, so an alias and its case variants must behave identically.
# The `givenup` row proves the alias boundary itself is still enforced.
for family in c-family hash dash html ocaml python-docstring; do
  case $family in
    c-family) marker='//'; suffix=''; path='case.ts' ;;
    hash) marker='#'; suffix=''; path='case.py' ;;
    dash) marker='--'; suffix=''; path='case.sql' ;;
    html) marker='<!--'; suffix=' -->'; path='case.html' ;;
    ocaml) marker='(*'; suffix=' *)'; path='case.ml' ;;
    python-docstring) marker='"""'; suffix='"""'; path='case.py' ;;
  esac
  run_snippet "$family BDD" "$(rule "$family")" "$marker given a user$suffix" tool write "$path" pass
  run_snippet "$family BDD uppercase" "$(rule "$family")" "$marker GIVEN a user$suffix" tool write "$path" pass
  run_snippet "$family BDD mixed case" "$(rule "$family")" "$marker When&Then it works$suffix" tool write "$path" pass
  run_snippet "$family directive" "$(rule "$family")" "$marker @noqa$suffix" tool write "$path" pass
  run_snippet "$family directive uppercase" "$(rule "$family")" "$marker @NOQA$suffix" tool write "$path" pass
  run_snippet "$family type directive mixed case" "$(rule "$family")" "$marker Type: ignore$suffix" tool write "$path" pass
  run_snippet "$family ts directive uppercase" "$(rule "$family")" "$marker TS-Expect-Error$suffix" tool write "$path" pass
  run_snippet "$family alias boundary" "$(rule "$family")" "$marker givenup the ghost$suffix" tool write "$path" trigger
done
run_snippet 'hash shebang' "$(rule hash)" '#!/usr/bin/env bash' tool write case.sh pass
run_snippet 'C Go build directive' "$(rule c-family)" '//go:build linux' tool write case.go pass
run_snippet 'C nolint directive' "$(rule c-family)" '//nolint' tool write case.go pass
run_snippet 'C scheme URL' "$(rule c-family)" 'const url = "https://example.com";' tool write case.ts pass
run_snippet 'C protocol-relative URL' "$(rule c-family)" 'const url = "//cdn.example.com/x";' tool write case.ts pass
run_snippet 'C CSS protocol-relative URL' "$(rule c-family)" 'a { background: url(//cdn.example.com/x); }' tool write case.css pass
run_snippet 'hash fragment URL' "$(rule hash)" 'page.html#section' tool write case.py pass
run_snippet 'docstring assignment' "$(rule python-docstring)" 'QUERY = """select 1"""' tool write case.py pass

# Empty line comments are violations too.
run_snippet 'empty C comment' "$(rule c-family)" '//' tool write case.ts trigger
run_snippet 'empty hash comment' "$(rule hash)" '#' tool write case.py trigger
run_snippet 'empty dash comment' "$(rule dash)" '--' tool write case.sql trigger

# Registration can silently drop one invalid condition. Require every declared
# condition to have matched at least one trigger fixture.
for rule_file in "$rules_dir"/*.md; do
  name=$(basename "$rule_file")
  sort -u "$scratch/defined.$name" >"$scratch/defined.sorted"
  sort -u "$scratch/matched.$name" >"$scratch/matched.sorted"
  diff -u "$scratch/defined.sorted" "$scratch/matched.sorted"
done

# Installed rules must be discovered from the deployed location, not only via
# --rule. chezmoi strips the readonly_ attribute prefix, so deploy the rules
# under their target names into an isolated HOME and exercise discovery with
# omp ttsr test invocations that pass no --rule at all.
deployed_home="$scratch/deployed-home"
mkdir -p -- "$deployed_home/.omp/agent/rules" "$deployed_home/project"
for rule_file in "$rules_dir"/readonly_comment-*.md; do
  deployed_name=$(basename "$rule_file")
  deployed_name=${deployed_name#readonly_}
  cp -- "$rule_file" "$deployed_home/.omp/agent/rules/$deployed_name"
done

deployed_omp() {
  env -u PI_CODING_AGENT_DIR -u OMP_AGENT_ENV \
    HOME="$deployed_home" USERPROFILE="$deployed_home" \
    XDG_CONFIG_HOME="$deployed_home/.config" XDG_DATA_HOME="$deployed_home/.local/share" \
    omp "$@"
}

deployed_rules=$(cd "$deployed_home/project" && deployed_omp ttsr list --json)
for family in c-family hash dash html ocaml python-docstring; do
  jq -e --arg name "comment-$family" '.[] | select(.provider == "native" and .name == $name)' \
    <<<"$deployed_rules" >/dev/null || fail "deployed comment-$family rule not discovered"
done

run_deployed() {
  local label=$1 family=$2 file=$3 tool=$4 path=$5 expected=$6 output provider
  output=$(cd "$deployed_home/project" \
    && deployed_omp ttsr test --file "$file" --source tool --tool "$tool" --path "$path" --json)
  provider=$(jq -r --arg want "comment-$family" \
    '[.triggered[] | select(.name == $want) | .sourceProvider] | first // ""' <<<"$output")
  if [[ $expected == trigger ]]; then
    [[ $provider == native ]] || fail "$label did not trigger the deployed comment-$family rule"
  else
    [[ -z $provider ]] || fail "$label triggered the deployed comment-$family rule unexpectedly"
  fi
}

run_deployed 'deployed c-family' c-family "$(fixture c-family trigger-line.ts)" write trigger-line.ts trigger
run_deployed 'deployed hash' hash "$(fixture hash trigger-todo.py)" edit trigger-todo.py trigger
run_deployed 'deployed dash' dash "$(fixture dash trigger-line.lua)" write trigger-line.lua trigger
run_deployed 'deployed html' html "$(fixture html trigger-todo.html)" write trigger-todo.html trigger
run_deployed 'deployed ocaml' ocaml "$(fixture ocaml trigger-todo.ml)" write trigger-todo.ml trigger
run_deployed 'deployed docstring' python-docstring "$(fixture python-docstring trigger-docstring.py)" write trigger-docstring.py trigger
run_deployed 'deployed docstring scope' python-docstring "$(fixture python-docstring trigger-docstring.py)" write trigger-docstring.rb pass

# Query the immutable bundled registry once; the six checks retain distinct failures.
registered_rules="$(omp ttsr list --json)"

# Validate the registry schema before the collision checks consume it, so a
# renamed or dropped field fails here instead of passing vacuously below.
jq -e '
  type == "array"
  and length > 0
  and all(.[]; (.name | type) == "string" and (.provider | type) == "string")
  and any(.[]; .provider == "builtin-defaults")
' <<<"$registered_rules" >/dev/null || fail 'omp ttsr list --json schema changed'

for name in comment-c-family comment-hash comment-dash comment-html comment-ocaml comment-python-docstring; do
  if jq -e --arg name "$name" '.[] | select(.provider == "builtin-defaults" and .name == $name)' <<<"$registered_rules" >/dev/null; then
    fail "bundled rule shadows $name"
  fi
done

printf 'omp comment rule tests passed\n'
