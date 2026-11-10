{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.my.tlsInspectionCa;
  inherit (config.my) hostName;
  active = cfg.enable && !config.my.bootstrap;

  tool = lib.getExe (import ../../packages/tls-inspection-ca.nix { inherit pkgs; });
  dir = "/etc/ssl/nix-config";
  bundle = "${dir}/ca-certificates.crt";

  # Every TLS stack this host runs reads one of these. NODE_EXTRA_CA_CERTS
  # takes the whole bundle; Node adds it to its own roots.
  variables = lib.genAttrs [
    "SSL_CERT_FILE"
    "NIX_SSL_CERT_FILE"
    "NODE_EXTRA_CA_CERTS"
    "REQUESTS_CA_BUNDLE"
    "CURL_CA_BUNDLE"
    "GIT_SSL_CAINFO"
  ] (_: bundle);
in
{
  options.my.tlsInspectionCa.certificateFile = lib.mkOption {
    type = lib.types.nullOr lib.types.path;
    default =
      let
        file = ../../secrets/hosts + "/${hostName}/tls-inspection-ca.yaml";
      in
      if builtins.pathExists file then file else null;
    description = "Encrypted YAML holding the TLS inspection CA as `certificate`, decrypted with the host identity.";
  };

  config = lib.mkIf active {
    assertions = [
      {
        assertion = cfg.certificateFile != null;
        message = "${hostName}: my.tlsInspectionCa.enable needs secrets/hosts/${hostName}/tls-inspection-ca.yaml; see docs/macos.md.";
      }
    ];

    # preActivation runs first under set -e, so a CA the host identity cannot
    # decrypt aborts the apply before /etc and launchd point anything at the
    # bundle. The base is this generation's bundle: /etc/ssl/certs still
    # links the previous generation's until the /etc step.
    system.activationScripts.preActivation.text = ''
      echo "setting up the TLS inspection CA bundle..." >&2
      ${tool} bundle \
        --certificate-file ${lib.escapeShellArg "${cfg.certificateFile}"} \
        --identity ${lib.escapeShellArg "${config.my.user.home}/.config/nix-config/age/key.txt"} \
        --identity-owner ${lib.escapeShellArg config.my.user.name} \
        --base ${config.environment.etc."ssl/certs/ca-certificates.crt".source} \
        --out-dir ${dir} \
        --daemon org.nixos.nix-daemon
    '';

    # Never fails the apply, which runs under set -e; a missing trust prompts
    # once per apply.
    system.activationScripts.postActivation.text = lib.mkAfter ''
      echo "checking macOS trust for the TLS inspection CA..." >&2
      if ! ${tool} trust --certificate ${dir}/tls-inspection-ca.pem; then
        echo "tls-inspection-ca: the macOS trust check failed; the apply continues" >&2
      fi
    '';

    # Shells, and through the mkDefault nix-daemon takes from here, the daemon.
    environment.variables = variables;

    # Apps launched from Finder, the Dock, or at login never read the shell
    # environment, and launchctl setenv does not survive a reboot, so a login
    # agent sets it again.
    launchd.user.agents.tls-inspection-ca-environment.serviceConfig = {
      ProgramArguments = [
        "/bin/sh"
        "-c"
        (lib.concatStringsSep "\n" (
          lib.mapAttrsToList (name: value: "/bin/launchctl setenv ${name} ${value}") variables
        ))
      ];
      RunAtLoad = true;
    };
  };
}
