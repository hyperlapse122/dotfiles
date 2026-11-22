{ pkgs }:

pkgs.writeShellApplication {
  name = "host-secrets";
  runtimeEnv.CLI_CREDENTIAL_MANIFEST = ../modules/shared/cli-credentials.json;
  runtimeInputs = [
    pkgs.coreutils
    pkgs.openssh
    pkgs.sops
    pkgs.jq
    (import ./publish-cli-auth.nix { inherit pkgs; })
  ];
  text = builtins.readFile ../scripts/host-secrets;
}
