{ lib, ... }:
{
  # Host facts and traits, declared once and imported by every assembly: the
  # NixOS and Darwin systems and their Home Manager users. Modules and checks
  # branch on these values, never on a host name.
  options.my = {
    bootstrap = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Install without private boot keys or user authentication secrets.";
    };

    hostName = lib.mkOption {
      type = lib.types.str;
      description = "The host's name, taken from its directory under hosts/.";
    };

    kind = lib.mkOption {
      type = lib.types.enum [
        "nixos"
        "darwin"
      ];
      default = "nixos";
      description = "Whether the host runs NixOS or macOS.";
    };

    desktopSSH.publicKey = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Public SSH metadata shared by the desktop provisioner and user agent.";
    };

    locale = {
      name = lib.mkOption {
        type = lib.types.str;
        default = "C.UTF-8";
        description = "OS Locale used when no user formatting preference is present.";
      };
      language = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Persistent OS message-language fallback, derived by the host assembly.";
      };
    };

    user = {
      name = lib.mkOption {
        type = lib.types.str;
        default = "h82";
        description = "The account the user environment is applied to.";
      };
      home = lib.mkOption {
        type = lib.types.str;
        default = "/home/h82";
        description = "The home directory of that account.";
      };
      gpgKey = lib.mkOption {
        type = lib.types.strMatching "[0-9A-F]{40}";
        default = "621512777E6933FEB4458FDC4945855D4F283F05";
        description = "Fingerprint of the user's OpenPGP card key, which Git signs with and the shared agent instructions name as the user's SOPS recipient.";
      };
    };

    intune.enable = lib.mkEnableOption "Microsoft Intune enrollment: the Intune app, the identity broker, and Microsoft Edge, with an Ubuntu OS identity for the Intune executables (NixOS hosts only)";
    nuphyGem80.enable = lib.mkEnableOption "device access for the NuPhy Gem80 configurator and firmware flashing";
    sshServer.enable = lib.mkEnableOption "an OpenSSH server that accepts only the user, authenticated by the OpenPGP card's authentication subkey (NixOS hosts only)";
    t3.cli.enable = lib.mkEnableOption "the headless T3 Code `t3` CLI";
    t3.desktop.enable = lib.mkEnableOption "the T3 Code desktop app (NixOS and macOS hosts only)";
    tlsInspectionCa.enable = lib.mkEnableOption "trust for the TLS inspection CA in secrets/hosts/<host>/tls-inspection-ca.yaml, through a combined CA bundle and macOS admin trust (macOS hosts only)";
    networkRecovery.enable = lib.mkEnableOption "a root daemon that repairs the network after a network switch leaves the Mac offline, and a shorter Claude Code stream idle timeout (macOS hosts only)";
    wiredNetwork.enable = lib.mkEnableOption "the static IPv4, DNS, and IPv6-off settings in secrets/hosts/<host>/wired-network.yaml for the wired adapter with the declared MAC, applied on production outputs: rendered into a NetworkManager profile on NixOS, reapplied on every switch on macOS";
  };
}
