{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.my.cliAuth;
  accounts = import ../../shared/cli-accounts.nix;
  credentials = lib.importJSON ../../shared/cli-credentials.json;
  enabledCredentials = lib.filterAttrs (
    _: spec: !(spec ? nixosOption) || cfg.${spec.nixosOption}
  ) credentials;
  groups = lib.unique (lib.mapAttrsToList (_: spec: spec.group) credentials);
  missingGroups = lib.filter (group: (cfg.sopsFiles.${group} or null) == null) (
    lib.unique (lib.mapAttrsToList (_: spec: spec.group) enabledCredentials)
  );
  available = missingGroups == [ ];
  missingPaths = lib.concatMapStringsSep ", " (group: "secrets/${group}.yaml") missingGroups;
  publisher = import ../../../packages/publish-cli-auth.nix { inherit pkgs; };
  opencode = import ../../../packages/opencode.nix { inherit pkgs; };
  agentTools = import ../../../packages/agent-tools.nix { inherit pkgs; };
  opencodeCredentials =
    lib.optional cfg.enableSyntheticApiKey "synthetic=/run/secrets/cli-auth/synthetic_api_key"
    ++ lib.optional cfg.enableOpencodeGoApiKey "opencode-go=/run/secrets/cli-auth/opencode_go_api_key"
    ++ lib.optional cfg.enableOpenaiApiKey "openai=/run/secrets/cli-auth/openai_api_key"
    ++ lib.optional cfg.enableAnthropicApiKey "anthropic=/run/secrets/cli-auth/anthropic_api_key";
  opencodeCommand = lib.escapeShellArgs (
    [
      "${pkgs.util-linux}/bin/runuser"
      "-u"
      config.my.user.name
      "--"
      "${pkgs.coreutils}/bin/env"
      "HOME=${config.my.user.home}"
      "${agentTools.opencodeAuthSync}/bin/opencode-auth-sync"
      "--opencode"
      "${opencode}/bin/opencode"
    ]
    ++ lib.concatMap (spec: [
      "--credential"
      spec
    ]) opencodeCredentials
  );
  publishCommand = lib.escapeShellArgs [
    "${pkgs.util-linux}/bin/runuser"
    "-u"
    config.my.user.name
    "--"
    "${publisher}/bin/publish-cli-auth"
    "--source"
    "/run/secrets/cli-auth"
    "--home"
    config.my.user.home
    "--github-user"
    cfg.githubUser
    "--gitlab-user"
    cfg.gitlabUser
    "--jpi-user"
    cfg.jpiUser
  ];
  dockerCredentialHelper = import ../../../packages/docker-credential-sops.nix {
    inherit pkgs;
    routingTable = import ../../shared/cli-registries.nix {
      dir = "/run/secrets/cli-auth";
      users = {
        github = cfg.githubUser;
        gitlab = cfg.gitlabUser;
        jpi = cfg.jpiUser;
        docker = cfg.dockerUser;
      };
    };
  };
in
{
  options.my.cliAuth = {
    enable = lib.mkEnableOption "CLI authentication publication during activation";
    sopsFiles = lib.mkOption {
      type = lib.types.attrsOf (lib.types.nullOr lib.types.path);
      default = lib.genAttrs groups (
        group:
        let
          file = ../../../secrets + "/${group}.yaml";
        in
        if builtins.pathExists file then file else null
      );
      description = "Encrypted YAML files indexed by CLI credential group. Missing inputs fail at activation.";
    };
    ageKeyFile = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/sops-nix/key.txt";
      description = "Runtime age identity restored once with the YubiKey.";
    };
    githubUser = lib.mkOption {
      type = lib.types.str;
      default = accounts.github;
    };
    gitlabUser = lib.mkOption {
      type = lib.types.str;
      default = accounts.gitlab;
    };
    jpiUser = lib.mkOption {
      type = lib.types.str;
      default = accounts.jpi;
    };
    dockerUser = lib.mkOption {
      type = lib.types.str;
      default = accounts.docker;
    };
    enableDockerToken = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Decrypt docker_token when provisioned.";
    };
    enableTokscaleToken = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Decrypt tokscale_token for the tokscale wrapper, which reads it at run time.";
    };
    enableSyntheticApiKey = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Decrypt synthetic_api_key for Pi's key helper, which reads it at run time.";
    };
    enableExaApiKey = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Decrypt exa_api_key for Pi's Exa web tools, which read it at run time.";
    };
    enableOpenRouterApiKey = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Decrypt openrouter_api_key for Pi's OpenRouter provider, which reads it at run time.";
    };
    enableOpencodeGoApiKey = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Decrypt opencode_go_api_key for OpenCode's OpenCode Go provider, which activation imports into OpenCode's credential store.";
    };
    enableOpenaiApiKey = lib.mkEnableOption "decryption of the OpenAI API key for OpenCode";
    enableAnthropicApiKey = lib.mkEnableOption "decryption of the Anthropic API key for OpenCode";
  };
  config = lib.mkMerge [
    {
      environment.systemPackages = [ dockerCredentialHelper ];
    }
    (lib.mkIf cfg.enable (
      lib.mkMerge [
        {
          systemd.services.sops-install-secrets = {
            wantedBy = [ "sysinit.target" ];
            requiredBy = [ "sysinit-reactivation.target" ];
            after = [
              "local-fs.target"
              "systemd-sysusers.service"
              "userborn.service"
            ];
            before = [
              "sysinit.target"
              "sysinit-reactivation.target"
            ];
            unitConfig = {
              DefaultDependencies = "no";
              RequiresMountsFor = [
                config.my.user.home
                cfg.ageKeyFile
              ];
            };
            serviceConfig = {
              Type = "oneshot";
              # A successful oneshot must be inactive so unchanged switches re-run it.
              RemainAfterExit = lib.mkForce false;
            };
          };
        }
        (lib.mkIf available {
          sops = {
            age = {
              keyFile = cfg.ageKeyFile;
              generateKey = false;
              sshKeyPaths = [ ];
            };
            gnupg.sshKeyPaths = [ ];
            useSystemdActivation = true;
            secrets = lib.mapAttrs' (
              field: spec:
              lib.nameValuePair "cli-auth/${field}" {
                key = field;
                sopsFile = cfg.sopsFiles.${spec.group};
                owner = config.my.user.name;
                mode = "0400";
              }
            ) enabledCredentials;
          };
          systemd.services.sops-install-secrets.serviceConfig.ExecStartPost = [
            publishCommand
          ]
          ++ lib.optional (opencodeCredentials != [ ]) opencodeCommand;
        })
        (lib.mkIf (!available) {
          systemd.services.sops-install-secrets.serviceConfig.ExecStart =
            pkgs.writeShellScript "missing-cli-secrets" ''
              echo 'CLI authentication not provisioned: prepare ${missingPaths} and restore the local age identity. See secrets/README.md.' >&2
              exit 1
            '';
        })
      ]
    ))
  ];
}
