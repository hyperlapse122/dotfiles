/*
  CLI credentials and the host SSH key on a Darwin host.

  NixOS decrypts these with a root-owned identity in a system unit. A
  Darwin host has no such stage, so its production output decrypts them
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
  credentials = lib.importJSON ../../../modules/shared/cli-credentials.json;
  groups = lib.unique (
    lib.mapAttrsToList (_: spec: spec.group) (
      lib.filterAttrs (_: spec: spec.darwin or true) credentials
    )
  );
  missingGroups = lib.filter (group: (cfg.credentialFiles.${group} or null) == null) groups;
  missingPaths =
    map (group: "secrets/${group}.yaml") missingGroups
    ++ lib.optional (cfg.sshKeyFile == null) "secrets/hosts/${hostName}/ssh.yaml";

  gpgTools = import ../../../packages/gpg-tools.nix { inherit pkgs; };
  hostSecrets = "${import ../../../packages/host-secrets.nix { inherit pkgs; }}/bin/host-secrets";
  # Interpolation copies a repository file into the store, so the activation
  # keeps the ciphertext in its closure. Null only reaches here when the
  # assertion below already fails.
  storePath = file: if file == null then "" else "${file}";
  hostSecretsArgs = lib.escapeShellArgs (
    [
      "--host"
      hostName
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
    ]
    ++ lib.concatMap (group: [
      "--credential-file"
      group
      (storePath (cfg.credentialFiles.${group} or null))
    ]) groups
  );

  registries = import ../../../modules/shared/cli-registries.nix {
    dir = cfg.stateDir;
    users = accounts;
  };
  dockerCredentialHelper = import ../../../packages/docker-credential-sops.nix {
    inherit pkgs;
    routingTable = registries;
  };

  # Darwin decrypts secrets with a user-owned identity.
  darwin = config.my.kind == "darwin";
  active = darwin && !config.my.bootstrap;
in
{
  options.my.secrets = {
    credentialFiles = lib.mkOption {
      type = lib.types.attrsOf (lib.types.nullOr lib.types.path);
      default = { };
      description = "Encrypted YAML files indexed by CLI credential group.";
    };
    sshKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = import ../../../lib/host-secret-file.nix hostName "ssh.yaml";
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
    {
      my.secrets.credentialFiles = lib.genAttrs groups (
        group:
        let
          file = ../../../secrets + "/${group}.yaml";
        in
        lib.mkDefault (if builtins.pathExists file then file else null)
      );
    }

    (lib.mkIf darwin {
      # Needed from the bootstrap output on, since recovery runs there.
      home.packages = [
        gpgTools.installUserAgeIdentity
        dockerCredentialHelper
      ];
    })

    (lib.mkIf active {
      assertions = [
        {
          assertion = missingPaths == [ ];
          message = "${hostName}: a Darwin production output needs ${lib.concatStringsSep ", " missingPaths}; see docs/adding-a-host.md.";
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
