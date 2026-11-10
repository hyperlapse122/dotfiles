/*
  Check interface:

    import ./tests/session-variables.nix { inherit pkgs self fixtures; }

  Asserts that every configuration renders the Testcontainers, Turborepo, and
  telemetry opt-out session variables into both files that carry the h82
  session environment: the Home Manager hm-session-vars.sh that login shells
  source, and ~/.config/environment.d/10-home-manager.conf that the systemd
  user manager reads.

  Verifies, on every Home Manager user `tests/lib/configurations.nix` yields
  (NixOS and non-NixOS hosts, production and bootstrap alike):
  - the h82 Home Manager generation exists.
  - environment.d/10-home-manager.conf is materialized in the generation's
    home-files, so a disabled or retargeted entry fails here rather than
    passing on its option text.
  - each file carries every expected variable as a whole line, so a longer
    value cannot satisfy the assertion.
  - each file carries exactly one CROSS_MODEL_PEERS value, joined with `,`
    alone, whose tokens are, as a set, the Compound Engineering peers the
    entry's installed packages call for (tests/lib/cross-model-peers.nix),
    and CROSS_MODEL_MAX_PEERS=2.

  Store paths are interpolated only when the user generation exists, so a
  removed user fails inside the builder rather than during evaluation. The
  builder collects every failure before it exits, so one red build names
  every affected configuration.
*/
{
  pkgs,
  self,
  fixtures,
}:
let
  inherit (pkgs) lib;

  configurations = import ./lib/configurations.nix { inherit pkgs self fixtures; };
  expectedPeers = import ./lib/cross-model-peers.nix { inherit lib; };

  expectedVariables = {
    TESTCONTAINERS_RYUK_CONTAINER_PRIVILEGED = "true";
    TESTCONTAINERS_RYUK_PRIVILEGED = "true";
    TURBO_ENV_MODE = "loose";
    DOTNET_CLI_TELEMETRY_OPTOUT = "1";
    DOTNET_TELEMETRY_OPTOUT = "1";
    TURBO_TELEMETRY_DISABLED = "1";
    POWERSHELL_TELEMETRY_OPTOUT = "1";
    CROSS_MODEL_MAX_PEERS = "2";
  };

  assertPresent =
    entry:
    let
      environmentFile = "${entry.user.home-files}/.config/environment.d/10-home-manager.conf";
      shellFile = "${entry.user.home.sessionVariablesPackage}/etc/profile.d/hm-session-vars.sh";
      peers = lib.escapeShellArg (lib.concatStringsSep "\n" (expectedPeers entry.user.home.packages));
    in
    ''
      if [ ! -f "${environmentFile}" ]; then
        echo "${entry.name}: home-files has no .config/environment.d/10-home-manager.conf" >&2
        failed=1
      fi
      checkPeers "${entry.name}: environment.d/10-home-manager.conf" \
        "$(sed -n 's/^CROSS_MODEL_PEERS=//p' "${environmentFile}")" ${peers}
      checkPeers "${entry.name}: hm-session-vars.sh" \
        "$(sed -n 's/^export CROSS_MODEL_PEERS="\(.*\)"$/\1/p' "${shellFile}")" ${peers}
    ''
    + lib.concatStrings (
      lib.mapAttrsToList (name: value: ''
        if ! grep -Fxq -- '${name}=${value}' "${environmentFile}"; then
          echo "${entry.name}: environment.d/10-home-manager.conf is missing '${name}=${value}'" >&2
          failed=1
        fi
        if ! grep -Fxq -- 'export ${name}="${value}"' "${shellFile}"; then
          echo "${entry.name}: hm-session-vars.sh is missing 'export ${name}=\"${value}\"'" >&2
          failed=1
        fi
      '') expectedVariables
    );

  assertEntry =
    entry:
    if entry.user ? home-files then
      assertPresent entry
    else
      ''
        echo "${entry.name}: the h82 Home Manager generation is missing" >&2
        failed=1
      '';
in
pkgs.runCommand "session-variables-tests" { nativeBuildInputs = [ pkgs.gnugrep ]; } ''
  set -x
  ${configurations.userGuard}
  failed=0

  # CE matches each token against `,<list>,`, so a space beside a comma, an
  # empty token, or a second line breaks the match.
  checkPeers() {
    local label=$1 value=$2 expected=$3 actual
    if [ -z "$expected" ]; then
      echo "$label: no installed package calls for a CE peer, so the peer check would cover none" >&2
      failed=1
      return
    fi
    case $value in
      *[[:space:]]*)
        echo "$label: CROSS_MODEL_PEERS '$value' holds whitespace or more than one line" >&2
        failed=1
        return
        ;;
    esac
    actual=$(tr ',' '\n' <<<"$value" | sort -u)
    if [ "$actual" != "$expected" ]; then
      echo "$label: CROSS_MODEL_PEERS is '$value', expected the set {$(paste -sd, <<<"$expected")}" >&2
      failed=1
    fi
  }

  ${lib.concatMapStringsSep "\n" assertEntry configurations.userEntries}

  if [ "$failed" != 0 ]; then
    exit 1
  fi
  touch $out
''
