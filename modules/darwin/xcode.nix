{
  config,
  lib,
  pkgs,
  ...
}:
let
  tool = lib.getExe (import ../../packages/macos-xcode.nix { inherit pkgs; });
in
{
  # Only production has the recovered identity. The checkout path is resolved
  # during activation, so neither account plaintext nor ciphertext enters a derivation.
  system.activationScripts.postActivation.text = lib.mkIf (!config.my.bootstrap) (
    lib.mkBefore ''
      xcodeSource="$(/usr/bin/sudo --user=${lib.escapeShellArg config.my.user.name} --set-home ${pkgs.git}/bin/git rev-parse --show-toplevel)/secrets/hosts/${config.my.hostName}/apple-account.yaml"
      /usr/bin/sudo --preserve-env=SSL_CERT_FILE,NIX_SSL_CERT_FILE,NODE_EXTRA_CA_CERTS,REQUESTS_CA_BUNDLE,CURL_CA_BUNDLE,GIT_SSL_CAINFO --user=${lib.escapeShellArg config.my.user.name} --set-home ${tool} \
        --source "$xcodeSource" \
        --identity ${lib.escapeShellArg "${config.my.user.home}/.config/nix-config/age/key.txt"} \
        --owner ${lib.escapeShellArg config.my.user.name}
    ''
  );
}
