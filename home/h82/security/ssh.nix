{
  config,
  lib,
  pkgs,
  ...
}:
let
  production = config.my.kind == "nixos" && !config.my.bootstrap;
  darwinProduction = config.my.kind == "darwin" && !config.my.bootstrap;
  publicKey = config.my.desktopSSH.publicKey;
  home = config.my.user.home;
  helper = import ../../../packages/desktop-ssh-session-active.nix { inherit pkgs; };
  tool = import ../../../packages/desktop-ssh.nix { inherit pkgs; };

  marker = "# Managed by nix-config; activation rewrites this file.";
  sshConfig = marker + "\n" + body;

  # A production Mac offers keys through ssh-agent-mux in this order: its
  # own key (non-nixos-secrets.nix publishes it), the YubiKey through
  # gpg-agent, then 1Password. OpenSSH offers agent keys that an IdentityFile
  # names first and keys found only in a file last, so the host key is served
  # by its own agent; the file entry still works when the mux is down.
  muxSocket = "${home}/.ssh/ssh-agent-mux.sock";
  hostKeySocket = "${home}/.ssh/host-key-agent.sock";
  muxUpstreams = [
    hostKeySocket
    "${config.programs.gpg.homedir}/S.gpg-agent.ssh"
    "${home}/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"
  ];
  openssh = "${pkgs.openssh}/bin";

  # Bootstrap keeps the existing agent until host credentials are provisioned.
  body =
    if darwinProduction then
      ''
        Host *
          IdentityFile ${config.my.secrets.sshKey}
          IdentityAgent ${muxSocket}
      ''
    else if config.my.kind != "nixos" then
      ''
        Host *
          IdentityFile ${config.my.secrets.sshKey}
      ''
    else if production then
      ''
        Host *
          IdentityFile ${publicKey}
          IdentityAgent /run/user/%i/desktop-ssh/agent.sock
      ''
    else
      ''
        Host *
          IdentityAgent ~/.1password/agent.sock
      '';
in
{
  options.my.ssh.configFile = lib.mkOption {
    type = lib.types.path;
    readOnly = true;
    internal = true;
    description = "The file activation installs as ~/.ssh/config.";
  };

  config = lib.mkMerge [
    {
      my.ssh.configFile = pkgs.writeText "ssh-config" sshConfig;

      # Installed as a user-owned copy rather than linked into the store. ssh
      # refuses a ~/.ssh/config owned by anyone but root or the user, and in an
      # unprivileged user namespace, such as the bubblewrap sandbox of the
      # T3 Code wrapper, root-owned store files appear owned by nobody. After
      # linkGeneration, which removes the previous generation's link at this
      # path. A file without the marker is one the user wrote, so it is moved
      # aside rather than overwritten.
      home.activation.sshConfig = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
        run install -d -m 700 "$HOME/.ssh"
        if [ -f "$HOME/.ssh/config" ] && [ ! -L "$HOME/.ssh/config" ] \
          && ! grep -qxF ${lib.escapeShellArg marker} "$HOME/.ssh/config"; then
          run mv --backup=numbered "$HOME/.ssh/config" "$HOME/.ssh/config.unmanaged"
        fi
        run install -m 600 ${config.my.ssh.configFile} "$HOME/.ssh/config"
      '';
    }

    {
      # 1Password reads the same key selection on Linux and macOS.
      home.file.".config/1Password/ssh/agent.toml".source = ../../../config/1password/agent.toml;
    }

    (lib.mkIf darwinProduction {
      # ssh-agent-mux cannot add keys, so this agent loads the host key itself.
      # If the key is not there yet, it exits and launchd starts it again.
      launchd.agents.ssh-host-key-agent = {
        enable = true;
        config = {
          ProgramArguments = [
            "/bin/sh"
            "-c"
            ''
              socket=${lib.escapeShellArg hostKeySocket}
              /bin/rm -f "$socket"
              ${openssh}/ssh-agent -D -a "$socket" &
              agent=$!
              while [ ! -S "$socket" ] && kill -0 "$agent" 2>/dev/null; do /bin/sleep 0.1; done
              if ! SSH_AUTH_SOCK="$socket" ${openssh}/ssh-add -q ${lib.escapeShellArg config.my.secrets.sshKey}; then
                echo "ssh-host-key-agent: cannot load ${config.my.secrets.sshKey}" >&2
                kill "$agent"
                exit 1
              fi
              wait "$agent"
            ''
          ];
          RunAtLoad = true;
          KeepAlive = true;
        };
      };

      # Starting gpg-agent here makes its SSH socket exist from login.
      launchd.agents.ssh-agent-mux = {
        enable = true;
        config = {
          ProgramArguments = [
            "/bin/sh"
            "-c"
            ''
              ${config.programs.gpg.package}/bin/gpgconf --launch gpg-agent || echo "ssh-agent-mux: gpg-agent did not start" >&2
              /bin/rm -f ${lib.escapeShellArg muxSocket}
              exec ${pkgs.ssh-agent-mux}/bin/ssh-agent-mux --config /dev/null --listen ${
                lib.escapeShellArgs ([ muxSocket ] ++ muxUpstreams)
              }
            ''
          ];
          RunAtLoad = true;
          KeepAlive = true;
        };
      };
    })

    (lib.mkIf production {
      home.packages = [ (lib.hiPrio tool) ];
      home.file.".config/desktop-ssh/config.json".text = builtins.toJSON {
        public_key = "${publicKey}";
        key_file = "${config.my.user.home}/.ssh/id_ed25519_nix_config";
        # Offered in this order after the host key: the YubiKey through
        # gpg-agent, then 1Password. gpg-agent gets a longer listing budget
        # because the first listing after the card is inserted reads it
        # through scdaemon.
        fallback_agents = [
          {
            socket = "/run/user/%i/gnupg/S.gpg-agent.ssh";
            timeout = 2;
          }
          {
            socket = "${config.my.user.home}/.1password/agent.sock";
            timeout = 0.3;
          }
        ];
      };
      systemd.user.services.desktop-ssh-agent = {
        Unit = {
          Description = "Desktop session SSH primary agent";
          After = [ "graphical-session.target" ];
          BindsTo = [ "graphical-session.target" ];
          PartOf = [ "graphical-session.target" ];
        };
        Service = {
          ExecCondition = lib.escapeShellArgs [
            "${helper}/bin/desktop-ssh-session-active"
            config.my.user.name
          ];
          ExecStart = lib.escapeShellArgs [
            "${tool}/bin/desktop-ssh"
            "agent"
            "--config"
            "${config.my.user.home}/.config/desktop-ssh/config.json"
          ];
          ExecStopPost = "${pkgs.systemd}/bin/systemctl --no-ask-password stop desktop-ssh-provision.service";
          RuntimeDirectory = "desktop-ssh";
          RuntimeDirectoryMode = "0700";
          LimitCORE = 0;
          KillMode = "control-group";
        };
        Install.WantedBy = [ "graphical-session.target" ];
      };
    })
  ];
}
