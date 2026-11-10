{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.my.printing;
  available = cfg.sopsFile != null;
  # A bootstrap install may run before the age identity is restored.
  queues = lib.optionals (available && !config.my.bootstrap) cfg.queues;
  envName = label: lib.toUpper label;
  cups = config.services.printing.package;

  ensureQueue = label: ''
    uri=''$${envName label}_URI
    info=''$${envName label}_INFO
    # A queue that already points at the URI is left alone: recreating it
    # queries the printer, which fails while the printer is off.
    if [ "$(lpstat -v ${label} 2>/dev/null)" != "device for ${label}: $uri" ]; then
      lpadmin -p ${label} -E -v "$uri" -m everywhere
    fi
    # Setting the description does not query the printer, so a changed
    # description reaches an existing queue even while the printer is off.
    lpadmin -p ${label} -D "$info"
  '';
in
{
  options.my.printing = {
    enable = lib.mkEnableOption "CUPS printing with network printer discovery through Avahi";
    sopsFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default =
        if builtins.pathExists ../../../secrets/printers.yaml then ../../../secrets/printers.yaml else null;
      description = "Encrypted printer queue YAML. Missing input builds with no declared queues.";
    };
    queues = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Arbitrary local labels (never the printer model) for the CUPS queues
        declared in `secrets/printers.yaml`. Each label becomes the queue name
        and needs matching `printers.<label>.uri` / `printers.<label>.info`
        entries in that file. The printer must speak IPP Everywhere.
      '';
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        assertions = [
          {
            assertion = lib.length (lib.unique (map envName cfg.queues)) == lib.length cfg.queues;
            message = "my.printing.queues labels must be unique case-insensitively (each becomes an uppercased environment variable prefix)";
          }
          {
            assertion = lib.all (label: builtins.match "[A-Za-z_][A-Za-z0-9_]*" label != null) cfg.queues;
            message = "my.printing.queues labels must match [A-Za-z_][A-Za-z0-9_]* (each becomes an environment variable name and a CUPS queue name)";
          }
        ];

        # Driverless IPP Everywhere and AirPrint printers need no driver package;
        # gutenprint and hplip cover older printers that still need one.
        services.printing = {
          enable = true;
          drivers = [
            pkgs.gutenprint
            pkgs.hplip
          ];
          # cupsd creates temporary queues for printers Avahi finds on its own.
          # cups-browsed, which nixpkgs enables whenever Avahi is, adds only the
          # legacy CUPS browsing protocol and its exposed listener.
          browsed.enable = false;
        };

        services.avahi = {
          enable = true;
          nssmdns4 = true;
          openFirewall = true;
        };
      }
      (lib.mkIf (queues != [ ]) {
        # Same independence from modules/nixos/system/secrets.nix as wifi.nix:
        # this module configures its own age key source so it decrypts
        # secrets/printers.yaml even when tokens.yaml is absent.
        sops.age.keyFile = config.my.cliAuth.ageKeyFile;
        sops.age.generateKey = false;

        sops.secrets =
          lib.genAttrs
            (lib.concatMap (label: [
              "printers/${label}/uri"
              "printers/${label}/info"
            ]) queues)
            (name: {
              sopsFile = cfg.sopsFile;
              owner = "root";
              mode = "0400";
            });

        sops.templates."printers.env".content = lib.concatMapStrings (label: ''
          ${envName label}_URI=${config.sops.placeholder."printers/${label}/uri"}
          ${envName label}_INFO=${config.sops.placeholder."printers/${label}/info"}
        '') queues;

        # hardware.printers.ensurePrinters renders each device URI into the
        # cups unit in the Nix store, so the queues are created at run time
        # from the decrypted values instead. lpadmin takes them only as
        # arguments, so they are visible to local `ps` while it runs.
        systemd.services.ensure-printers = {
          description = "Create the CUPS queues declared in secrets/printers.yaml";
          wantedBy = [ "multi-user.target" ];
          # Ordering alone: sops-install-secrets is wanted by sysinit.target
          # and sysinit-reactivation.target. Wanting it here would re-run it,
          # and its CLI auth publish, on every 5-minute retry, because it
          # does not remain active after it exits.
          wants = [ "network-online.target" ];
          requires = [ "cups.socket" ];
          after = [
            "sops-install-secrets.service"
            "network-online.target"
            "cups.socket"
          ];
          path = [ cups ];
          # The lpstat comparison above expects the untranslated message.
          environment.LC_ALL = "C";
          # -m everywhere reads the model from the printer itself, so creation
          # waits until the printer is reachable.
          unitConfig.StartLimitIntervalSec = 0;
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            EnvironmentFile = config.sops.templates."printers.env".path;
            Restart = "on-failure";
            RestartSec = "5min";
          };
          script = lib.concatMapStrings ensureQueue queues;
          # The template holds only placeholders, so a changed value shows up
          # only as a changed encrypted file.
          restartTriggers = [ cfg.sopsFile ];
        };
      })
    ]
  );
}
