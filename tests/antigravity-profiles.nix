/*
  Check interface:

    import ./tests/antigravity-profiles.nix { inherit pkgs self fixtures; }

  Asserts that every Home Manager user `tests/lib/configurations.nix` yields
  (NixOS and non-NixOS hosts, production and bootstrap alike) has the
  Antigravity CLI and the Antigravity ACP runtime on PATH, by reading each
  user's built home.path rather than the home.packages option:

  - bin/agy resolves to packages/antigravity-cli.nix, built from its pin;
  - bin/agy_acp_server.par execs the runtime built from
    packages/antigravity-acp-release.json, never T3 Code's pin, and links
    into Compound Engineering run homes exactly the skills the user's
    home-files puts in ~/.gemini/antigravity-cli/skills, the pinned Compound
    Engineering skills (ce-plan among them) included;
  - bin/localharness_external, beside it, is that runtime's executable helper.

  tests/antigravity-acp-path.nix runs the wrapper itself. macOS users are
  covered by tests/darwin-outputs.nix, which only a macOS builder can build.
  Every lookup carries an `or` fallback so a mutation that removes a package
  reaches the builder as a failing assertion rather than an evaluation error.
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
  runtimeDir = "${
    import ../packages/antigravity-acp.nix {
      inherit pkgs;
      pins = (builtins.fromJSON (builtins.readFile ../packages/antigravity-acp-release.json)).platforms;
    }
  }/libexec/antigravity-acp";

  esc = value: lib.escapeShellArg (toString value);

  assertEntry = entry: ''
    checkUser ${esc entry.name} ${esc (entry.user.home.path or "")} ${esc (entry.user.home-files or "")}
  '';
in
pkgs.runCommand "antigravity-profiles-tests" { } ''
  ${configurations.userGuard}
  failures=$PWD/failures
  : > "$failures"

  checkUser() (
    user=$1 homePath=$2 homeFiles=$3
    fail() { echo "$user: $*" >> "$failures"; }

    if [ -z "$homePath" ] || [ ! -d "$homePath/bin" ]; then
      fail "home-manager renders no home.path"
      exit
    fi

    [ "$(readlink -f "$homePath/bin/agy" || true)" = ${agy} ] \
      || fail "agy on PATH is not the pinned Antigravity CLI"

    helper=$homePath/bin/localharness_external
    if [ ! -x "$helper" ]; then
      fail "no executable localharness_external beside agy_acp_server.par"
    elif [ "$(readlink -f "$helper")" != ${runtimeDir}/localharness_external ]; then
      fail "localharness_external resolves to $(readlink -f "$helper"), not the PATH-pinned runtime"
    fi

    par=$homePath/bin/agy_acp_server.par
    if [ ! -x "$par" ]; then
      fail "no executable agy_acp_server.par on PATH"
      exit
    fi
    wrapper=$(readlink -f "$par")
    grep -qxF 'exec ${runtimeDir}/agy_acp_server.par "$@"' "$wrapper" \
      || fail "agy_acp_server.par does not exec the PATH-pinned runtime's .par"

    skillsDir=$homeFiles/.gemini/antigravity-cli/skills
    if [ -z "$homeFiles" ] || [ ! -d "$skillsDir" ]; then
      fail "home-files has no .gemini/antigravity-cli/skills"
      exit
    fi
    work=$(mktemp -d)
    ls -A "$skillsDir" | sort > "$work/linked"
    loops=$(grep -cE '^ *for skill in .*; do$' "$wrapper" || true)
    if [ "$loops" != 1 ]; then
      fail "agy_acp_server.par has $loops skill loops, not 1"
      exit
    fi
    loop=$(grep -E '^ *for skill in .*; do$' "$wrapper")
    loop=''${loop#*for skill in }
    eval "set -- ''${loop%; do}"
    printf '%s\n' "$@" | sort > "$work/wrapper"
    cmp -s "$work/linked" "$work/wrapper" \
      || fail "agy_acp_server.par links other skills than ~/.gemini/antigravity-cli/skills holds: $(diff "$work/linked" "$work/wrapper" | grep '^[<>]' | tr '\n' ' ')"
    grep -qx ce-plan "$work/wrapper" \
      || fail "agy_acp_server.par does not link the Compound Engineering skill ce-plan"
  )

  ${lib.concatMapStringsSep "\n" assertEntry configurations.userEntries}

  if [ -s "$failures" ]; then
    cat "$failures" >&2
    exit 1
  fi
  touch $out
''
