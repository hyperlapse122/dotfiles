/*
  Check interface:

    import ./tests/bootstrap-recipients.nix { inherit pkgs; }

  Asserts that every per-host bootstrap recipient can actually decrypt the
  encrypted token document.

  Verifies:
  - Every hosts/<host>/ directory has a secrets/bootstrap/<host>/ directory,
    and every secrets/bootstrap/<host>/ directory has a hosts/<host>/
    directory.
  - Each secrets/bootstrap/<host>/ directory holds both age-key.asc and
    recipient.txt.

  secrets/tokens.yaml is encrypted to the recipients .sops.yaml names, so a
  host whose recipient is missing there installs a valid-looking identity and
  then fails at activation, far from the cause. Regenerating a host's identity
  without re-encrypting the tokens produces exactly that, and nothing else in
  the tree notices.
*/
{ pkgs }:
let
  inherit (pkgs) lib;

  bootstrap = ../secrets/bootstrap;

  directoriesIn = import ./lib/directories.nix { inherit lib; };

  hosts = directoriesIn bootstrap;

  hostDirs = directoriesIn ../hosts;

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
    set -x
    ${noHosts}
    ${unpaired}
    ${lib.concatStringsSep "\n" (map checkHost hosts)}
    python3 - ${../.sops.yaml} ${bootstrap} <<'PY'
    import json
    import pathlib
    import re
    import subprocess
    import sys

    def parse_yaml(text):
        return json.loads(subprocess.check_output(["yq", "-o=json", ".", "-"], input=text, text=True))

    def token_recipients(config):
        # Use the same Go regexp matching as SOPS and the ciphertext guard.
        # The first matching rule wins, including a catch-all without a regex.
        expression = '[.creation_rules[] | . as $rule | select("secrets/tokens.yaml" | test($rule.path_regex // ""))][0].age // ""'
        value = json.loads(subprocess.check_output(["yq", "-o=json", expression, "-"],
                                                 input=json.dumps(config), text=True))
        return {item.strip() for item in value.split(",") if item.strip()}

    def permitted(recipient, config):
        if not re.fullmatch(r"age1[023456789acdefghjklmnpqrstuvwxyz]{58}", recipient):
            return False
        valid = subprocess.run(["age", "--encrypt", "--recipient", recipient],
                               input=b"", stdout=subprocess.DEVNULL,
                               stderr=subprocess.DEVNULL).returncode == 0
        return valid and recipient in token_recipients(config)

    recipient = "age1mzqjkevvl4zvp272ecmpvjmp77espnaxz9uedjsmahkz7eecsdeqxkayjk"
    matching = {"path_regex": r"secrets/tokens\.yaml$", "age": recipient}
    assert permitted(recipient, {"creation_rules": [matching]})
    assert not permitted("", {"creation_rules": [matching]})
    assert not permitted("age1malformed", {"creation_rules": [matching]})
    assert not permitted(recipient[:-1], {"creation_rules": [matching]})
    assert not permitted(recipient[:-1] + "q", {"creation_rules": [matching]})
    assert not permitted(recipient, {"creation_rules": [dict(matching, age=recipient + "suffix")]})
    assert not permitted(recipient, parse_yaml("# " + recipient + "\ncreation_rules: []"))
    assert not permitted(recipient, {"creation_rules": [dict(matching, path_regex=r"secrets/wifi\.yaml$")]})
    assert not permitted(recipient, {"creation_rules": [dict(matching, age=""), matching]})
    assert not permitted(recipient, {"creation_rules": [{"age": ""}, matching]})
    assert permitted(recipient, {"creation_rules": [dict(matching, path_regex=r"secrets/wifi\.yaml$"), matching]})

    config = parse_yaml(pathlib.Path(sys.argv[1]).read_text())
    for host in sorted(pathlib.Path(sys.argv[2]).iterdir()):
        if host.is_dir():
            recorded = (host / "recipient.txt").read_text().strip()
            if not permitted(recorded, config):
                sys.exit(f"bootstrap recipient for {host.name} is invalid or absent from the first applicable secrets/tokens.yaml rule")
    PY
    touch $out
  ''
