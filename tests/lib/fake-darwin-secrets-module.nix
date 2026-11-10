# The system-level counterpart of fake-secrets-module.nix for the macOS
# fixtures: the TLS inspection CA their production output decrypts.
{ pkgs, ... }:
let
  fakeSecrets = import ./fake-secrets.nix { inherit pkgs; };
in
{
  my.tlsInspectionCa.certificateFile = "${fakeSecrets}/tls-inspection-ca.yaml";
}
