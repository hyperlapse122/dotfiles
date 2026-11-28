{ pkgs, self }:
let
  inherit (pkgs) lib;
  configurations = import ./lib/configurations.nix { inherit pkgs self; };
  etcSource = import ./lib/etc-file.nix { inherit lib; };
  esc = value: lib.escapeShellArg (toString value);
  production = map (entry: {
    inherit entry;
    hostPkgs = self.nixosConfigurations.${entry.name}.pkgs;
  }) configurations.production;
  cpu = map (entry: {
    entry = configurations.withTraitForcedOff "my.cuda.enable" entry;
    hostPkgs = self.nixosConfigurations.${entry.name}.pkgs;
  }) configurations.production;
  assertProduction =
    { entry, hostPkgs }:
    let
      inherit (entry) config name;
      user = config.my.user.name;
      units = etcSource config "systemd/user";
      package = import ../packages/ollama.nix {
        pkgs = hostPkgs;
        cudaSupport = config.my.cuda.enable;
      };
      service = "${toString units}/ollama.service";
      hasPackage = builtins.any (p: toString p == toString package) config.environment.systemPackages;
    in
    ''
      ${lib.optionalString (
        !config.users.users.${user}.linger
      ) "echo ${esc "${name}: owner does not linger"} >&2; exit 1"}
      ${lib.optionalString (
        !hasPackage
      ) "echo ${esc "${name}: selected Ollama package is not installed"} >&2; exit 1"}
      ${lib.concatMapStrings
        (line: ''
          grep -Fx -- ${esc line} ${esc service} >/dev/null || { echo ${esc "${name}: missing server setting ${line}"} >&2; exit 1; }
        '')
        [
          "ConditionUser=${user}"
          "Environment=\"OLLAMA_HOST=127.0.0.1:11434\""
          "Environment=\"OLLAMA_NO_CLOUD=1\""
          "ExecStart=${lib.getExe package} serve"
          "Restart=on-failure"
        ]
      }
      [ "$(readlink ${esc "${toString units}/default.target.wants/ollama.service"})" = "../ollama.service" ] || { echo ${esc "${name}: default.target does not want the Ollama server"} >&2; exit 1; }
      [ ! -e ${esc "${toString units}/ollama-provision.service"} ] || { echo ${esc "${name}: the retired model provisioning unit is still declared"} >&2; exit 1; }
    '';
  assertBootstrap =
    entry:
    let
      units = etcSource entry.config "systemd/user";
      user = entry.config.my.user.name;
    in
    ''
      ${lib.optionalString (
        entry.config.users.users.${user}.linger == true
      ) "echo ${esc "${entry.name}: bootstrap owner lingers"} >&2; exit 1"}
      for unit in ollama.service ollama-provision.service; do
        [ ! -e ${esc (toString units)}/"$unit" ] && [ ! -L ${esc (toString units)}/default.target.wants/"$unit" ] || { echo ${esc "${entry.name}: Ollama enabled in bootstrap"} >&2; exit 1; }
      done
    '';
in
pkgs.runCommand "ollama-user-service-tests" { } ''
  ${configurations.guard}
  ${lib.concatMapStringsSep "\n" assertProduction (production ++ cpu)}
  ${lib.concatMapStringsSep "\n" assertBootstrap configurations.bootstraps}
  touch $out
''
