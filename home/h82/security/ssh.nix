{
  config,
  lib,
  pkgs,
  ...
}:
let
  production = config.my.kind == "nixos" && !config.my.bootstrap;
  publicKey = config.my.desktopSSH.publicKey;
  helper = import ../../../packages/desktop-ssh-session-active.nix { inherit pkgs; };
  tool = import ../../../packages/desktop-ssh.nix { inherit pkgs; };

  marker = "# Managed by nix-config; activation rewrites this file.";
  sshConfig = marker + "\n" + body;

  # Bootstrap keeps the existing agent until host credentials are provisioned.
  # A non-NixOS host, Linux or macOS, has no 1Password agent the flake sets up:
  # it uses its own key, which production activation publishes
  # (non-nixos-secrets.nix).
  body =
    if config.my.kind != "nixos" then
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

    (lib.mkIf (config.my.kind == "nixos") {
      home.file.".config/1Password/ssh/agent.toml".source = ../../../config/1password/agent.toml;
    })

    (lib.mkIf production {
      home.packages = [ (lib.hiPrio tool) ];
      home.file.".config/desktop-ssh/config.json".text = builtins.toJSON {
        public_key = "${publicKey}";
        key_file = "${config.my.user.home}/.ssh/id_ed25519_nix_config";
        fallback_socket = "${config.my.user.home}/.1password/agent.sock";
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
