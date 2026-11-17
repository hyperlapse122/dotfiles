/*
  Check interface:

    import ./tests/acpx-delivery.nix { inherit pkgs self fixtures; }

  Asserts that `acpx` is on PATH for every Home Manager user
  `tests/lib/configurations.nix` yields (NixOS production and bootstrap
  outputs), by reading each user's built `home.path` rather than the
  `home.packages` option. Package config-bypass and version sanity belong to
  `packages/acpx.nix` `postInstallCheck` (`tests/acpx-config.sh`); this check
  proves the profile holds the binary and runs it with an empty environment.

  macOS users are covered by `tests/darwin-outputs.nix`, which only a macOS
  builder can build.

  Every lookup carries an `or` fallback so a mutation that drops the package
  from the profile reaches the builder as a failing assertion rather than an
  evaluation error.
*/
{
  pkgs,
  self,
  fixtures,
}:
let
  inherit (pkgs) lib;

  configurations = import ./lib/configurations.nix { inherit pkgs self fixtures; };

  package = import ../packages/acpx.nix { inherit pkgs; };
  binary = lib.getExe package;

  esc = value: lib.escapeShellArg (toString value);

  assertEntry = entry: ''
    checkUser ${esc entry.name} ${esc (entry.user.home.path or "")}
  '';
in
pkgs.runCommand "acpx-delivery-tests" { } ''
  ${configurations.userGuard}
  failures=$PWD/failures
  : > "$failures"

  checkUser() (
    user=$1 homePath=$2
    fail() { echo "$user: $*" >> "$failures"; }

    if [ -z "$homePath" ] || [ ! -d "$homePath/bin" ]; then
      fail "home-manager renders no home.path"
      exit
    fi
    command=$homePath/bin/acpx
    if [ ! -x "$command" ]; then
      fail "no executable acpx on PATH"
    elif [ "$(readlink -f "$command")" != ${esc binary} ]; then
      fail "acpx resolves to $(readlink -f "$command"), not the packaged acpx"
    elif ! env -i "$command" --version > /dev/null 2>&1; then
      fail "acpx does not run with an empty environment"
    fi
  )

  ${lib.concatMapStringsSep "\n" assertEntry configurations.userEntries}

  if [ -s "$failures" ]; then
    cat "$failures" >&2
    exit 1
  fi
  touch $out
''
