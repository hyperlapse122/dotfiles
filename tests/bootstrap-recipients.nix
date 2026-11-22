/*
  Check interface:

    import ./tests/bootstrap-recipients.nix { inherit pkgs; }

  Pairs each host with its bootstrap files and checks that the first matching
  creation rule for every shared CLI credential file grants access to exactly
  those hosts. The legacy rule supplies the same recipient set for rollback.
  Docker registry credentials may go only to recorded NixOS recipients.
*/
{ pkgs }:
let
  inherit (pkgs) lib;

  bootstrap = ../secrets/bootstrap;
  credentials = lib.importJSON ../modules/shared/cli-credentials.json;
  sharedCredentials = lib.filterAttrs (_: spec: spec.darwin or true) credentials;
  groups = lib.unique (lib.mapAttrsToList (_: spec: spec.group) sharedCredentials);
  sharedPaths = map (group: "secrets/${group}.yaml") (groups ++ [ "tokens" ]);

  directoriesIn = import ./lib/directories.nix { inherit lib; };

  hosts = directoriesIn bootstrap;

  hostDirs = directoriesIn ../hosts;
  nixosHosts = (import ../lib/hosts.nix { inherit lib; } ../hosts).nixos;

  hasFile = host: name: builtins.pathExists (bootstrap + "/${host}/${name}");

  checkHost =
    host:
    if !hasFile host "age-key.asc" then
      ''
        echo 'secrets/bootstrap/${host} has no age-key.asc' >&2
        exit 1
      ''
    else if !hasFile host "recipient.txt" then
      ''
        echo 'secrets/bootstrap/${host} has no recipient.txt' >&2
        exit 1
      ''
    else
      ''
        echo 'ok: ${host}'
      '';

  # Each missing side is reported by name before the check fails, so one run
  # lists every unpaired directory.
  unpaired =
    let
      withoutBootstrap = lib.subtractLists hosts hostDirs;
      withoutHost = lib.subtractLists hostDirs hosts;
    in
    lib.optionalString (withoutBootstrap != [ ] || withoutHost != [ ]) ''
      ${lib.concatMapStrings (host: ''
        echo 'hosts/${host} has no matching secrets/bootstrap/${host}' >&2
      '') withoutBootstrap}
      ${lib.concatMapStrings (host: ''
        echo 'secrets/bootstrap/${host} has no matching hosts/${host}' >&2
      '') withoutHost}
      exit 1
    '';

  noHosts = lib.optionalString (hosts == [ ]) ''
    echo 'no per-host bootstrap material under secrets/bootstrap' >&2
    exit 1
  '';
in
pkgs.runCommand "bootstrap-recipients-tests"
  {
    nativeBuildInputs = [
      pkgs.python3
      pkgs.yq-go
      pkgs.age
    ];
  }
  ''
    ${noHosts}
    ${unpaired}
    ${lib.concatStringsSep "\n" (map checkHost hosts)}
    python3 - ${../.sops.yaml} ${bootstrap} ${lib.escapeShellArg (builtins.toJSON nixosHosts)} ${lib.escapeShellArgs sharedPaths} <<'PY'
    import json
    import os
    import pathlib
    import subprocess
    import sys

    def rule_recipients(config, path):
        # SOPS uses the first matching Go regexp, including a catch-all.
        expression = '[.creation_rules[] | . as $rule | select(strenv(SECRET_PATH) | test($rule.path_regex // ""))][0].age // ""'
        value = subprocess.check_output(["yq", "-r", expression, "-"], input=config,
                                        env=dict(os.environ, SECRET_PATH=path), text=True)
        return {item.strip() for item in value.split(",") if item.strip()}

    recorded = {}
    for host in sorted(pathlib.Path(sys.argv[2]).iterdir()):
        if host.is_dir():
            recipient = (host / "recipient.txt").read_text().strip()
            valid = subprocess.run(["age", "--encrypt", "--recipient", recipient],
                                   input=b"", stdout=subprocess.DEVNULL,
                                   stderr=subprocess.DEVNULL).returncode == 0
            if not valid or not recipient.startswith("age1"):
                sys.exit(f"bootstrap recipient for {host.name} is invalid")
            if recipient in recorded.values():
                sys.exit(f"bootstrap recipient for {host.name} is shared with another host")
            recorded[host.name] = recipient

    config = pathlib.Path(sys.argv[1]).read_text()
    for path in sys.argv[4:]:
        if rule_recipients(config, path) != set(recorded.values()):
            sys.exit(f"{path}: creation rule recipients must match the recorded bootstrap recipients")

    docker_path = "secrets/docker-registry.yaml"
    nixos_recipients = {recorded[host] for host in json.loads(sys.argv[3])}
    docker_recipients = rule_recipients(config, docker_path)
    if not docker_recipients or not docker_recipients <= nixos_recipients:
        sys.exit(f"{docker_path}: expected only recorded NixOS recipients")

    fake = "age1mzqjkevvl4zvp272ecmpvjmp77espnaxz9uedjsmahkz7eecsdeqxkayjk"
    for path in sys.argv[4:]:
        match = {"path_regex": "^" + path.replace(".", r"\.") + "$", "age": fake}
        other = {"path_regex": r"^secrets/wifi\.yaml$", "age": ""}
        fixtures = [
            ([other, match], {fake}),
            ([dict(match, age=""), match], set()),
            ([{"age": ""}, match], set()),
            ([dict(match, age=fake + "suffix")], {fake + "suffix"}),
        ]
        for rules, expected in fixtures:
            assert rule_recipients(json.dumps({"creation_rules": rules}), path) == expected
        assert rule_recipients(f"# {fake}\ncreation_rules: []", path) == set()
    PY
    touch $out
  ''
