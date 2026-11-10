/*
  Check interface:

    import ./tests/ssh-server.nix { inherit pkgs self; }

  Asserts what modules/nixos/services/ssh-server.nix produces, reading the
  materialised /etc tree. The expected authorized key is exported here from
  keys/signing.asc by the authentication subkey's own ID, never taken from the
  module under test.

  On every configuration that enables `my.sshServer.enable` (each production
  configuration re-evaluated with it forced on when none enables it):
  - multi-user.target wants an sshd.service that runs sshd.
  - sshd_config disables password and keyboard-interactive login and root
    login, and allows only the user.
  - the user's authorized_keys.d file holds exactly the SSH form of the
    authentication subkey 0x1E305FCE7BE9F27D, and no other key.

  On every configuration that leaves it off: no sshd.service is wanted and no
  sshd_config is materialised.

  The builder collects every failure before it exits.
*/
{ pkgs, self }:
let
  inherit (pkgs) lib;

  configurations = import ./lib/configurations.nix { inherit pkgs self; };
  sshServer = configurations.withTrait "my.sshServer.enable" (config: config.my.sshServer.enable);
  etcFile = import ./lib/etc-file.nix { inherit lib; };

  esc = value: lib.escapeShellArg (toString value);

  fail = message: ''
    echo ${esc message} >&2
    failed=1
  '';

  # The trailing ! makes gpg export this subkey rather than whichever one it
  # would pick for the primary key.
  expectedKey = pkgs.runCommand "ssh-server-expected-key" { nativeBuildInputs = [ pkgs.gnupg ]; } ''
    export GNUPGHOME=$(mktemp -d)
    gpg --batch --quiet --import ${../keys/signing.asc}
    gpg --batch --export-ssh-key '0x1E305FCE7BE9F27D!' > $out
  '';

  assertEnabled =
    entry:
    let
      inherit (entry) config name;
      units = etcFile config "systemd/system";
      sshdConfig = etcFile config "ssh/sshd_config";
      keys = etcFile config "ssh/authorized_keys.d/${config.my.user.name}";
    in
    ''
      ${lib.optionalString (units == null) (
        fail "${name}: the built system declares no systemd unit tree"
      )}
      ${lib.optionalString (units != null) ''
        if ! grep -qs '^ExecStart=.*/sshd ' ${esc "${units}/multi-user.target.wants/sshd.service"}; then
          ${fail "${name}: multi-user.target does not want an sshd.service that runs sshd"}
        fi
      ''}
      ${lib.optionalString (sshdConfig == null) (fail "${name}: no /etc/ssh/sshd_config is materialised")}
      ${lib.optionalString (sshdConfig != null) ''
        for line in 'PasswordAuthentication no' 'KbdInteractiveAuthentication no' 'PermitRootLogin no' ${esc "AllowUsers ${config.my.user.name}"}; do
          if ! grep -Fxq -- "$line" ${esc sshdConfig}; then
            report ${esc name}": sshd_config lacks $line"
          fi
        done
      ''}
      ${lib.optionalString (keys == null) (
        fail "${name}: no authorized_keys.d file is materialised for ${config.my.user.name}"
      )}
      ${lib.optionalString (keys != null) ''
        if [ "$(grep -v '^[[:space:]]*$' ${esc keys})" != "$(cat ${expectedKey})" ]; then
          ${fail "${name}: the authorized keys are not exactly the card's authentication subkey"}
        fi
      ''}
    '';

  assertDisabled =
    entry:
    let
      inherit (entry) config name;
      units = etcFile config "systemd/system";
    in
    ''
      ${lib.optionalString (units != null) ''
        if [ -e ${esc "${units}/multi-user.target.wants/sshd.service"} ]; then
          ${fail "${name}: my.sshServer.enable is off but multi-user.target wants sshd.service"}
        fi
      ''}
      ${lib.optionalString (etcFile config "ssh/sshd_config" != null) (
        fail "${name}: my.sshServer.enable is off but an sshd_config is materialised"
      )}
    '';
in
pkgs.runCommand "ssh-server-tests" { nativeBuildInputs = [ pkgs.gnugrep ]; } ''
  set -x
  ${configurations.guard}
  ${sshServer.guard}
  failed=0
  report() {
    echo "$1" >&2
    failed=1
  }

  ${lib.concatMapStringsSep "\n" assertEnabled sshServer.enabled}
  ${lib.concatMapStringsSep "\n" assertDisabled sshServer.disabled}

  if [ "$failed" != 0 ]; then
    exit 1
  fi
  touch $out
''
