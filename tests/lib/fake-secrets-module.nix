# Fixtures have no card-encrypted material under secrets/, so production
# decrypts fake secrets built for the fixture's own architecture. Shared by
# the Linux and macOS fixture assemblies.
{ pkgs, ... }:
let
  fakeSecrets = import ./fake-secrets.nix { inherit pkgs; };
in
{
  my.secrets = {
    tokensFile = "${fakeSecrets}/tokens.yaml";
    sshKeyFile = "${fakeSecrets}/ssh.yaml";
  };
}
