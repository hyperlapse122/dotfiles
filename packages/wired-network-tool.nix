# Packages scripts/<name>.py with the module it shares with the other wired
# network tool. Python puts the script's real directory on sys.path, so the
# shared module has to be copied next to the tool rather than symlinked.
{ pkgs, name }:
let
  scripts = pkgs.runCommand "${name}-scripts" { } ''
    mkdir -p "$out"
    cp ${../scripts + "/${name}.py"} "$out/${name}.py"
    cp ${../scripts/wired_network_common.py} "$out/wired_network_common.py"
  '';
in
pkgs.writeShellApplication {
  inherit name;
  runtimeInputs = [
    pkgs.python3
    pkgs.sops
  ];
  text = ''exec python3 ${scripts}/${name}.py "$@"'';
}
