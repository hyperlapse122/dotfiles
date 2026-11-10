{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.my.cliAuth;
  accounts = import ../../shared/cli-accounts.nix;
  available = cfg.sopsFile != null;
  publisher = import ../../../packages/publish-cli-auth.nix { inherit pkgs; };
  publishCommand = lib.escapeShellArgs [
    "${pkgs.util-linux}/bin/runuser"
    "-u"
    "h82"
    "--"
    "${publisher}/bin/publish-cli-auth"
    "--source"
    "/run/secrets/cli-auth"
    "--home"
    "/home/h82"
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
    sopsFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default =
        if builtins.pathExists ../../../secrets/tokens.yaml then ../../../secrets/tokens.yaml else null;
      description = "Encrypted token YAML. Missing input fails at activation, not evaluation.";
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
      description = "Decrypt docker_token from secrets/tokens.yaml when provisioned.";
    };
    enableTokscaleToken = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Decrypt tokscale_token from secrets/tokens.yaml for the tokscale wrapper, which reads it at run time.";
    };
    enableSyntheticApiKey = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Decrypt synthetic_api_key from secrets/tokens.yaml for Pi's key helper, which reads it at run time.";
    };
    enableExaApiKey = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Decrypt exa_api_key from secrets/tokens.yaml for Pi's Exa web tools, which read it at run time.";
    };
    enableOpenRouterApiKey = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Decrypt openrouter_api_key from secrets/tokens.yaml for Pi's OpenRouter provider, which reads it at run time.";
    };
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
                "/home/h82"
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
            defaultSopsFile = cfg.sopsFile;
            age = {
              keyFile = cfg.ageKeyFile;
              generateKey = false;
              sshKeyPaths = [ ];
            };
            gnupg.sshKeyPaths = [ ];
            useSystemdActivation = true;
            secrets =
              lib.genAttrs
                (map (name: "cli-auth/${name}") (
                  [
                    "github_token"
                    "gitlab_token"
                    "jpi_token"
                  ]
                  ++ lib.optional cfg.enableDockerToken "docker_token"
                  ++ lib.optional cfg.enableTokscaleToken "tokscale_token"
                  ++ lib.optional cfg.enableSyntheticApiKey "synthetic_api_key"
                  ++ lib.optional cfg.enableExaApiKey "exa_api_key"
                  ++ lib.optional cfg.enableOpenRouterApiKey "openrouter_api_key"
                ))
                (name: {
                  key = lib.removePrefix "cli-auth/" name;
                  owner = "h82";
                  mode = "0400";
                });
          };
          systemd.services.sops-install-secrets.serviceConfig.ExecStartPost = publishCommand;
        })
        (lib.mkIf (!available) {
          systemd.services.sops-install-secrets.serviceConfig.ExecStart =
            pkgs.writeShellScript "missing-cli-secrets" ''
              echo 'CLI authentication not provisioned: prepare secrets/tokens.yaml and restore the local age identity. See secrets/README.md.' >&2
              exit 1
            '';
        })
      ]
    ))
  ];
}
