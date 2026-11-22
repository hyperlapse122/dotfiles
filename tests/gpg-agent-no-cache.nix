{ pkgs, self }:
let
  inherit (import ./lib/host-check-helpers.nix { inherit pkgs self; }) forEveryUser;
  assertConfiguration =
    entry:
    let
      homedir = entry.user.programs.gpg.homedir or null;
      home = entry.user.home.homeDirectory or "";
      homeFiles = entry.user.home-files or null;
      gpgAgentConf =
        if homedir == null || homeFiles == null then
          null
        else
          "${homeFiles}/${pkgs.lib.removePrefix "${home}/" homedir}/gpg-agent.conf";
    in
    ''
      ${pkgs.lib.optionalString (gpgAgentConf == null) ''
        echo 'missing gpg-agent.conf on ${entry.name}' >&2
        fail=1
      ''}
      ${pkgs.lib.optionalString (gpgAgentConf != null) ''
        if [ ! -f ${pkgs.lib.escapeShellArg gpgAgentConf} ] || ! grep -Fxq 'default-cache-ttl 0' ${pkgs.lib.escapeShellArg gpgAgentConf}; then
          echo 'gpg-agent.conf no longer sets default-cache-ttl 0 on ${entry.name}' >&2
          fail=1
        fi
        python3 ${./personal-environment.py} gpg ${entry.user.home-files}
        if ! grep -Fxq 'max-cache-ttl 0' ${gpgAgentConf}; then
          echo 'gpg-agent.conf no longer sets max-cache-ttl 0 on ${entry.name}' >&2
          fail=1
        fi
        # Any further cache lifetime, ssh variants included, reintroduces the
        # agent-side cache the card PIN handling is built on doing without.
        if grep -E 'cache-ttl' ${gpgAgentConf} | grep -qvE '^[a-z-]*cache-ttl(-ssh)? 0$'; then
          echo 'gpg-agent.conf sets a non-zero cache lifetime on ${entry.name}' >&2
          fail=1
        fi
      ''}
    '';
in
pkgs.runCommand "gpg-agent-no-cache-tests"
  {
    nativeBuildInputs = [
      pkgs.gnugrep
      pkgs.python3
    ];
  }
  ''
    set -x
    ${forEveryUser assertConfiguration}
    touch $out
  ''
