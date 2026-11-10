/*
  Check interface:

    import ./tests/retire-orca.nix { inherit pkgs self; }

  Runs every Home Manager user environment's materialized
  home.activation.retireOrca block, with the packaged helper it calls, against
  seeded scratch homes (tests/test_retire_orca.py): Orca's hooks, Claude
  status line, Antigravity hook, Codex hook trust entries, and state
  directories go, everything other tools wrote beside them stays, a second run
  changes nothing, and a malformed file is left alone without failing the
  apply. The macOS variant, which also clears ~/Library, runs in
  tests/darwin-outputs.nix on a macOS builder.
*/
{ pkgs, self }:
let
  inherit (pkgs) lib;

  configurations = import ./lib/configurations.nix { inherit pkgs self; };

  assertUser =
    entry:
    let
      activation = entry.user.home.activation.retireOrca or null;
      block = pkgs.writeText "retire-orca-block-${entry.name}.sh" (activation.data or "");
    in
    if activation == null then
      ''
        echo 'missing home.activation.retireOrca on ${entry.name}' >&2
        failed=1
      ''
    else
      ''
        python3 ${./test_retire_orca.py} ${block} 0 || {
          echo 'the retireOrca activation on ${entry.name} failed its contract' >&2
          failed=1
        }
      '';
in
pkgs.runCommand "retire-orca-tests" { nativeBuildInputs = [ pkgs.python3 ]; } ''
  export PYTHONDONTWRITEBYTECODE=1
  ${configurations.userGuard}
  failed=0

  ${lib.concatMapStringsSep "\n" assertUser configurations.userEntries}

  [ "$failed" = 0 ] || exit 1
  touch $out
''
