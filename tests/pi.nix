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
  executeActivation = import ./lib/agent-activation.nix { inherit pkgs; };

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
    failed=0
    ${lib.concatMapStrings (
      entry:
      let
        found = lib.findFirst (p: (p.pname or "") == "pi") null entry.user.home.packages;
        decide = lib.findFirst (p: (p.pname or "") == "decide") null entry.user.home.packages;
        authActivation = entry.user.home.activation.piAuth or null;
        keyDirectory =
          if entry.user.my.kind == "nixos" then "/run/secrets/cli-auth" else entry.user.my.secrets.stateDir;
      in
      lib.optionalString (found == null || (found.version or "") != pin.version) ''
        echo "Pi missing or wrong version on ${entry.name}" >&2
        exit 1
      ''
      + lib.optionalString (found != null) ''
        test -x ${found}/bin/pi
        python3 ${./pi-runtime.py} ${found}/libexec/pi/pi ${entry.user.home-files}/.pi/agent ${../home/h82/agents}
        node ${./pi-tools.mjs} ${found} ${entry.user.home-files}/.pi/agent
        python3 ${./pi-wrapper.py} ${found}/bin/pi ${entry.user.home-files}/.pi/agent ${keyDirectory}
        python3 ${./pi-state.py} ${entry.user.home-files}/.pi/agent ${../scripts/pi-state} ${found} ${./pi-trust.mjs}
      ''
      + lib.optionalString (authActivation == null && !entry.user.my.bootstrap) ''
        echo "missing home.activation.piAuth on production output ${entry.name}" >&2
        failed=1
      ''
      + lib.optionalString (authActivation != null) ''
        python3 ${./pi-activation.py} ${pkgs.writeText "pi-auth-block.sh" authActivation.data} ${entry.user.home.homeDirectory} ${keyDirectory} || failed=1
      ''
      + executeActivation {
        script = entry.user.home.activation.piMcpSettings.data or "";
        home = entry.user.home.homeDirectory;
        contract = {
          file = ".pi/agent/mcp.json";
          declared.ownEntries = [
            {
              path = [ "mcpServers" ];
              entries.decide = {
                command = if decide == null then "/missing/bin/decide-mcp" else "${decide}/bin/decide-mcp";
                exposure = "direct";
                timeout = 1800;
                type = "stdio";
              };
            }
          ];
          seed.mcpServers.other.command = "other";
          preservePaths = [
            [
              "mcpServers"
              "other"
            ]
          ];
        };
      }
    ) userEntries}
    test "$failed" = 0
    touch $out
  ''
