{ pkgs }:

pkgs.writeShellApplication {
  name = "host-secrets";
  runtimeInputs = [
    pkgs.coreutils
    pkgs.openssh
    pkgs.sops
    (import ./publish-cli-auth.nix { inherit pkgs; })
  ];
  text = builtins.readFile ../scripts/host-secrets;
}
