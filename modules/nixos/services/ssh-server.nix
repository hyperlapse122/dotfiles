{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (config.my) user;
  # The SSH form of the authentication subkey of the user's OpenPGP card key,
  # read from the public key in the repository. The card that signs Git
  # commits also answers SSH logins, through whatever agent the client side
  # runs, so no separate key enters the repository. The build fails when the
  # key has no authentication subkey.
  authorizedKey =
    pkgs.runCommand "ssh-server-authorized-key" { nativeBuildInputs = [ pkgs.gnupg ]; }
      ''
        export GNUPGHOME=$(mktemp -d)
        gpg --batch --quiet --import ${../../../keys/signing.asc}
        gpg --batch --export-ssh-key ${user.gpgKey} > $out
      '';
in
{
  config = lib.mkIf config.my.sshServer.enable {
    services.openssh = {
      enable = true;
      settings = {
        PasswordAuthentication = false;
        KbdInteractiveAuthentication = false;
        PermitRootLogin = "no";
        AllowUsers = [ user.name ];
      };
    };
    # The file sshd reads for the user, sourced from the derivation directly:
    # openssh.authorizedKeys.keyFiles would read it during evaluation, which
    # builds it there.
    environment.etc."ssh/authorized_keys.d/${user.name}" = {
      source = authorizedKey;
      mode = "0444";
    };
  };
}
