{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.my.tailscale;
  available = cfg.sopsFile != null;
  tailscalePkg = config.services.tailscale.package;
  # The operator lets the user's tray change prefs without sudo. `tailscale up`
  # refuses to run while a stored non-default pref is missing from its flags,
  # so the operator sits in the up flags too, and autoconnect's up adds --reset
  # (below) for prefs the tray changed, such as an exit node.
  nodeFlags = [
    "--ssh"
    "--accept-routes"
    "--operator=${config.my.user.name}"
  ];
  routeLabels = [
    "lan_10"
    "lan_1"
    "site_a"
    "site_b"
  ];

  dedupScript = pkgs.writeShellScript "tailscale-dedup-device" (
    builtins.readFile ../../../scripts/tailscale-dedup-device
  );
in
{
  options.my.tailscale = {
    enable = lib.mkEnableOption "Tailscale mesh networking with SSH and unattended re-registration";
    advertiseRoutes = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Advertise this host's subnet routes to the tailnet. Only one host in the tailnet should set this.";
    };
    sopsFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default =
        if builtins.pathExists ../../../secrets/tailscale.yaml then
          ../../../secrets/tailscale.yaml
        else
          null;
      description = "Encrypted Tailscale credentials YAML. Missing input builds with tailscaled running but unauthenticated.";
    };
    apiBase = lib.mkOption {
      type = lib.types.str;
      default = "https://api.tailscale.com";
      description = "Tailscale API base URL. Overridden in VM tests to point at a mock server instead of the real API.";
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        services.tailscale = {
          enable = true;
          openFirewall = true;
          extraUpFlags = nodeFlags ++ [ "--reset" ];
          # tailscaled-autoconnect applies extraUpFlags only while the node
          # needs login; extraSetFlags runs `tailscale set` on every tailscaled
          # start, so an already-registered node gets the same prefs.
          extraSetFlags = nodeFlags;
          useRoutingFeatures = if cfg.advertiseRoutes then "server" else "none";
        };
      }
      (lib.mkIf available {
        # Independent of modules/nixos/system/secrets.nix's own cliAuth.sopsFile state:
        # this module must decrypt secrets/tailscale.yaml even when tokens.yaml is
        # absent, so it configures its own age key source rather than relying
        # on cliAuth's `mkIf available` block to have already set one.
        sops.age.keyFile = config.my.cliAuth.ageKeyFile;
        sops.age.generateKey = false;

        sops.secrets =
          lib.genAttrs
            (
              [
                "tailscale/auth_key"
                "tailscale/api_token"
              ]
              ++ lib.optionals cfg.advertiseRoutes (map (r: "tailscale/routes/${r}") routeLabels)
            )
            (name: {
              sopsFile = cfg.sopsFile;
              owner = "root";
              mode = "0400";
            });

        # Split so tailscale-advertise-routes (which never calls the API)
        # isn't hand the bearer token it has no use for.
        sops.templates = lib.mkMerge [
          {
            "tailscale-api.env".content = ''
              TAILSCALE_API_TOKEN=${config.sops.placeholder."tailscale/api_token"}
              TAILSCALE_API_BASE=${cfg.apiBase}
            '';
          }
          (lib.mkIf cfg.advertiseRoutes {
            "tailscale-routes.env".content = ''
              TAILSCALE_ROUTES=${
                lib.concatMapStringsSep "," (r: config.sops.placeholder."tailscale/routes/${r}") routeLabels
              }
            '';
          })
        ];

        services.tailscale.authKeyFile = config.sops.secrets."tailscale/auth_key".path;

        # Runs before tailscaled-autoconnect, gated on tailscaled's own state
        # file rather than BackendState: an ordinary reboot or a key-expiry
        # reauthentication both leave that file in place (this instance IS
        # the existing registration, so never delete it), while a genuine
        # fresh install has no state file yet, which is exactly when a
        # same-hostname device must be cleared -- and it must be cleared
        # *before* the new instance registers, since Tailscale suffixes a
        # colliding hostname on the newly-registering device, not the old
        # one. `before` alone is enough to order ahead of
        # tailscaled-autoconnect.service: nixpkgs already pulls that unit in
        # via its own `wantedBy = [ "multi-user.target" ]`.
        systemd.services.tailscale-dedup-device = {
          description = "On a fresh install, remove any pre-existing tailnet device with this host's name";
          before = [ "tailscaled-autoconnect.service" ];
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            Type = "oneshot";
            EnvironmentFile = config.sops.templates."tailscale-api.env".path;
            Environment = "SELF_HOSTNAME=${config.networking.hostName}";
            ExecStart = dedupScript;
          };
          path = [
            pkgs.jq
            pkgs.curl
          ];
        };

        systemd.services.tailscale-advertise-routes = lib.mkIf cfg.advertiseRoutes {
          description = "Advertise this host's configured Tailscale subnet routes";
          after = [ "tailscaled-autoconnect.service" ];
          wants = [ "tailscaled-autoconnect.service" ];
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            Type = "oneshot";
            EnvironmentFile = config.sops.templates."tailscale-routes.env".path;
          };
          path = [ tailscalePkg ];
          # tailscale set --advertise-routes is idempotent, so this needs no
          # state gate: safe to run on every activation.
          script = ''
            tailscale set --advertise-routes="$TAILSCALE_ROUTES"
          '';
        };
      })
    ]
  );
}
