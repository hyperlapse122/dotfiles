# The system-level counterpart of fake-secrets-module.nix for the macOS
# fixtures: the TLS inspection CA, the wired network declaration, and the
# Apple Account file their production output decrypts. No check decrypts the
# Apple Account file, so it holds no ciphertext.
{ pkgs, ... }:
let
  fakeSecrets = import ./fake-secrets.nix { inherit pkgs; };
in
{
  my.tlsInspectionCa.certificateFile = "${fakeSecrets}/tls-inspection-ca.yaml";
  my.wiredNetwork.file = "${fakeSecrets}/wired-network.yaml";
  my.xcode.appleAccountFile = "${pkgs.writeTextDir "apple-account.yaml" "fake\n"}/apple-account.yaml";
}
