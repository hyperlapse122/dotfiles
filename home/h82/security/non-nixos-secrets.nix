/*
  CLI credentials and the host SSH key on a non-NixOS host.

  NixOS decrypts these with a root-owned identity in a system unit. A
  non-NixOS host has no such stage, so its production output decrypts them
  from the user-owned identity during Home Manager activation, through
  scripts/host-secrets: `stage` runs before writeBoundary and aborts the
  activation before a single link changes when the identity or any secret is
  wrong, and `publish` runs after linkGeneration. The sops-nix Home Manager
  service is not used because its failure, in a user unit, does not fail the
  switch.

  The bootstrap output carries none of this, so it applies before the
  identity has been recovered.
*/
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.my.secrets;
  inherit (config.my) hostName;
  accounts = import ../../../modules/shared/cli-accounts.nix;

  gpgTools = import ../../../packages/gpg-tools.nix { inherit pkgs; };
  hostSecrets = "${import ../../../packages/host-secrets.nix { inherit pkgs; }}/bin/host-secrets";
  # Interpolation copies a repository file into the store, so the activation
  # keeps the ciphertext in its closure. Null only reaches here when the
  # assertion below already fails.
  storePath = file: if file == null then "" else "${file}";
  hostSecretsArgs = lib.escapeShellArgs [
    "--host"
    hostName
    "--tokens"
    (storePath cfg.tokensFile)
    "--ssh"
    (storePath cfg.sshKeyFile)
    "--state-dir"
    cfg.stateDir
    "--ssh-key"
    cfg.sshKey
    "--github-user"
    accounts.github
    "--gitlab-user"
    accounts.gitlab
    "--jpi-user"
    accounts.jpi
  ];

  registries = import ../../../modules/shared/cli-registries.nix {
    dir = cfg.stateDir;
    users = accounts;
  };
  dockerCredentialHelper = import ../../../packages/docker-credential-sops.nix {
    inherit pkgs;
    routingTable = registries;
  };

  # Linux and macOS hosts alike: neither has the NixOS system unit that
  # decrypts secrets with a root-owned identity.
  nonNixos = config.my.kind != "nixos";
  active = nonNixos && !config.my.bootstrap;
in
{
  options.my.secrets = {
    tokensFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default =
        if builtins.pathExists ../../../secrets/tokens.yaml then ../../../secrets/tokens.yaml else null;
      description = "Encrypted token YAML shared by every host.";
    };
    sshKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default =
        let
          file = ../../../secrets/hosts + "/${hostName}/ssh.yaml";
        in
        if builtins.pathExists file then file else null;
      description = "Encrypted YAML holding this host's SSH private key as ssh_private_key.";
    };
    sshKey = lib.mkOption {
      type = lib.types.str;
      default = "${config.my.user.home}/.ssh/id_ed25519_nix_config";
      readOnly = true;
      description = "Where host-secrets installs this host's SSH private key; ~/.ssh/config names it.";
    };
    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "${config.my.user.home}/.local/state/cli-auth";
      readOnly = true;
      description = "Where host-secrets publishes the decrypted tokens: the user-mode counterpart of /run/secrets/cli-auth, read by the credential helper and the Tokscale wrapper.";
    };
  };

  config = lib.mkMerge [
    (lib.mkIf nonNixos {
      # Needed from the bootstrap output on, since recovery runs there.
      home.packages = [
        gpgTools.installUserAgeIdentity
        dockerCredentialHelper
      ];
    })

    (lib.mkIf active {
      assertions = [
        {
          assertion = cfg.tokensFile != null && cfg.sshKeyFile != null;
          message = "${hostName}: a non-NixOS production output needs secrets/tokens.yaml and secrets/hosts/${hostName}/ssh.yaml; see docs/adding-a-host.md.";
        }
      ];

      home.activation.nixConfigSecretsStage = lib.hm.dag.entryBefore [ "writeBoundary" ] ''
        ${hostSecrets} stage ${hostSecretsArgs}
      '';

      home.activation.nixConfigSecretsPublish = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
        ${hostSecrets} publish ${hostSecretsArgs}
      '';
    })
  ];
}
