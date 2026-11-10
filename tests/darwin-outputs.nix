/*
  Check interface:

    import ./tests/darwin-outputs.nix { inherit pkgs darwinFixtures darwinConfigurations; }

  `pkgs` is nixpkgs for aarch64-darwin and `darwinFixtures` is
  tests/lib/darwin-fixtures.nix. Builds on a macOS builder only, and reads
  what the macOS fixture hosts materialize, both variants, where
  tests/darwin-config.nix reads their options on Linux:

  - the Home Manager activation script stages host secrets before
    writeBoundary and publishes them after linkGeneration, in production
    only;
  - the session names the Podman machine's API socket and no Ryuk privilege
    variable, the generation links no containers/ or systemd user file, the
    containers.conf activation installs selects libkrun, `docker` is the
    profile's `podman`, the machine watchdog's agent abandons its process
    group at interactive priority, a login agent exports the socket to GUI
    apps, and the minikube login agent exists in production only;
  - the session and a login agent at load set CROSS_MODEL_PEERS to the
    peers the installed packages call for (tests/lib/cross-model-peers.nix),
    codex among them, and CROSS_MODEL_MAX_PEERS to 2;
  - a login agent at load sets CLAUDE_CODE_EVEN_MORE_DANGEROUSLY_SKIP_PERMISSIONS
    to 1 for GUI apps, both variants;
  - the retireOrca activation, run in scratch homes, removes Orca's agent
    hooks, status line, and state directories, ~/Library/Application
    Support/orca included, and keeps what other tools wrote
    (tests/test_retire_orca.py);
  - gpg-agent.conf names the darwin pinentry filter, whose proxy delegates to
    pinentry_mac, with both cache TTLs at 0, and scdaemon.conf is the shared
    one; activation imports pinentry_mac's defaults with UseKeychain false;
  - Ghostty's config lists the NixOS font families in order;
  - `nr` on PATH is nr-darwin;
  - installed OMP credential helpers read the user's secret state directory;
  - serve-html on PATH is the packaged helper the shared instructions name;
  - agy on PATH is the pinned Antigravity CLI, agy_acp_server.par execs the
    runtime built from packages/antigravity-acp-release.json and sets no
    SSL_CERT_FILE, because the macOS .par finds its CA bundle itself, and
    localharness_external beside it is that runtime's;
  - the VSCodium settings merge targets Application Support;
  - grok on PATH resolves to the grok-build wrapper, and the profile has no
    `agent` executable;
  - sccache is on PATH, and the Cargo settings merge updates
    ~/.cargo/config.toml with the profile sccache wrapper while preserving
    unowned state;
  - ~/Library/Android/sdk holds what T3 Code's device hub needs:
    cmdline-tools/latest/bin/avdmanager, platform-tools/adb, an arm64-v8a
    Google APIs system.img for every platform the pin file names, and an
    emulator/emulator wrapper that defaults ANDROID_HOME and ANDROID_SDK_ROOT
    to ~/Library/Android/sdk before it execs the store emulator; the session
    sets ANDROID_HOME and ANDROID_SDK_ROOT to that path, and its PATH
    assignment gains the emulator directory;
  - the activation script runs the mobileDevices step after linkGeneration,
    and it calls the built mobile-devices helper with /usr/bin/xcrun, the SDK
    root, a --java-home whose bin/java runs, every declared device, and the
    newest pinned API with an arm64-v8a image;
  - with my.t3.desktop.enable, the T3 Code nightly bundle is in the profile,
    its main executable is byte-identical to the release zip's, and a launch
    agent sets T3CODE_DISABLE_AUTO_UPDATE=1;
  - the system's nix.conf keeps store auto-optimisation off,
    /etc/nix-config-host records the host and variant, the Brewfile lists the
    expected casks, the shared fonts are installed, and activation turns on
    automatic appearance without pinning AppleInterfaceStyle;
  - running the activation's user-defaults block with stub commands writes,
    as the primary user, exactly the Dock's persistent-apps,
    persistent-others, show-recents, and tilesize, each with the value its
    option holds, then restarts that user's Dock; nothing else in activation
    touches com.apple.dock;
  - the system activate script runs the Xcode step, mas through launchctl
    asuser for App Store id 497799835, after brew bundle and before the Home
    Manager activation call, then the KakaoTalk step for App Store id
    869223134, through its own launchctl asuser wrapper, then the Flighty
    step for App Store id 1358823008, before that call;
  - the retired-cask step runs after the Flighty step and before the Home
    Manager activation call, with every brew call going through /usr/bin/sudo
    as the primary user with the absolute brew path; it uninstalls the
    grok-bot and orca casks, then untaps stablyai/orca, which
    tests/retired-brew-effects.py runs against a recording brew stub;
  - with the TLS inspection CA trait, production shells and a RunAtLoad
    login agent set all six CA variables to
    /etc/ssl/nix-config/ca-certificates.crt, nix-daemon's plist names it, the
    bundle step runs before /etc and the trust step after; bootstrap keeps
    the default bundle and has neither step nor agent;
  - with the network recovery trait, production loads a root daemon at load
    and every 5 seconds that runs the packaged network-recovery script with
    /var/db/network-recovery and the Tailscale app's CLI, logging to
    /var/log/network-recovery.log, which newsyslog rotates; bootstrap has
    neither the daemon nor the rotation entry;
  - the nix-homebrew setup script is built with autoMigrate on, so the first
    apply takes over an existing /opt/homebrew instead of stopping.

  Every comparison is rendered into the builder, so a failure names the
  fixture and the reason.
*/
{
  pkgs,
  darwinFixtures,
  darwinConfigurations,
}:
let
  inherit (pkgs) lib;
  streamTimeoutEffects = pkgs.writeText "claude-stream-timeout-effects.py" ''
    import os, plistlib, re, subprocess, sys, tempfile
    from pathlib import Path

    generation = Path(sys.argv[1])
    enabled = sys.argv[2] == "1"
    body = (generation / "activate").read_text()
    marker = '_iNote "Activating %s" "claudeStreamTimeout"\n'
    assert marker in body, "missing GUI timeout activation"
    step = body.split(marker, 1)[1].split('_iNote "Activating %s"', 1)[0]
    agent = generation / "LaunchAgents/org.nix-community.home.claude-stream-timeout.plist"
    assert agent.exists() == enabled, "GUI timeout login agent has the wrong trait gate"
    with tempfile.TemporaryDirectory() as scratch:
        root = Path(scratch)
        state = root / "environment"
        stub = root / "launchctl"
        stub.write_text("""#!/bin/sh
    case "$2" in CLAUDE_BYTE_STREAM_IDLE_TIMEOUT_MS) ;; *) exit 1 ;; esac
    case "$1" in
      setenv) printf '%s' "$3" > "$TIMEOUT_STATE" ;;
      getenv) cat "$TIMEOUT_STATE" ;;
      unsetenv) rm "$TIMEOUT_STATE" ;;
      *) exit 1 ;;
    esac
    """)
        stub.chmod(0o755)
        env = dict(os.environ, HOME=scratch, TIMEOUT_STATE=str(state))
        env.pop("DRY_RUN", None)
        for initial in ("60000", "90000"):
            state.write_text(initial)
            subprocess.run(["bash", "-euo", "pipefail", "-c", step.replace("/bin/launchctl", str(stub))], env=env, check=True)
            expected = "60000" if enabled else (None if initial == "60000" else initial)
            assert (state.read_text() if state.exists() else None) == expected, "activation failed to publish or retire its GUI timeout"
        if enabled:
            with agent.open("rb") as source:
                plist = plistlib.load(source)
            assert plist["RunAtLoad"] is True, "timeout is not published on login"
            argv = [arg.replace("/bin/launchctl", str(stub)) for arg in plist["ProgramArguments"]]
            state.unlink()
            subprocess.run(argv, env=env, check=True)
            assert state.read_text() == "60000", "login agent failed to publish the timeout"
  '';
  instructionDelivery = import ./agent-instructions.nix {
    inherit pkgs;
    entries = map (entry: {
      inherit (entry) name;
      user = entry.host.config.home-manager.users.${entry.host.config.my.user.name} or { };
    }) (darwinFixtures ++ lib.mapAttrsToList (name: host: { inherit name host; }) darwinConfigurations);
  };

  # The declared values belong to tests/codex-settings.nix; this reads them
  # from the file the step hands the merge, so it checks only their effect.
  codexEffects = pkgs.writeText "codex-activation-effects.py" ''
    import json, os, re, subprocess, sys, tempfile, tomllib
    from pathlib import Path
    body = Path(sys.argv[1]).read_text()
    original = sys.argv[2]
    declared = json.loads(Path(re.search(r"--declared (\S+)", body)[1]).read_text())
    with tempfile.TemporaryDirectory() as work:
        home = Path(work) / "home"
        target = home / ".codex/config.toml"
        target.parent.mkdir(parents=True)
        redirected = body.replace(original, str(home))
        assert redirected != body and original not in redirected, "Codex destination was not redirected"
        env = dict(os.environ, HOME=str(home), CODEX_HOME=str(home / ".codex"))
        env.pop("DRY_RUN", None)
        def run():
            return subprocess.run(["bash", "-euo", "pipefail", "-c", redirected], env=env, capture_output=True, text=True)
        seed = 'model = "old-model"\nmodel_reasoning_effort = "old-effort"\nservice_tier = "old-tier"\ncheck_for_update_on_startup = true\ndeveloper_instructions = "retired"\ncustom = "keep"\n[agents]\ndefault_subagent_model = "old-child"\ndefault_subagent_reasoning_effort = "old-effort"\nmax_threads = 3\n[features]\nin_app_updates = true\ndaemon_auto_start = true\nmemories = true\ncomputer_use = true\ncustom = true\n[plugins."computer-use@openai-bundled"]\nenabled = true\n[plugins."unified-computer-use@openai-bundled"]\nenabled = true\n'
        expected = tomllib.loads(seed)
        for key in declared["remove"]:
            assert key in expected, f"seed lacks retired key {key}"
            del expected[key]
        for entry in declared["setPaths"]:
            *parents, leaf = entry["path"]
            table = expected
            for part in parents:
                table = table[part]
            assert table.get(leaf) != entry["value"], f"seed already holds declared {entry['path']}"
            table[leaf] = entry["value"]
        for entry in declared.get("ownEntries", []):
            table = expected
            for part in entry["path"]:
                table = table.setdefault(part, {})
            table.update(entry["entries"])
        target.write_text(seed)
        result = run()
        assert result.returncode == 0, result.stderr
        actual = tomllib.loads(target.read_text())
        assert actual == expected, "Codex activation did not apply declarations, retire keys, and preserve unmanaged state"
        assert actual["check_for_update_on_startup"] is False
        fff = actual.get("mcp_servers", {}).get("fff", {})
        assert fff.get("command", "").startswith("/nix/store/") and fff["command"].endswith("/bin/fff-mcp"), "Codex must start the fff MCP server by its store path"
        assert os.access(fff["command"], os.X_OK), "the fff MCP server command is not executable"
        assert fff.get("args") == ["--no-update-check"], "the fff MCP server must run without its update check"
        assert all(actual["features"][key] is False for key in ["in_app_updates", "daemon_auto_start", "memories"]), "Codex settings must be TOML booleans"
        protected = b'[features\nmalformed = true\n'
        target.write_bytes(protected)
        result = run()
        assert result.returncode != 0, "Codex activation swallowed malformed-input refusal"
        assert target.read_bytes() == protected, "Codex activation altered protected malformed input"
  '';

  cargoEffects = pkgs.writeText "cargo-activation-effects.py" ''
    import os, subprocess, sys, tempfile, tomllib
    from pathlib import Path
    body = Path(sys.argv[1]).read_text()
    original = sys.argv[2]
    wrapper = sys.argv[3]
    with tempfile.TemporaryDirectory() as work:
        home = Path(work) / "home"
        target = home / ".cargo/config.toml"
        home.mkdir(parents=True)
        redirected = body.replace(original, str(home))
        assert redirected != body and original not in redirected, "Cargo destination was not redirected"
        env = dict(os.environ, HOME=str(home))
        env.pop("DRY_RUN", None)
        def run():
            return subprocess.run(["bash", "-euo", "pipefail", "-c", redirected], env=env, capture_output=True, text=True)
        result = run()
        assert result.returncode == 0, result.stderr
        assert tomllib.loads(target.read_text()) == {"build": {"rustc-wrapper": wrapper}}, "Cargo activation did not initialize missing config.toml"
        target.write_text('# user comment\n[build]\njobs = 4\nrustc-wrapper = "old"\n[alias]\nb = "build"\n[net]\ngit-fetch-with-cli = true\n')
        result = run()
        assert result.returncode == 0, result.stderr
        rendered = target.read_text()
        assert "# user comment" in rendered, "Cargo activation dropped user TOML comment"
        assert tomllib.loads(rendered) == {
            "build": {"jobs": 4, "rustc-wrapper": wrapper},
            "alias": {"b": "build"},
            "net": {"git-fetch-with-cli": True},
        }, "Cargo activation did not apply build.rustc-wrapper and preserve unmanaged state"
        protected = b'[build\nmalformed = true\n'
        target.write_bytes(protected)
        result = run()
        assert result.returncode != 0, "Cargo activation swallowed malformed-input refusal"
        assert target.read_bytes() == protected, "Cargo activation altered protected malformed input"
  '';

  authEffects = ./lib/containers-auth-effects.py;

  # Runs the activation's user-defaults block with stub commands and compares
  # its Dock writes with the Dock options; tests/darwin-config.nix owns what
  # those options must be.
  dockWrites = ./lib/dock-writes.py;

  mapping = import ../modules/shared/darwin-apps.nix;
  expectedCasks = lib.sort lib.lessThan mapping.casks;

  androidPin = import ./lib/android-pin.nix { inherit lib; };
  expectedPeers = import ./lib/cross-model-peers.nix { inherit lib; };

  fontFamilies = [
    "JetBrainsMono Nerd Font"
    "D2CodingLigature Nerd Font"
    "D2KodingLigature Nerd Font"
    "Twitter Color Emoji"
  ];

  assertEntry =
    entry:
    let
      config = entry.host.config;
      user = config.home-manager.users.${config.my.user.name};
      generation = user.home.activationPackage;
      state = user.my.secrets.stateDir;
      system = entry.host.system;
      t3Desktop = lib.findFirst (p: (p.pname or "") == "t3code-desktop") null user.home.packages;
      production = if entry.bootstrap then "0" else "1";
      deviceArgs = map androidPin.deviceArg (user.my.mobileDevices or [ ]);
      androidSdkRoot = "${config.my.user.home}/Library/Android/sdk";
      masExe = lib.getExe entry.host.pkgs.mas;
      brewExe = "${config.homebrew.prefix}/bin/brew";
      peers = lib.concatStringsSep "," (expectedPeers user.home.packages);
      grokPkg = import ../packages/grok-build.nix { inherit (entry.host) pkgs; };
      serveHtmlPackage =
        (import ../packages/agent-tools.nix { inherit (entry.host) pkgs; }).serveHtml or null;
      serveHtml = lib.optionalString (serveHtmlPackage != null) (lib.getExe serveHtmlPackage);
      agy = "${import ../packages/antigravity-cli.nix { inherit (entry.host) pkgs; }}/bin/agy";
      antigravityRuntime = "${
        import ../packages/antigravity-acp.nix {
          inherit (entry.host) pkgs;
          pins = (builtins.fromJSON (builtins.readFile ../packages/antigravity-acp-release.json)).platforms;
        }
      }/libexec/antigravity-acp";
      # Only these four Dock keys may be written; the rest stay the user's.
      expectedDock = pkgs.writeText "expected-dock.json" (
        builtins.toJSON {
          inherit (config.system.defaults.dock)
            persistent-apps
            persistent-others
            show-recents
            tilesize
            ;
        }
      );
    in
    ''
      name=${lib.escapeShellArg entry.name}
      gen=${generation}
      sys=${system}
      production=${production}
      variant=${if entry.bootstrap then "bootstrap" else "production"}

      # The line an activation step starts on, or 0 when it is absent.
      step() { grep -n "_iNote \"Activating %s\" \"$1\"" "$gen/activate" | head -n1 | cut -d: -f1 || true; }
      # The lines of an activation step, up to the next step's note.
      stepBlock() {
        awk -v note="_iNote \"Activating %s\" \"$1\"" '
          $0 == note { on = 1; next }
          on && /^_iNote "Activating %s" / { exit }
          on { print }
        ' "$gen/activate"
      }
      stage=$(step nixConfigSecretsStage); stage=''${stage:-0}
      publish=$(step nixConfigSecretsPublish); publish=''${publish:-0}
      boundary=$(step writeBoundary); boundary=''${boundary:-0}
      link=$(step linkGeneration); link=''${link:-0}
      if [ "$boundary" = 0 ] || [ "$link" = 0 ]; then
        bad "the activation script has no writeBoundary or linkGeneration step"
      elif [ "$production" = 1 ]; then
        [ "$stage" != 0 ] && [ "$stage" -lt "$boundary" ] \
          || bad "host-secrets stage must run before writeBoundary"
        [ "$publish" -gt "$link" ] || bad "host-secrets publish must run after linkGeneration"
      else
        [ "$stage" = 0 ] && [ "$publish" = 0 ] \
          || bad "bootstrap must run no host-secrets step"
      fi
      [ "$(step dockerCredHelpers)" = "" ] || bad "the OrbStack credHelpers merge still runs"
      authBlock=$TMPDIR/containers-auth-$variant.sh
      stepBlock containersAuth > "$authBlock"
      if ! python3 ${authEffects} "$authBlock"; then
        bad "containersAuth effect contract failed"
      fi


      vars=$gen/home-path/etc/profile.d/hm-session-vars.sh
      [ -f "$vars" ] || bad "no hm-session-vars.sh in the profile"
      grep -q 'DOCKER_HOST=.*podman/podman-machine-default-api.sock' "$vars" \
        || bad "DOCKER_HOST does not name the Podman machine's API socket"
      grep -q 'REGISTRY_AUTH_FILE=' "$vars" || bad "REGISTRY_AUTH_FILE is not in the session"
      grep -q 'TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE=.*/var/run/docker.sock' "$vars" \
        || bad "TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE does not name the VM's Docker socket"
      for v in TESTCONTAINERS_RYUK_PRIVILEGED TESTCONTAINERS_RYUK_CONTAINER_PRIVILEGED; do
        if grep -q "$v=" "$vars"; then bad "the Linux Ryuk variable $v reached the session"; fi
      done
      # The VM mounts ~/.config/containers, where a store link would dangle.
      [ ! -e "$gen/home-files/.config/containers" ] || bad "store-linked containers/ files reached macOS"
      [ ! -e "$gen/home-files/.config/systemd" ] || bad "systemd user files reached macOS"

      containersconf=$(grep -o -m1 '/nix/store/[a-z0-9]*-containers.conf' "$gen/activate" || true)
      if [ -z "$containersconf" ]; then
        bad "activation installs no containers.conf"
      else
        grep -qx 'provider *= *"libkrun"' "$containersconf" \
          || bad "containers.conf does not select the libkrun machine provider"
      fi
      [ "$(readlink -f "$gen/home-path/bin/docker")" = "$(readlink -f "$gen/home-path/bin/podman")" ] \
        || bad "docker on PATH is not the profile's podman"

      if [ -d "$gen/LaunchAgents" ]; then
        if find -L "$gen/LaunchAgents" -type f -iname '*chatgpt*' -print | grep . >/dev/null \
          || grep -Riq -- 'chatgpt' "$gen/LaunchAgents"; then
          bad "ChatGPT login startup is unsupported but a launch agent exists"
        fi
      fi

      # A plist with its whitespace removed, so a key and its value are adjacent.
      agent() { tr -d ' \t\n' 2>/dev/null < "$gen/LaunchAgents/org.nix-community.home.$1.plist" || true; }
      watchdog=$(agent podman-machine-podman-machine-default)
      case $watchdog in *'<key>AbandonProcessGroup</key><true/>'*) ;; *) bad "the machine watchdog does not abandon its process group" ;; esac
      case $watchdog in *'<key>ProcessType</key><string>Interactive</string>'*) ;; *) bad "the machine watchdog does not run at interactive priority" ;; esac
      guienv=$(agent container-environment)
      case $guienv in
        *'launchctlsetenvDOCKER_HOST'*podman/podman-machine-default-api.sock*) ;;
        *) bad "no login agent exports the machine's socket to GUI apps" ;;
      esac
      case $guienv in
        *'launchctlsetenvTESTCONTAINERS_DOCKER_SOCKET_OVERRIDE/var/run/docker.sock'*) ;;
        *) bad "no login agent exports the VM's Docker socket to GUI apps" ;;
      esac
      grep -Fxq 'export CROSS_MODEL_PEERS="${peers}"' "$vars" \
        || bad "the session does not set CROSS_MODEL_PEERS to ${peers}"
      grep -Fxq 'export CROSS_MODEL_MAX_PEERS="2"' "$vars" || bad "the session does not set CROSS_MODEL_MAX_PEERS to 2"
      case ",${peers}," in *,codex,*) ;; *) bad "CROSS_MODEL_PEERS (${peers}) does not allow codex, which the profile installs" ;; esac
      peeragent=$(agent cross-model-peers)
      case $peeragent in
        *'launchctlsetenvCROSS_MODEL_PEERS${peers}/bin/launchctlsetenvCROSS_MODEL_MAX_PEERS2'*'<key>RunAtLoad</key><true/>'*) ;;
        *) bad "no login agent sets CROSS_MODEL_PEERS to ${peers} and CROSS_MODEL_MAX_PEERS to 2 for GUI apps" ;;
      esac
      waiveragent=$(agent claude-rm-waiver)
      case $waiveragent in
        *'exec/bin/launchctlsetenvCLAUDE_CODE_EVEN_MORE_DANGEROUSLY_SKIP_PERMISSIONS1</string></array>'*'<key>RunAtLoad</key><true/>'*) ;;
        *) bad "no login agent sets CLAUDE_CODE_EVEN_MORE_DANGEROUSLY_SKIP_PERMISSIONS to 1 for GUI apps" ;;
      esac
      minikube=$(agent minikube)
      if [ "$production" = 1 ]; then
        case $minikube in *minikube-darwin-start*'<key>RunAtLoad</key><true/>'*) ;; *) bad "the minikube login agent is missing" ;; esac
        case $minikube in *'<key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>'*) ;; *) bad "the minikube login agent is not retried after a failure" ;; esac
        case $minikube in *'<key>AbandonProcessGroup</key><true/>'*) ;; *) bad "the minikube login agent does not abandon its process group" ;; esac
        case $minikube in *'<key>PATH</key><string>/nix/store/'*-podman-*'/bin:/nix/store/'*-minikube-*'/bin:/usr/bin:/bin</string>'*) ;; *) bad "the minikube login agent's PATH lacks podman or minikube" ;; esac
      else
        [ -z "$minikube" ] || bad "bootstrap has a minikube login agent"
      fi

      agentconf=$gen/home-files/.gnupg/gpg-agent.conf
      gitgpg=$(${pkgs.git}/bin/git config --file "$gen/home-files/.config/git/config" --get-regexp '^gpg\.(openpgp\.)?program$' | tail -n1 | cut -d' ' -f2- || true)
      if [ "$gitgpg" != "${
        (import ../packages/gpg-tools.nix { inherit pkgs; }).gitGpg
      }/bin/gpg-git" ]; then
        bad "Git does not use the card-discovery signing adapter"
      fi
      if [ ! -f "$agentconf" ]; then
        bad "no gpg-agent.conf"
      else
        pinentry=$(sed -n 's/^pinentry-program //p' "$agentconf")
        case $pinentry in
          */bin/pinentry-card) ;;
          *) bad "gpg-agent.conf names $pinentry, not the darwin pinentry filter" ;;
        esac
        proxy=$(dirname "$(dirname "$pinentry")")/libexec/pinentry-card/pinentry-card-proxy
        grep -q 'KEYRING_BACKEND = "security"' "$proxy" 2>/dev/null \
          || bad "the pinentry filter's proxy is not the macOS Keychain render"
        grep -q 'bin/pinentry-mac' "$proxy" 2>/dev/null \
          || bad "the pinentry filter's proxy does not delegate to pinentry_mac"
        grep -qx 'default-cache-ttl 0' "$agentconf" && grep -qx 'max-cache-ttl 0' "$agentconf" \
          || bad "gpg-agent must cache no PIN"
      fi
      grep -qx 'disable-ccid' "$gen/home-files/.gnupg/scdaemon.conf" \
        && grep -qx 'pcsc-shared' "$gen/home-files/.gnupg/scdaemon.conf" \
        || bad "scdaemon.conf is not the shared one"
      # Home Manager writes `/usr/bin/defaults <flags> import <domain> <plist>`,
      # with an empty flag slot and the domain quoted only when it needs it.
      plist=$(grep -oE "/usr/bin/defaults +import +'?org\.gpgtools\.pinentry-mac'? +/nix/store/[^ ]*" "$gen/activate" \
        | grep -o '/nix/store/[^ ]*' || true)
      if [ -z "$plist" ]; then
        bad "activation does not import pinentry_mac's defaults"
      else
        tr -d ' \t\n' < "$plist" | grep -q '<key>UseKeychain</key><false/>' \
          || bad "pinentry_mac's UseKeychain default is not false"
      fi

      ghostty=$gen/home-files/.config/ghostty/config
      if [ -f "$ghostty" ]; then
        families=$(sed -n 's/^font-family *= *//p' "$ghostty" | tr '\n' '|')
        [ "$families" = ${lib.escapeShellArg "${lib.concatStringsSep "|" fontFamilies}|"} ] \
          || bad "Ghostty's font-family is $families"
      else
        bad "no Ghostty config"
      fi

      grok=$(readlink -f "$gen/home-path/bin/grok" || true)
      if [ -z "$grok" ] || [ "$grok" != ${lib.escapeShellArg "${grokPkg}/bin/grok"} ]; then
        bad "grok on PATH is not the grok-build wrapper"
      fi
      if [ -e "$gen/home-path/bin/agent" ] || [ -L "$gen/home-path/bin/agent" ]; then
        bad "the profile puts an agent executable on PATH"
      fi

      case $(readlink -f "$gen/home-path/bin/nr") in
        /nix/store/*-nr-darwin-*) ;;
        *) bad "nr on PATH is not nr-darwin" ;;
      esac

      if ! grep -Fxq -- ${lib.escapeShellArg "KEY_FILE='${state}/synthetic_api_key'"} "$gen/home-path/bin/omp-synthetic-key"; then
        bad "OMP's installed key helper does not read ${state}/synthetic_api_key"
      fi
      if ! grep -Fxq -- ${lib.escapeShellArg "KEY_FILE='${state}/openrouter_api_key'"} "$gen/home-path/bin/omp-openrouter-key"; then
        bad "OMP's installed OpenRouter key helper does not read ${state}/openrouter_api_key"
      fi

      if [ -z ${lib.escapeShellArg serveHtml} ]; then
        bad "packages/agent-tools.nix exports no serveHtml"
      elif [ "$(readlink -f "$gen/home-path/bin/serve-html" || true)" != ${lib.escapeShellArg serveHtml} ]; then
        bad "serve-html on PATH is not the packaged helper"
      fi

      [ "$(readlink -f "$gen/home-path/bin/agy" || true)" = ${lib.escapeShellArg agy} ] \
        || bad "agy on PATH is not the pinned Antigravity CLI"
      agyPar=$(readlink -f "$gen/home-path/bin/agy_acp_server.par" || true)
      if [ -z "$agyPar" ] || [ ! -x "$agyPar" ]; then
        bad "no agy_acp_server.par on PATH"
      else
        grep -qxF ${lib.escapeShellArg "exec ${antigravityRuntime}/agy_acp_server.par \"$@\""} "$agyPar" \
          || bad "agy_acp_server.par does not exec the PATH-pinned runtime's .par"
        if grep -qF SSL_CERT_FILE "$agyPar"; then
          bad "the macOS agy_acp_server.par wrapper sets SSL_CERT_FILE"
        fi
      fi
      [ "$(readlink -f "$gen/home-path/bin/localharness_external" || true)" = ${lib.escapeShellArg "${antigravityRuntime}/localharness_external"} ] \
        || bad "localharness_external on PATH is not the PATH-pinned runtime's"

      codexBlock=$TMPDIR/codex-settings-$variant.sh
      stepBlock codexSettings > "$codexBlock"
      if ! python3 ${codexEffects} "$codexBlock" ${lib.escapeShellArg config.my.user.home}; then
        bad "Codex activation effect contract failed"
      fi

      [ -x "$gen/home-path/bin/sccache" ] || bad "sccache is missing from PATH"
      cargoBlock=$TMPDIR/cargo-settings-$variant.sh
      stepBlock cargoSettings > "$cargoBlock"
      if ! python3 ${cargoEffects} "$cargoBlock" ${lib.escapeShellArg config.my.user.home} ${lib.escapeShellArg "${user.home.profileDirectory}/bin/sccache"}; then
        bad "Cargo activation effect contract failed"
      fi

      grep -q 'Library/Application Support/VSCodium/User/settings.json' "$gen/activate" \
        || bad "the VSCodium settings merge does not target Application Support"

      # The paths T3 Code's device hub requires under the SDK root.
      sdk=$gen/home-files/Library/Android/sdk
      [ -x "$sdk/cmdline-tools/latest/bin/avdmanager" ] \
        || bad "the Android SDK has no cmdline-tools/latest/bin/avdmanager"
      [ -x "$sdk/platform-tools/adb" ] || bad "the Android SDK has no platform-tools/adb"
      for api in ${lib.escapeShellArgs androidPin.platforms}; do
        [ -f "$sdk/system-images/android-$api/google_apis/arm64-v8a/system.img" ] \
          || bad "the Android SDK has no arm64-v8a Google APIs system.img for API $api"
      done
      # A Dock-launched T3 Code starts the emulator with no SDK variables set.
      emulator=$sdk/emulator/emulator
      if ! grep -qsxF 'export ANDROID_HOME="''${ANDROID_HOME:-$HOME/Library/Android/sdk}"' "$emulator" \
        || ! grep -qsxF 'export ANDROID_SDK_ROOT="''${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}"' "$emulator"; then
        bad "emulator/emulator is not the wrapper that defaults ANDROID_HOME and ANDROID_SDK_ROOT to ~/Library/Android/sdk"
      else
        real=$(sed -n 's|^exec \(/nix/store/[^ ]*/emulator/emulator\) "\$@"$|\1|p' "$emulator")
        if [ -z "$real" ] || [ ! -x "$real" ] || [ "$(head -c 2 "$real")" = "#!" ]; then
          bad "the emulator wrapper does not exec the store emulator binary"
        fi
      fi
      sdkroot=${lib.escapeShellArg androidSdkRoot}
      for v in ANDROID_HOME ANDROID_SDK_ROOT; do
        grep -qxF "export $v=\"$sdkroot\"" "$vars" || bad "the session does not set $v to $sdkroot"
      done
      # Only a PATH assignment counts, so another line naming the directory
      # cannot stand in for it.
      pathlines=$(grep '^export PATH=' "$vars" || true)
      case $pathlines in
        *":$sdkroot/emulator\""* | *":$sdkroot/emulator:"*) ;;
        *) bad "no PATH assignment gains the SDK's emulator directory" ;;
      esac

      devices=$(step mobileDevices); devices=''${devices:-0}
      [ "$devices" -gt "$link" ] || bad "the mobileDevices step does not run after linkGeneration"
      helper=$(grep -m1 '/nix/store/[^ ]*/bin/mobile-devices --xcrun ' "$gen/activate" || true)
      helperexe=$(grep -o '/nix/store/[^ ]*/bin/mobile-devices' <<<"$helper" || true)
      if [ -z "$helper" ] || [ ! -x "$helperexe" ]; then
        bad "activation does not call the built mobile-devices helper"
      else
        ${lib.optionalString (deviceArgs == [ ]) ''bad "my.mobileDevices declares no device"''}
        for arg in \
          '--xcrun /usr/bin/xcrun ' \
          ${lib.escapeShellArg "--sdk-root ${lib.escapeShellArg androidSdkRoot} "} \
          ${lib.escapeShellArg "--android-api ${lib.escapeShellArg androidPin.newestArm64Api} "} \
          ${lib.escapeShellArgs deviceArgs}; do
          case $helper in
            *"$arg"*) ;;
            *) bad "the mobile-devices helper call lacks $arg" ;;
          esac
        done
        javahome=$(sed -n "s|.*--java-home '\{0,1\}\(/nix/store/[^ ']*\).*|\1|p" <<<"$helper")
        if [ -z "$javahome" ] || ! "$javahome/bin/java" -version >/dev/null 2>&1; then
          bad "the mobile-devices helper call lacks a --java-home whose bin/java runs: ''${javahome:-none}"
        fi
      fi

      ${lib.optionalString (t3Desktop != null) ''
        app=${t3Desktop}/Applications/'T3 Code (Nightly).app'
        if [ ! -d "$app" ]; then
          bad "the T3 Code nightly bundle is missing"
        else
          exe=$(/usr/bin/plutil -extract CFBundleExecutable raw "$app/Contents/Info.plist" 2>/dev/null \
            || sed -n '/CFBundleExecutable/{n;s/.*<string>\(.*\)<\/string>.*/\1/p;}' "$app/Contents/Info.plist")
          unzip -p ${t3Desktop.src} "T3 Code (Nightly).app/Contents/MacOS/$exe" | cmp -s - "$app/Contents/MacOS/$exe" \
            || bad "the T3 Code main executable differs from the release zip's, so its signature is broken"
        fi
        grep -qs T3CODE_DISABLE_AUTO_UPDATE "$gen/LaunchAgents/org.nix-community.home.t3code-disable-auto-update.plist" \
          || bad "no launch agent sets T3CODE_DISABLE_AUTO_UPDATE"
      ''}

      # The TLS inspection CA trait, on in the fixture: production points
      # shells, nix-daemon, and GUI apps at one bundle; bootstrap keeps the
      # default and has no agent.
      tlsbundle=/etc/ssl/nix-config/ca-certificates.crt
      setenvfile=$(grep -o -m1 '/nix/store/[a-z0-9]*-set-environment' "$sys/etc/zshenv" || true)
      daemonca=$(/usr/bin/plutil -extract EnvironmentVariables.NIX_SSL_CERT_FILE raw "$sys/Library/LaunchDaemons/org.nixos.nix-daemon.plist" 2>/dev/null || true)
      caagent=$sys/user/Library/LaunchAgents/org.nixos.tls-inspection-ca-environment.plist
      if [ "$production" = 1 ]; then
        for v in SSL_CERT_FILE NIX_SSL_CERT_FILE NODE_EXTRA_CA_CERTS REQUESTS_CA_BUNDLE CURL_CA_BUNDLE GIT_SSL_CAINFO; do
          grep -qsxF "export $v=\"$tlsbundle\"" "$setenvfile" || bad "shells do not set $v to the TLS inspection CA bundle"
          /usr/bin/plutil -extract ProgramArguments.2 raw "$caagent" 2>/dev/null | grep -qxF "/bin/launchctl setenv $v $tlsbundle" \
            || bad "no login agent sets $v to the TLS inspection CA bundle for GUI apps"
        done
        [ "$(/usr/bin/plutil -extract RunAtLoad raw "$caagent" 2>/dev/null)" = true ] || bad "the CA environment agent does not run at load"
        [ "$daemonca" = "$tlsbundle" ] || bad "nix-daemon reads $daemonca, not the TLS inspection CA bundle"
        bundleline=$(grep -n -m1 '/bin/tls-inspection-ca bundle ' "$sys/activate" | cut -d: -f1); bundleline=''${bundleline:-0}
        etcline=$(grep -n -m1 'setting up /etc' "$sys/activate" | cut -d: -f1); etcline=''${etcline:-0}
        trustline=$(grep -n -m1 '/bin/tls-inspection-ca trust ' "$sys/activate" | cut -d: -f1); trustline=''${trustline:-0}
        if [ "$bundleline" = 0 ] || [ "$trustline" = 0 ] || ! [ "$bundleline" -lt "$etcline" ] || ! [ "$etcline" -lt "$trustline" ]; then
          bad "the CA bundle step does not run before /etc and the trust step after it"
        fi
        # Run the materialized bundle step itself, so a step that only echoes
        # its arguments fails: the fixture's fake CA decrypts with the fake
        # identity beside it, and only the identity copy, its owner, and the
        # output directory point into scratch space. launchctl is a stub.
        castep=$(sed -n '/\/bin\/tls-inspection-ca bundle \\$/,/--daemon /p' "$sys/activate")
        cafile=$(sed -n 's|^ *--certificate-file \([^ ]*\) .*|\1|p' <<<"$castep")
        cabase=$(sed -n 's|^ *--base \([^ ]*\) .*|\1|p' <<<"$castep")
        rm -rf "$TMPDIR/castep"; mkdir -p "$TMPDIR/castep/bin"
        install -m 600 "$(dirname "$cafile")/key.txt" "$TMPDIR/castep/key.txt"
        printf '#!/bin/sh\nexit 1\n' >"$TMPDIR/castep/bin/launchctl"; chmod +x "$TMPDIR/castep/bin/launchctl"
        castep=$(sed -e "s|^\( *--identity \).*\( \\\\\)$|\1$TMPDIR/castep/key.txt\2|" \
          -e "s|^\( *--identity-owner \).*\( \\\\\)$|\1$(id -un)\2|" \
          -e "s|^\( *--out-dir \).*\( \\\\\)$|\1$TMPDIR/castep/out\2|" <<<"$castep")
        if [ -z "$cafile" ] || [ -z "$cabase" ] || ! PATH=$TMPDIR/castep/bin:$PATH bash -euo pipefail -c "$castep" 2>"$TMPDIR/castep/err"; then
          bad "the materialized CA bundle step fails: $(cat "$TMPDIR/castep/err" 2>/dev/null)"
        elif ! cat "$cabase" "$(dirname "$cafile")/tls-inspection-ca.pem" | cmp -s - "$TMPDIR/castep/out/ca-certificates.crt"; then
          bad "the materialized CA bundle step does not write this generation's roots followed by the CA"
        fi
      else
        [ "$daemonca" = /etc/ssl/certs/ca-certificates.crt ] || bad "bootstrap nix-daemon reads $daemonca, not the default bundle"
        [ ! -e "$caagent" ] || bad "bootstrap has the CA environment agent"
        if grep -q 'tls-inspection-ca' "$sys/activate"; then bad "bootstrap activation runs a TLS inspection CA step"; fi
      fi

      # The network recovery trait, on in the fixture: production loads a root
      # daemon every 5 seconds that runs the packaged script with the state
      # directory and the Tailscale CLI, logging to the file newsyslog rotates;
      # bootstrap has neither.
      nrdaemon=$sys/Library/LaunchDaemons/org.nixos.network-recovery.plist
      python3 ${streamTimeoutEffects} "$gen" "$production" || bad "Claude GUI timeout lifecycle failed"
      python3 ${./test_retire_orca.py} ${
        pkgs.writeText "retire-orca-block.sh" (user.home.activation.retireOrca.data or "exit 1")
      } 1 || bad "the retireOrca activation failed its contract"
      nrrotate=$sys/etc/newsyslog.d/network-recovery.conf
      if [ "$production" = 1 ]; then
        nrarg() { /usr/bin/plutil -extract "$1" raw "$nrdaemon" 2>/dev/null || true; }
        nrexe=$(nrarg ProgramArguments.0)
        case $nrexe in
          /nix/store/*-network-recovery/bin/network-recovery) [ -x "$nrexe" ] || bad "the network recovery daemon runs $nrexe, which is not executable" ;;
          *) bad "the network recovery daemon runs '$nrexe', not the packaged script" ;;
        esac
        [ "$(nrarg ProgramArguments.1) $(nrarg ProgramArguments.2) $(nrarg ProgramArguments.3) $(nrarg ProgramArguments.4)" \
          = "--state-dir /var/db/network-recovery --tailscale /Applications/Tailscale.app/Contents/MacOS/Tailscale" ] \
          || bad "the network recovery daemon does not pass the state directory and the Tailscale CLI"
        [ "$(nrarg StartInterval)" = 5 ] && [ "$(nrarg RunAtLoad)" = true ] \
          || bad "the network recovery daemon does not run at load and every 5 seconds"
        nrpath=$(nrarg EnvironmentVariables.PATH)
        for directory in /usr/bin /bin /usr/sbin /sbin; do
          case :$nrpath: in
            *":$directory:"*) ;;
            *) bad "the network recovery daemon PATH lacks $directory" ;;
          esac
        done
        grep -qxF 'export CLAUDE_BYTE_STREAM_IDLE_TIMEOUT_MS="60000"' "$vars" \
          || bad "the session does not export the 60-second Claude stream timeout"
        [ "$(nrarg StandardOutPath)" = /var/log/network-recovery.log ] \
          && [ "$(nrarg StandardErrorPath)" = /var/log/network-recovery.log ] \
          || bad "the network recovery daemon does not log to /var/log/network-recovery.log"
        grep -qE '^/var/log/network-recovery\.log[[:space:]]' "$nrrotate" \
          || bad "newsyslog does not rotate /var/log/network-recovery.log"
      else
        [ ! -e "$nrdaemon" ] || bad "bootstrap has the network recovery daemon"
        [ ! -e "$nrrotate" ] || bad "bootstrap rotates the network recovery log"
        if grep -q '^export CLAUDE_BYTE_STREAM_IDLE_TIMEOUT_MS=' "$vars"; then
          bad "bootstrap exports the Claude stream timeout"
        fi
      fi
      nixconf=$sys/etc/nix/nix.conf
      [ -f "$nixconf" ] || bad "the system has no nix.conf"
      if grep -Eq '^auto-optimise-store *= *true' "$nixconf"; then
        bad "nix.conf turns on store auto-optimisation"
      fi
      grep -qx "host=$name_host" "$sys/etc/nix-config-host" \
        && grep -qx "variant=$variant" "$sys/etc/nix-config-host" \
        || bad "/etc/nix-config-host does not record the host and variant"

      brewfile=$(grep -o -m1 "/nix/store/[a-z0-9]*-Brewfile" "$sys/activate" || true)
      if [ -z "$brewfile" ]; then
        bad "the system activation runs no brew bundle"
      else
        casks=$(sed -n 's/^cask "\([^"]*\)".*/\1/p' "$brewfile" | sort | tr '\n' ' ')
        [ "$casks" = ${lib.escapeShellArg "${lib.concatStringsSep " " expectedCasks} "} ] \
          || bad "the Brewfile lists casks: $casks"
      fi
      # nix-homebrew renders autoMigrate into this guard as "1" or "".
      setup=$(grep -o -m1 "/nix/store/[a-z0-9]*-setup-homebrew" "$sys/activate" || true)
      if [ -z "$setup" ]; then
        bad "the system activation runs no nix-homebrew setup"
      elif ! grep -qF 'if [[ -z "1" ]]' "$setup"; then
        bad "the nix-homebrew setup would stop on an existing Homebrew installation"
      fi
      # The Xcode step runs after brew bundle and before Home Manager, the last
      # point that still runs as root; mas runs in the primary user's session.
      lineof() { grep -nF -m1 -- "$1" "$sys/activate" | cut -d: -f1 || true; }
      bundleline=$(lineof "brew bundle --file="); bundleline=''${bundleline:-0}
      masline=$(lineof ${lib.escapeShellArg ''/bin/launchctl asuser "$xcodeUid" /usr/bin/env SUDO_UID="$xcodeUid" SUDO_GID="$xcodeGid" ${masExe} "$@"''}); masline=''${masline:-0}
      installline=$(lineof 'if ! xcodeMas install 497799835 && ! xcodeMas get 497799835; then'); installline=''${installline:-0}
      kakaomasline=$(lineof ${lib.escapeShellArg ''/bin/launchctl asuser "$appStoreUid" /usr/bin/env SUDO_UID="$appStoreUid" SUDO_GID="$appStoreGid" ${masExe} "$@"''}); kakaomasline=''${kakaomasline:-0}
      kakaoline=$(lineof 'if ! appStoreMas install 869223134 && ! appStoreMas get 869223134; then'); kakaoline=''${kakaoline:-0}
      flightyline=$(lineof 'if ! appStoreMas install 1358823008 && ! appStoreMas get 1358823008; then'); flightyline=''${flightyline:-0}
      retiredbrewline=$(lineof ${lib.escapeShellArg ''PATH="${config.homebrew.prefix}/bin:$PATH" /usr/bin/sudo --preserve-env=PATH --user=${config.system.primaryUser} --set-home /usr/bin/env NONINTERACTIVE=1 ${brewExe} "$@"''}); retiredbrewline=''${retiredbrewline:-0}
      retiredlistline=$(lineof ${lib.escapeShellArg ''if [ -z "$retiredList" ] || [ "$retiredList" = "Error: Cask 'grok-bot' is not installed." ]; then''}); retiredlistline=''${retiredlistline:-0}
      retiredline=$(lineof 'elif ! retiredBrew uninstall --cask --force grok-bot; then'); retiredline=''${retiredline:-0}
      hmline=$(lineof "echo Activating home-manager configuration for "); hmline=''${hmline:-0}
      if [ "$bundleline" = 0 ] || [ "$hmline" = 0 ]; then
        bad "the system activation has no brew bundle or Home Manager activation call"
      elif [ "$masline" = 0 ] || [ "$installline" = 0 ]; then
        bad "the system activation has no Xcode step running mas through launchctl asuser for 497799835"
      elif ! [ "$bundleline" -lt "$masline" ] || ! [ "$masline" -lt "$installline" ] || ! [ "$installline" -lt "$hmline" ]; then
        bad "the Xcode step does not run after brew bundle and before Home Manager"
      fi
      if [ "$kakaomasline" = 0 ] || [ "$kakaoline" = 0 ]; then
        bad "the system activation has no KakaoTalk step running mas through launchctl asuser for 869223134"
      elif ! [ "$installline" -lt "$kakaomasline" ] || ! [ "$kakaomasline" -lt "$kakaoline" ] || ! [ "$kakaoline" -lt "$hmline" ]; then
        bad "the KakaoTalk step does not run after the Xcode step and before Home Manager"
      fi
      if [ "$flightyline" = 0 ]; then
        bad "the system activation has no Flighty step running mas for 1358823008"
      elif ! [ "$kakaoline" -lt "$flightyline" ] || ! [ "$flightyline" -lt "$hmline" ]; then
        bad "the Flighty step does not run after the KakaoTalk step and before Home Manager"
      fi
      if [ "$retiredbrewline" = 0 ] || [ "$retiredlistline" = 0 ] || [ "$retiredline" = 0 ]; then
        bad "the system activation has no retired-cask step running brew through sudo for grok-bot, telling not-installed from other brew list failures, and uninstalling with --force"
      elif ! [ "$bundleline" -lt "$retiredbrewline" ] || ! [ "$flightyline" -lt "$retiredbrewline" ] || ! [ "$retiredbrewline" -lt "$retiredlistline" ] || ! [ "$retiredlistline" -lt "$retiredline" ] || ! [ "$retiredline" -lt "$hmline" ]; then
        bad "the retired-cask step does not run after brew bundle and the Flighty step and before Home Manager"
      fi
      python3 ${./retired-brew-effects.py} "$sys/activate" \
        || bad "the retired-cask step did not uninstall orca before untapping stablyai/orca, or failed the apply (tests/retired-brew-effects.py)"

      [ -n "$(ls -A "$sys/Library/Fonts/Nix Fonts" 2>/dev/null)" ] \
        || bad "no fonts under Library/Fonts/Nix Fonts"
      # The value is a multi-line plist, so read up to its closing tag.
      autoAppearance=$(awk '
        /defaults write -g .?AppleInterfaceStyleSwitchesAutomatically/ { on = 1 }
        on { print }
        on && /<\/plist>/ { exit }
      ' "$sys/activate")
      case "$autoAppearance" in
        *"<true/>"*) ;;
        *) bad "the system activation does not turn on automatic appearance" ;;
      esac
      if grep -Eq "defaults write -g '?AppleInterfaceStyle'? " "$sys/activate"; then
        bad "the system activation pins AppleInterfaceStyle"
      fi
      python3 ${dockWrites} "$sys/activate" ${expectedDock} ${lib.escapeShellArg config.my.user.name} \
        || bad "the system activation's Dock writes differ from the Dock options"
    '';
in
pkgs.runCommand "darwin-outputs"
  {
    nativeBuildInputs = [
      pkgs.python3
      pkgs.unzip
    ];
  }
  ''
    test -e ${instructionDelivery}
    fail=0
    bad() { echo "$name: $*" >&2; fail=1; }
    ${lib.optionalString (darwinFixtures == [ ]) ''
      echo "tests/fixtures/hosts holds no macOS fixture host" >&2
      fail=1
    ''}
    ${lib.concatMapStrings (entry: ''
      name_host=${lib.escapeShellArg entry.fixture}
      ${assertEntry entry}
    '') darwinFixtures}
    ${lib.concatMapStrings (
      entry:
      let
        disabled = entry.host.extendModules {
          modules = [ { my.networkRecovery.enable = lib.mkForce false; } ];
        };
        user = disabled.config.home-manager.users.${disabled.config.my.user.name};
      in
      ''
        name=${lib.escapeShellArg "${entry.name}-network-recovery-disabled"}
        sys=${disabled.config.system.build.toplevel}
        vars=${user.home.activationPackage}/home-path/etc/profile.d/hm-session-vars.sh
        python3 ${streamTimeoutEffects} ${user.home.activationPackage} 0 || bad "disabled Claude GUI timeout cleanup failed"
        [ ! -e "$sys/Library/LaunchDaemons/org.nixos.network-recovery.plist" ] \
          || bad "trait-disabled production has the network recovery daemon"
        [ ! -e "$sys/etc/newsyslog.d/network-recovery.conf" ] \
          || bad "trait-disabled production rotates the network recovery log"
        if grep -q '^export CLAUDE_BYTE_STREAM_IDLE_TIMEOUT_MS=' "$vars"; then
          bad "trait-disabled production exports the Claude stream timeout"
        fi
      ''
    ) (lib.filter (entry: !entry.bootstrap) darwinFixtures)}
    [ "$fail" = 0 ] || exit 1
    touch "$out"
  ''
