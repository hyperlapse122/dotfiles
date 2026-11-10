/*
  Check interface:

    import ./tests/host-name-guard.nix { inherit pkgs self; }

  Fails when a host name appears in the repository's code: `flake.nix`,
  `lib/`, `modules/`, `home/`, `tests/`, `scripts/`, `packages/`, and
  `.github/workflows/`. Host names come from the directories under `hosts/`
  and the fixture hosts under `tests/fixtures/hosts/`, so the list is never
  written out here. `hosts/`, `secrets/`, `docs/`, and the top-level prose
  files are not scanned.

  The search is a case-insensitive fixed-string match on the full host name,
  so prose that uses part of a name, such as a vendor or model, stays legal.
  The builder lists every `file:line` hit before it fails, and it also fails
  when no host is discovered or a scanned path is missing, so it never passes
  vacuously.
*/
{ pkgs, self }:
let
  inherit (pkgs) lib;

  directoriesIn = import ./lib/directories.nix { inherit lib; };

  # Fixture hosts stand in for real ones in checks, so their names stay out of
  # code for the same reason.
  hostNames = directoriesIn ../hosts ++ directoriesIn ./fixtures/hosts;

  scannedPaths = [
    "flake.nix"
    "lib"
    "modules"
    "home"
    "tests"
    "scripts"
    "packages"
    ".github/workflows"
  ];

  patterns = pkgs.writeText "host-name-guard-patterns" (
    lib.concatMapStrings (name: "${name}\n") hostNames
  );
in
pkgs.runCommand "host-name-guard-tests" { nativeBuildInputs = [ pkgs.gnugrep ]; } ''
  cd ${self}

  if [ ${toString (builtins.length hostNames)} -eq 0 ]; then
    echo "host-name-guard: no host directories discovered under hosts/" >&2
    exit 1
  fi

  for path in ${lib.escapeShellArgs scannedPaths}; do
    if [ ! -e "$path" ]; then
      echo "host-name-guard: scanned path $path is missing from the flake source" >&2
      exit 1
    fi
  done

  status=0
  grep -rnIiF -f ${patterns} -- ${lib.escapeShellArgs scannedPaths} > "$TMPDIR/hits" || status=$?

  if [ "$status" -eq 0 ]; then
    echo "host-name-guard: host names found in scanned code paths:" >&2
    cat "$TMPDIR/hits" >&2
    echo "A host directory name is the machine's distinctive model identifier and must not appear as a substring in ${lib.concatStringsSep ", " scannedPaths}. Branch on a trait (my.*.enable) or my.bootstrap instead, and keep host names in hosts/ and secrets/bootstrap/." >&2
    exit 1
  fi

  if [ "$status" -ne 1 ]; then
    echo "host-name-guard: grep failed with status $status" >&2
    exit 1
  fi

  touch $out
''
