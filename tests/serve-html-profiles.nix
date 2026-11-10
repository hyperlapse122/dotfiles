/*
  Check interface:

    import ./tests/serve-html-profiles.nix { inherit pkgs self fixtures; }

  Asserts that `serve-html`, the command the shared agent instructions tell
  agents under T3 Code to open local HTML with, is on PATH for every Home
  Manager user `tests/lib/configurations.nix` yields (NixOS and non-NixOS
  hosts, production and bootstrap alike), by reading each user's built
  home.path rather than the home.packages option. tests/test_serve_html.py
  covers what the helper does; this check proves the profile holds it.

  macOS users are covered by tests/darwin-outputs.nix, which only a macOS
  builder can build.

  Every lookup carries an `or` fallback so a mutation that removes the package,
  from the profile or from packages/agent-tools.nix, reaches the builder as a
  failing assertion rather than an evaluation error. The check also runs the
  profile's command with an empty environment, so a packaged script whose
  interpreter line was not rewritten into the store fails here.
*/
{
  pkgs,
  self,
  fixtures,
}:
let
  inherit (pkgs) lib;

  configurations = import ./lib/configurations.nix { inherit pkgs self fixtures; };

  package = (import ../packages/agent-tools.nix { inherit pkgs; }).serveHtml or null;
  helper = lib.optionalString (package != null) (lib.getExe package);

  esc = value: lib.escapeShellArg (toString value);

  assertEntry = entry: ''
    checkUser ${esc entry.name} ${esc (entry.user.home.path or "")}
  '';
in
pkgs.runCommand "serve-html-profiles-tests" { } ''
  ${configurations.userGuard}
  failures=$PWD/failures
  : > "$failures"
  ${lib.optionalString (helper == "") ''
    echo "packages/agent-tools.nix exports no serveHtml" >> "$failures"
  ''}

  checkUser() (
    user=$1 homePath=$2
    fail() { echo "$user: $*" >> "$failures"; }

    if [ -z "$homePath" ] || [ ! -d "$homePath/bin" ]; then
      fail "home-manager renders no home.path"
      exit
    fi
    command=$homePath/bin/serve-html
    if [ ! -x "$command" ]; then
      fail "no executable serve-html on PATH"
    elif [ "$(readlink -f "$command")" != ${esc helper} ]; then
      fail "serve-html resolves to $(readlink -f "$command"), not the packaged helper"
    elif ! env -i "$command" --help > /dev/null 2>&1; then
      fail "serve-html does not run with an empty environment"
    fi
  )

  ${lib.concatMapStringsSep "\n" assertEntry configurations.userEntries}

  if [ -s "$failures" ]; then
    cat "$failures" >&2
    exit 1
  fi
  touch $out
''
