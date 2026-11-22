{ pkgs, agentTools }:
let
  inherit (agentTools) agentSettingsPython;
  packaged = agentTools.agentSettings;
in
pkgs.runCommand "agent-settings-tests" { nativeBuildInputs = [ agentSettingsPython ]; } ''
  export PYTHONDONTWRITEBYTECODE=1
  mkdir -p scripts tests
  cp ${../scripts/agent-settings} scripts/agent-settings
  cp ${./test_agent_settings.py} tests/test_agent_settings.py
  python tests/test_agent_settings.py

  # Activation runs the packaged binary, not this source copy, and its
  # unit's PATH carries no python3. Exercise the built file so a lost
  # +x bit or an unpatched `#!/usr/bin/env python3` fails here rather
  # than at activation.
  interpreter=$(head -1 ${packaged}/bin/agent-settings)
  case "$interpreter" in
    '#!'/nix/store/*) ;;
    *)
      echo "packaged merger must carry a store interpreter, got: $interpreter" >&2
      exit 1
      ;;
  esac

  # TOML mode through the packaged binary, which proves the built
  # interpreter carries tomlkit: a comment and a table the merge does
  # not own must survive, and the declared leaves start divergent.
  mkdir -p home/.codex
  printf '# keep me\ncheck_for_update_on_startup = true\ndeveloper_instructions = "stale"\n\n[features]\nmemories = true\n\n[plugins."x"]\nenabled = true\n' \
    > home/.codex/config.toml
  printf '{"remove":["developer_instructions"],"setPaths":[{"path":["check_for_update_on_startup"],"value":false},{"path":["features","memories"],"value":false},{"path":["features","daemon_auto_start"],"value":false}]}\n' \
    > codex.json
  env -i ${packaged}/bin/agent-settings --format toml --label Codex \
    --settings "$PWD/home/.codex/config.toml" --declared "$PWD/codex.json"
  grep -qxF '# keep me' home/.codex/config.toml
  ${pkgs.python3}/bin/python3 - <<'PY'
  import tomllib
  merged = tomllib.load(open('home/.codex/config.toml', 'rb'))
  assert merged == {'check_for_update_on_startup': False, 'features': {'memories': False, 'daemon_auto_start': False}, 'plugins': {'x': {'enabled': True}}}, merged
  PY

  # Malformed TOML must fail the process and leave the file alone.
  printf 'model = "unterminated\n' > home/.codex/config.toml
  if env -i ${packaged}/bin/agent-settings --format toml --label Codex \
      --settings "$PWD/home/.codex/config.toml" --declared "$PWD/codex.json"; then
    echo "packaged merger accepted malformed TOML" >&2
    exit 1
  fi
  if [ "$(cat home/.codex/config.toml)" != 'model = "unterminated' ]; then
    echo "refused TOML merge still rewrote the settings file" >&2
    exit 1
  fi

  touch $out
''
