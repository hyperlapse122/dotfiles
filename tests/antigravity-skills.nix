{
  entries ? null,
  pkgs,
  self,
  fixtures ? [ ],
}:
let
  lib = pkgs.lib;
  configurations = import ./lib/configurations.nix { inherit pkgs self fixtures; };
  userEntries = if entries == null then configurations.userEntries else entries;

in
pkgs.runCommand "antigravity-skills-tests" { nativeBuildInputs = [ pkgs.python3 ]; } ''
  ${lib.optionalString (entries == null) configurations.userGuard}
  ${lib.concatMapStrings (entry: ''
    python3 ${./native-plugins.py} ${pkgs.writeText "agent-plugins.sh" entry.user.home.activation.nativeAgentPlugins.data}
  '') userEntries}
  touch $out
''
