{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.my.xcode;
  inherit (config.my) hostName;
  active = !config.my.bootstrap;
  tool = lib.getExe (import ../../packages/macos-xcode.nix { inherit pkgs; });
in
{
  options.my.xcode.appleAccountFile = lib.mkOption {
    type = lib.types.nullOr lib.types.path;
    default =
      let
        file = ../../secrets/hosts + "/${hostName}/apple-account.yaml";
      in
      if builtins.pathExists file then file else null;
    description = "Encrypted YAML holding the Apple Account `username` and `password` for `xcodes`, decrypted in memory with the host identity at activation.";
  };

  # Only production has the recovered identity. The file is named by its store
  # path: nix-darwin's activate clears the environment and runs from /, so
  # nothing at activation can find the checkout being applied.
  config = lib.mkIf active {
    assertions = [
      {
        assertion = cfg.appleAccountFile != null;
        message = "${hostName}: Xcode provisioning needs secrets/hosts/${hostName}/apple-account.yaml; see docs/macos.md.";
      }
    ];

    system.activationScripts.postActivation.text = lib.mkBefore ''
      /usr/bin/sudo --preserve-env=SSL_CERT_FILE,NIX_SSL_CERT_FILE,NODE_EXTRA_CA_CERTS,REQUESTS_CA_BUNDLE,CURL_CA_BUNDLE,GIT_SSL_CAINFO --user=${lib.escapeShellArg config.my.user.name} --set-home ${tool} \
        --source ${lib.escapeShellArg "${cfg.appleAccountFile}"} \
        --identity ${lib.escapeShellArg "${config.my.user.home}/.config/nix-config/age/key.txt"} \
        --owner ${lib.escapeShellArg config.my.user.name}
    '';
  };
}
