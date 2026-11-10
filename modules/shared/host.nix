{ lib, ... }:
{
  # Host facts and traits, declared once and imported by every assembly: the
  # NixOS system, the Home Manager user inside it, and the standalone Home
  # Manager and system-manager outputs of a non-NixOS host. Modules and checks
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
        "linux"
        "darwin"
      ];
      default = "nixos";
      description = "Whether the host runs NixOS, another Linux distribution, or macOS.";
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

    gpgAgentRelay = {
      enable = lib.mkEnableOption "a relay that serves gpg from a remote gpg-agent over TCP, in place of a local agent and card reader";
      endpoint = lib.mkOption {
        type = lib.types.nullOr (lib.types.strMatching "[^:[:space:]]+:[0-9]+");
        default = null;
        example = "192.168.250.1:4321";
        description = "The `host:port` the remote agent's relay listens on. Required when the relay is enabled.";
      };
    };
    sshServer.enable = lib.mkEnableOption "an OpenSSH server that accepts only the user, authenticated by the OpenPGP card's authentication subkey (NixOS hosts only)";
    t3.cli.enable = lib.mkEnableOption "the headless T3 Code `t3` CLI";
    t3.desktop.enable = lib.mkEnableOption "the T3 Code desktop app (NixOS and macOS hosts only)";
    wifiman.enable = lib.mkEnableOption "UniFi WiFiman Desktop and its root daemon (NixOS hosts only)";
    tlsInspectionCa.enable = lib.mkEnableOption "trust for the TLS inspection CA in secrets/hosts/<host>/tls-inspection-ca.yaml, through a combined CA bundle and macOS admin trust (macOS hosts only)";
    networkRecovery.enable = lib.mkEnableOption "a root daemon that repairs the network after a network switch leaves the Mac offline, and a shorter Claude Code stream idle timeout (macOS hosts only)";
  };
}
