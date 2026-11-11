{
  pkgs,
  self,
  entries ? null,
}:
let
  inherit (pkgs) lib;
  configurations = import ./lib/configurations.nix { inherit pkgs self; };
  pin = builtins.fromJSON (builtins.readFile ../packages/pi-release.json);
  userEntries = if entries == null then configurations.userEntries else entries;

in
pkgs.runCommand "pi-tests"
  {
    nativeBuildInputs = [
      pkgs.python3
      pkgs.nodejs
    ];
  }
  ''
    ${lib.optionalString (entries == null) configurations.userGuard}
    ${lib.concatMapStrings (
      entry:
      let
        found = lib.findFirst (p: (p.pname or "") == "pi") null entry.user.home.packages;
        keyDirectory =
          if entry.user.my.kind == "nixos" then "/run/secrets/cli-auth" else entry.user.my.secrets.stateDir;
      in
      lib.optionalString (found == null || (found.version or "") != pin.version) ''
        echo "Pi missing or wrong version on ${entry.name}" >&2
        exit 1
      ''
      + lib.optionalString (found != null) ''
        test -x ${found}/bin/pi
        python3 ${./pi-runtime.py} ${found}/libexec/pi/pi ${entry.user.home-files}/.pi/agent
        node ${./pi-runtime-policy.mjs} ${found} ${entry.user.home-files}/.pi/agent
        node ${./pi-tools.mjs} ${found} ${entry.user.home-files}/.pi/agent
        python3 ${./pi-wrapper.py} ${found}/bin/pi ${entry.user.home-files}/.pi/agent ${keyDirectory}
        python3 ${./pi-state.py} ${entry.user.home-files}/.pi/agent ${../scripts/pi-state} ${found} ${./pi-trust.mjs}
        node --experimental-strip-types ${./pi-policy.mjs} ${entry.user.home-files}/.pi/agent
      ''
    ) userEntries}
    touch $out
  ''
