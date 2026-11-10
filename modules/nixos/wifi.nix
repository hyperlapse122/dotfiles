{
  config,
  lib,
  ...
}:
let
  cfg = config.my.wifi;
  available = cfg.sopsFile != null;
  upperLabels = map lib.toUpper cfg.networks;
in
{
  options.my.wifi = {
    sopsFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = if builtins.pathExists ../../secrets/wifi.yaml then ../../secrets/wifi.yaml else null;
      description = "Encrypted Wi-Fi credential YAML. Missing input builds and activates with no Wi-Fi profiles.";
    };
    networks = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "home"
        "office"
      ];
      description = ''
        Arbitrary local labels (never the literal SSID) for the networks
        declared in `secrets/wifi.yaml`. Each label needs matching
        `wifi.<label>.ssid` / `wifi.<label>.psk` entries in that file.

        Removing a label here does not revoke its NetworkManager profile
        immediately: nixpkgs' `ensureProfiles` only adds or overwrites
        declared profiles and never deletes one for a label no longer
        declared, so the old profile (and the credentials rendered into it)
        stays connectable until the next reboot.
      '';
    };
  };
  config = lib.mkMerge [
    {
      assertions = [
        {
          assertion = lib.length (lib.unique upperLabels) == lib.length upperLabels;
          message = "my.wifi.networks labels must be unique case-insensitively (each becomes an uppercased environment variable prefix)";
        }
        {
          assertion = lib.all (label: builtins.match "[A-Za-z_][A-Za-z0-9_]*" label != null) cfg.networks;
          message = "my.wifi.networks labels must match [A-Za-z_][A-Za-z0-9_]* (each becomes an environment variable name and a NetworkManager connection id; other characters would silently corrupt the substitution)";
        }
      ];
    }
    (lib.mkIf available {
      # Independent of modules/nixos/system/secrets.nix's own cliAuth.sopsFile state:
      # this module must decrypt secrets/wifi.yaml even when tokens.yaml is
      # absent, so it configures its own age key source rather than relying
      # on cliAuth's `mkIf available` block to have already set one. Reads
      # cliAuth's own ageKeyFile option (rather than repeating its literal
      # default) so the two modules cannot silently diverge if it is ever
      # overridden per host.
      sops.age.keyFile = config.my.cliAuth.ageKeyFile;
      sops.age.generateKey = false;

      sops.secrets =
        lib.genAttrs
          (lib.concatMap (label: [
            "wifi/${label}/ssid"
            "wifi/${label}/psk"
          ]) cfg.networks)
          (name: {
            sopsFile = cfg.sopsFile;
            owner = "root";
            mode = "0400";
          });

      sops.templates."wifi.env".content = lib.concatMapStrings (label: ''
        ${lib.toUpper label}_SSID=${config.sops.placeholder."wifi/${label}/ssid"}
        ${lib.toUpper label}_PSK=${config.sops.placeholder."wifi/${label}/psk"}
      '') cfg.networks;

      systemd.services."NetworkManager-ensure-profiles" = {
        after = [ "sops-install-secrets.service" ];
        wants = [ "sops-install-secrets.service" ];
      };

      networking.networkmanager.ensureProfiles = {
        environmentFiles = [ config.sops.templates."wifi.env".path ];
        profiles = lib.genAttrs cfg.networks (label: {
          connection = {
            id = label;
            type = "wifi";
          };
          wifi.ssid = "$" + lib.toUpper label + "_SSID";
          wifi-security = {
            key-mgmt = "wpa-psk";
            psk = "$" + lib.toUpper label + "_PSK";
          };
        });
      };
    })
  ];
}
