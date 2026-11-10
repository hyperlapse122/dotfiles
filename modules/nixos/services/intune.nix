{
  config,
  lib,
  pkgs,
  ...
}:
let
  # One definition feeds both the rule the system enforces and the line the
  # Intune agent reads, so the declared policy is never stricter than the
  # real one. The tenant's thresholds are unknown until enrollment; raise
  # these when its password check asks for more.
  passwordPolicy = {
    minlen = 12;
    dcredit = -1;
    ucredit = -1;
    lcredit = -1;
    ocredit = -1;
  };
  passwordPolicyArgs = lib.mapAttrsToList (name: value: "${name}=${toString value}") passwordPolicy;
in
{
  # Edge, which signs in through the identity broker, comes from
  # home/h82/default.nix under the same trait.
  config = lib.mkIf config.my.intune.enable {
    # Installs both packages, their units and D-Bus services, and pam_intune.so,
    # which records the login password's quality in /run/intune/<uid>/pwquality
    # for the agent's password check.
    services.intune.enable = true;

    # The upstream module and its PAM rule take both packages from pkgs and
    # offer no package option, so the Ubuntu identity reaches them here.
    # intune-daemon reads no os-release file and stays unwrapped.
    nixpkgs.overlays = [
      (
        final: prev:
        let
          identity = final.callPackage ../../../packages/intune-ubuntu-identity.nix { };
        in
        {
          intune-portal = identity.wrap prev.intune-portal [
            "intune-portal"
            "intune-agent"
          ];
          microsoft-identity-broker = identity.wrap prev.microsoft-identity-broker [
            "microsoft-identity-broker"
            "microsoft-identity-device-broker"
            "dsreg"
          ];
        }
      )
    ];

    # Both units ship an [Install] section, which NixOS ignores for a packaged
    # unit. Without the socket the app and agent cannot reach the daemon, and
    # without the timer the device checks in only while the app is open.
    systemd.sockets.intune-daemon.wantedBy = [ "sockets.target" ];
    systemd.user.timers.intune-agent.wantedBy = [ "graphical-session.target" ];

    security.pam.services.passwd.rules.password = {
      pwquality = {
        order = config.security.pam.services.passwd.rules.password.unix.order - 10;
        control = "requisite";
        modulePath = "${pkgs.libpwquality.lib}/lib/security/pam_pwquality.so";
        args = passwordPolicyArgs;
      };
      # Without this pam_unix asks for the new password again and takes
      # whatever is typed the second time, past the quality rule.
      unix.settings.use_authtok = true;
    };

    # The agent also parses a pam_pwquality line from this Ubuntu path. No PAM
    # service uses the file, so it names the module as Ubuntu does rather than
    # by store path.
    environment.etc."pam.d/common-password".text = ''
      password requisite pam_pwquality.so ${lib.concatStringsSep " " passwordPolicyArgs}
    '';
  };
}
