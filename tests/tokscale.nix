/*
  Check interface:

    import ./tests/tokscale.nix { inherit pkgs self; }

  Asserts that every configuration `tests/lib/configurations.nix` yields gives
  h82 the Tokscale wrapper, the declared settings merge, and the custom pricing
  file, and that only the production configurations decrypt the Tokscale
  token. Which side a configuration is on comes from the helper's `bootstrap`
  field, never from the sops manifest under test. It reads what the
  generations materialize -- home-path, home-files, the rendered activation
  script and the sops manifests -- rather than the options they come from.
  Expected values are literals stated here, independently of
  home/h82/agents/tokscale.nix.

  Verifies, on every configuration:
  - home-path/bin/tokscale is the packaged wrapper, and the host name baked
    into it is that configuration's networking.hostName with the token read
    from /run/secrets/cli-auth/tokscale_token.
  - home.activation.tokscaleSettings runs after installPackages, invokes the
    packaged merger without swallowing its exit status, points it at
    ~/.config/tokscale/settings.json, and passes a declared document equal to
    the one stated here.
  - no Home Manager file targets .config/tokscale/settings.json.
  - .config/tokscale/custom-pricing.json parses to the dotfiles document.
  - a production configuration's sops manifest carries cli-auth/tokscale_token
    owned by h82 with mode 0400, its gh/glab publisher does not read that
    token, and a bootstrap configuration's manifests carry no Tokscale secret at
    all.

  It also evaluates packages/tokscale.nix directly: a host name or token path
  that could break out of the single quotes the package substitutes them into
  must fail evaluation, and the shapes host names take must still build. Those
  fixtures use role names, never a real host's name.

  The wrapper's run-time behaviour (token precedence, Antigravity
  directories, exit status) is covered by the tokscale-wrapper check. This
  check never runs bun or Tokscale.

  Every lookup carries an `or` fallback so a mutation that removes an entry
  reaches the builder as shell rather than failing evaluation. See
  .compound-engineering/artifacts/solutions/best-practices/unguarded-derivation-interpolation-defeats-nix-check-mutation-testing.md
  The helper's guard runs first, so an empty configuration list, or one with no
  bootstrap output, fails the build instead of passing it. The builder collects
  every failure, so one red build names every broken assertion across every
  configuration.
*/
{ pkgs, self }:
let
  inherit (pkgs) lib;

  configurations = import ./lib/configurations.nix { inherit pkgs self; };

  esc = value: lib.escapeShellArg (toString value);

  executeActivation = import ./lib/agent-activation.nix { inherit pkgs; };

  declaredExpected = pkgs.writeText "tokscale-expected-settings.json" (
    builtins.toJSON {
      set = {
        colorPalette = "blue";
        autoRefreshEnabled = true;
        autoRefreshMs = 30000;
      };
      setPaths = [
        {
          path = [
            "scanner"
            "bucketTimezone"
          ];
          value = "Asia/Seoul";
        }
        {
          path = [
            "autosubmit"
            "enabled"
          ];
          value = false;
        }
      ];
    }
  );

  # Written as JSON text rather than a Nix attribute set so the comparison
  # cannot share a rendering path with the module.
  pricingExpected = pkgs.writeText "tokscale-expected-pricing.json" ''
    {
      "$schema": "https://tokscale.ai/custom-pricing.schema.json",
      "models": {
        "gemini-3.1-pro": {
          "input_cost_per_million_tokens": 4,
          "output_cost_per_million_tokens": 18,
          "cache_read_input_token_cost_per_million_tokens": 0.4,
          "cache_creation_input_token_cost_per_million_tokens": 0.375
        },
        "claude-fable-5-1": {
          "input_cost_per_million_tokens": 10,
          "output_cost_per_million_tokens": 50,
          "cache_read_input_token_cost_per_million_tokens": 0.25,
          "cache_creation_input_token_cost_per_million_tokens": 12.5
        }
      }
    }
  '';

  assertEntry =
    entry:
    let
      hostName = entry.name;
      production = !entry.bootstrap;
      hm = entry.user;
      homePath = hm.home.path or null;
      homeFiles = hm.home-files or null;

      activation = hm.home.activation.tokscaleSettings or null;
      script = if activation == null then "" else (activation.data or "");
      runsAfterPackages = lib.elem "installPackages" (
        if activation == null then [ ] else (activation.after or [ ])
      );

      settingsTargeted = lib.any (file: (file.target or "") == ".config/tokscale/settings.json") (
        lib.attrValues (hm.home.file or { })
      );

      # sops-nix installs through a systemd unit when my.cliAuth is enabled
      # and through the setupSecrets activation script otherwise, so both
      # places are searched for the manifests they hand the installer.
      sopsService = entry.config.systemd.services.sops-install-secrets or { };
      installers = lib.concatStringsSep " " (
        lib.toList (sopsService.serviceConfig.ExecStart or [ ])
        ++ [ (entry.config.system.activationScripts.setupSecrets.text or "") ]
      );
      publisher = lib.concatStringsSep " " (lib.toList (sopsService.serviceConfig.ExecStartPost or [ ]));

      host' = esc hostName;
    in
    ''
      expectedHost=${esc (entry.config.networking.hostName or "")}
      ${
        if homePath == null then
          ''fail ${host'}": no home-path"''
        else
          ''
            wrapper=${homePath}/bin/tokscale
            if [ ! -x "$wrapper" ]; then
              fail ${host'}": home-path has no executable bin/tokscale"
            else
              resolved=$(readlink -f "$wrapper")
              case "$resolved" in
                /nix/store/*-tokscale-*/bin/tokscale) ;;
                *) fail ${host'}": bin/tokscale is not the packaged wrapper: $resolved" ;;
              esac
              if ! grep -Fxq -- "HOST_NAME='$expectedHost'" "$resolved"; then
                fail ${host'}": the wrapper does not carry the host name $expectedHost"
              fi
              if ! grep -Fxq -- "TOKEN_FILE='/run/secrets/cli-auth/tokscale_token'" "$resolved"; then
                fail ${host'}": the wrapper does not read /run/secrets/cli-auth/tokscale_token"
              fi
            fi
          ''
      }
      ${lib.optionalString (activation == null) ''
        fail ${host'}": missing home.activation.tokscaleSettings"
      ''}
      if [ ${esc (lib.boolToString runsAfterPackages)} != "true" ]; then
        fail ${host'}": home.activation.tokscaleSettings must run after installPackages"
      fi

      script=${esc script}
      # Comment lines are stripped so an explanatory sentence cannot match.
      # The merger call spans several lines, so the whole block is searched.
      if printf '%s' "$script" | grep -v '^[[:space:]]*#' \
        | grep -E '(\|\|[[:space:]]*(true|:|echo)|;[[:space:]]*true|set \+e)' >/dev/null; then
        fail ${host'}": the tokscaleSettings activation script swallows the merger exit status"
      fi

      merger=$(printf '%s' "$script" | tr '\n' ' ' \
        | grep -oE -- '/nix/store/[^[:space:]]+/bin/agent-settings' | sed -n '1p' || true)
      if [ -z "$merger" ]; then
        fail ${host'}": the tokscaleSettings activation script does not invoke the packaged merger"
      fi

      settingsArg=$(printf '%s' "$script" | tr '\n' ' ' \
        | grep -oE -- '--settings[[:space:]]+[^[:space:]]+' | sed -n '1p' | awk '{print $2}' || true)
      if [ "$settingsArg" != ${esc "${hm.home.homeDirectory or ""}/.config/tokscale/settings.json"} ]; then
        fail ${host'}": the merger must be pointed at ~/.config/tokscale/settings.json, got: '$settingsArg'"
      fi

      declaredPath=$(printf '%s' "$script" | tr '\n' ' ' \
        | grep -oE -- '--declared[[:space:]]+/nix/store/[^[:space:]]+' | sed -n '1p' | awk '{print $2}' || true)
      if [ -z "$declaredPath" ]; then
        fail ${host'}": the tokscaleSettings activation script passes no declared document"
      elif ! python3 "$compareJson" "$declaredPath" ${declaredExpected}; then
        fail ${host'}": the declared settings drifted from the asserted values"
      elif [ -n "$merger" ]; then
        ${executeActivation {
          inherit script;
          home = hm.home.homeDirectory or "";
          contract = {
            file = ".config/tokscale/settings.json";
            seed = seededSettings;
            expected = mergedExpected;
            declared = {
              set = {
                colorPalette = "blue";
                autoRefreshEnabled = true;
                autoRefreshMs = 30000;
              };
              setPaths = [
                {
                  path = [
                    "scanner"
                    "bucketTimezone"
                  ];
                  value = "Asia/Seoul";
                }
                {
                  path = [
                    "autosubmit"
                    "enabled"
                  ];
                  value = false;
                }
              ];
            };
          };
        }}
      fi

      if [ ${esc (lib.boolToString settingsTargeted)} != "false" ]; then
        fail ${host'}": Home Manager must not target .config/tokscale/settings.json; Tokscale owns it"
      fi

      ${
        if homeFiles == null then
          ''fail ${host'}": no home-files"''
        else
          ''
            pricing=${homeFiles}/.config/tokscale/custom-pricing.json
            if [ ! -f "$pricing" ]; then
              fail ${host'}": missing .config/tokscale/custom-pricing.json"
            elif ! python3 "$compareJson" "$pricing" ${pricingExpected}; then
              fail ${host'}": custom-pricing.json differs from the dotfiles document"
            fi
          ''
      }

      manifests=$(printf '%s' ${esc installers} | grep -oE '/nix/store/[^[:space:]]+-manifest\.json' || true)
      if [ -z "$manifests" ]; then
        fail ${host'}": found no sops manifest"
      fi
      tokscaleSecrets=$(python3 - $manifests <<'PY'
      import json, sys
      for path in sys.argv[1:]:
          for secret in json.load(open(path)).get('secrets', []):
              if 'tokscale' in secret.get("name", "") or 'tokscale' in secret.get("key", ""):
                  print(secret.get('name'), secret.get('key'), secret.get('owner'), secret.get('mode'))
      PY
      )
      ${
        if production then
          ''
            if [ "$tokscaleSecrets" != "cli-auth/tokscale_token tokscale_token h82 0400" ]; then
              fail ${host'}": expected cli-auth/tokscale_token owned by h82 with mode 0400, got: '$tokscaleSecrets'"
            fi
            publisher=$(printf '%s' ${esc publisher} | grep -oE '/nix/store/[^[:space:]]+/bin/publish-cli-auth' | sed -n '1p' || true)
            if [ -z "$publisher" ]; then
              fail ${host'}": sops-install-secrets no longer runs publish-cli-auth"
            elif grep -q tokscale "$publisher"; then
              fail ${host'}": publish-cli-auth must not read the Tokscale token"
            fi
          ''
        else
          ''
            if [ -n "$tokscaleSecrets" ]; then
              fail ${host'}": a bootstrap host must not decrypt a Tokscale secret, got: '$tokscaleSecrets'"
            fi
          ''
      }
    '';

  seededSettings = {
    colorPalette = "green";
    autoRefreshEnabled = false;
    autoRefreshMs = 60000;
    tuiLightMode = true;
    usage.disabledProviders = [ "x" ];
    scanner = {
      opencodeDbPaths = [ "/tmp/db" ];
      bucketTimezone = "UTC";
    };
    autosubmit = {
      enabled = true;
      lastRunAtMs = 1700000000000;
      lastError = "boom";
    };
  };

  mergedExpected = {
    colorPalette = "blue";
    autoRefreshEnabled = true;
    autoRefreshMs = 30000;
    tuiLightMode = true;
    usage.disabledProviders = [ "x" ];
    scanner = {
      opencodeDbPaths = [ "/tmp/db" ];
      bucketTimezone = "Asia/Seoul";
    };
    autosubmit = {
      enabled = false;
      lastRunAtMs = 1700000000000;
      lastError = "boom";
    };
  };

  # Each case states whether packages/tokscale.nix must accept the pair.
  # tryEval catches the package's assertMsg, so a guard that stops rejecting
  # turns into a named shell failure instead of an evaluation error.
  guardCases = [
    {
      label = "a quote in the host name";
      hostName = "bad'name";
      accept = false;
    }
    {
      label = "an empty host name";
      hostName = "";
      accept = false;
    }
    {
      label = "a host name with a space";
      hostName = "bad name";
      accept = false;
    }
    {
      label = "a host name starting with a hyphen";
      hostName = "-bad";
      accept = false;
    }
    {
      label = "a relative token path";
      tokenFile = "run/secrets/cli-auth/tokscale_token";
      accept = false;
    }
    {
      label = "a quote in the token path";
      tokenFile = "/run/secrets/bad'path";
      accept = false;
    }
    {
      label = "a mixed-case host name with hyphens and digits";
      hostName = "Laptop-Host-11";
      accept = true;
    }
    {
      label = "an underscore and hyphen in the host name";
      hostName = "Desktop-Host_b";
      accept = true;
    }
  ];

  guardChecks = lib.concatMapStrings (
    case:
    let
      evaluated =
        builtins.tryEval
          (import ../packages/tokscale.nix {
            inherit pkgs;
            hostName = case.hostName or "test-host";
            tokenFile = case.tokenFile or "/run/secrets/cli-auth/tokscale_token";
          }).drvPath;
    in
    lib.optionalString (evaluated.success != case.accept) ''
      fail ${esc "packages/tokscale.nix ${if case.accept then "rejects" else "accepts"} ${case.label}"}
    ''
  ) guardCases;

  compareJson = pkgs.writeText "compare-json.py" ''
    import json, sys
    sys.exit(0 if json.load(open(sys.argv[1])) == json.load(open(sys.argv[2])) else 1)
  '';
in
pkgs.runCommand "tokscale-tests" { nativeBuildInputs = [ pkgs.python3 ]; } ''
  ${configurations.guard}
  failed=0
  fail() {
    echo "$1" >&2
    failed=1
  }
  compareJson=${compareJson}

  ${guardChecks}

  ${lib.concatMapStringsSep "\n" assertEntry configurations.entries}

  if [ "$failed" != 0 ]; then
    exit 1
  fi
  touch $out
''
