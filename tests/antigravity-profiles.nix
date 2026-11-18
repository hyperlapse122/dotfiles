/*
  Check the Antigravity CLI and retired ACP executables in the materialized
  Home Manager user profiles. Native Darwin builds check the same boundary
  through tests/darwin-outputs.nix.
*/
{
  pkgs,
  self,
  fixtures,
}:
let
  inherit (pkgs) lib;

  configurations = import ./lib/configurations.nix { inherit pkgs self fixtures; };
  agy = "${import ../packages/antigravity-cli.nix { inherit pkgs; }}/bin/agy";

  esc = value: lib.escapeShellArg (toString value);
  assertEntry = entry: ''
    checkUser ${esc entry.name} ${esc (entry.user.home.path or "")}
  '';
in
pkgs.runCommand "antigravity-profiles-tests" { } ''
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

    [ "$(readlink -f "$homePath/bin/agy" || true)" = ${agy} ] \
      || fail "agy on PATH is not the pinned Antigravity CLI"
    for binary in agy_acp_server.par localharness_external; do
      [ ! -e "$homePath/bin/$binary" ] && [ ! -L "$homePath/bin/$binary" ] \
        || fail "retired Antigravity runtime executable $binary is on PATH"
    done
  )

  ${lib.concatMapStringsSep "\n" assertEntry configurations.userEntries}

  if [ -s "$failures" ]; then
    cat "$failures" >&2
    exit 1
  fi
  touch $out
''
