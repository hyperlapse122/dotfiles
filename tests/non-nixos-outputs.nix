/*
  Check interface:

    import ./tests/non-nixos-outputs.nix { inherit pkgs self fixtures; }

  `fixtures` is tests/lib/linux-fixtures.nix. Asserts what the non-NixOS
  assembly produces for every fixture host, both variants:

  - every fixture yields a production and a bootstrap output;
  - among Linux hosts, the Android SDK reaches x86_64 hosts only, so an
    aarch64 host gets no tools it cannot execute;
  - the account and home directory follow the host's `my.user` values;
  - no desktop configuration reaches the user environment: no Plasma or
    autostart files, no GUI packages, the T3 Code desktop app included;
  - the T3 Code CLI is in the user packages exactly when the host enables
    my.t3.cli.enable, and at least one fixture enables it;
  - production runs the host-secrets activation steps, stage before any link
    changes and publish after the links, and bootstrap never does; both carry
    the user-mode identity installer, and ~/.ssh/config names the host key
    rather than the 1Password agent;
  - Codex is installed, allowed as a Compound Engineering peer, reads
    ~/.codex/AGENTS.md, and its settings merge targets ~/.codex/config.toml
    after installPackages;
  - sccache is installed and the Cargo settings merge targets
    ~/.cargo/config.toml after installPackages;
  - on fixtures of the builder's own architecture, grok on the profile's PATH
    resolves to the packaged Grok Build wrapper, and the profile has no
    `agent` executable;
  - on fixtures of the builder's own architecture, the Tokscale wrapper,
    OMP's key helper, and the registry credential helper read the tokens
    host-secrets publishes, not /run/secrets, which a non-NixOS host does not
    have;
  - the system layer manages no file the distribution owns: no user database,
    subordinate id range, login-shell list, or NVIDIA configuration;
  - on fixtures of the builder's own architecture, the materialized system
    layer runs pcscd with the ccid reader drivers and a duplicate-free default
    service PATH, writes a nix.conf that keeps builds on the nixbld users and
    trusts only root, and records the host and variant in /etc/nix-config-host.
    Other architectures are proven by their own build in CI.

  Every comparison is rendered into the builder, so a failure names the
  fixture and the reason instead of aborting evaluation.
*/
{
  pkgs,
  self,
  fixtures,
}:
let
  inherit (pkgs) lib;

  # GUI packages the NixOS desktop installs; none may reach a non-NixOS host.
  guiPackages = [
    "discord"
    "google-chrome"
    "kleopatra"
    "ksshaskpass"
    "okular"
    "libreoffice"
    "telegram-desktop"
    "winbox"
    "yubioath-flutter"
    "chatgpt"
    "claude-desktop"
    "wifiman-desktop"
    "t3code-desktop"
    "vscodium"
    "ghostty"
  ];

  fail = message: ''
    echo ${lib.escapeShellArg message} >&2
    fail=1
  '';

  check = condition: message: lib.optionalString (!condition) (fail message);

  fixtureNames = lib.unique (map (entry: entry.fixture) fixtures);

  assertPairs = lib.concatMapStrings (
    fixture:
    let
      variants = map (entry: entry.bootstrap) (lib.filter (entry: entry.fixture == fixture) fixtures);
    in
    check (
      lib.elem false variants && lib.elem true variants
    ) "${fixture}: expected a production and a bootstrap output"
  ) fixtureNames;

  assertEntry =
    entry:
    let
      home = entry.host.home;
      hm = home.config;
      pnames = map (p: p.pname or (lib.getName p)) hm.home.packages;
      leakedGui = lib.filter (name: lib.elem name pnames) guiPackages;
      # Resolved by target and enable, so a renamed or disabled entry cannot
      # hide what actually lands in the home directory.
      enabledTargets = files: lib.filter (file: file.enable) (lib.attrValues files);
      sshConfigFile = hm.my.ssh.configFile;
      # hasInfix matches by regex, which rejects strings that carry store paths.
      sshInstalled =
        lib.hasInfix
          (builtins.unsafeDiscardStringContext ''install -m 600 ${sshConfigFile} "$HOME/.ssh/config"'')
          (builtins.unsafeDiscardStringContext (activation.sshConfig.data or ""))
        && !lib.any (file: file.target == ".ssh/config") (enabledTargets hm.home.file);
      desktopFiles = lib.filter (
        target:
        lib.hasPrefix "autostart/" target || lib.hasPrefix "plasma" target || lib.hasPrefix "kde" target
      ) (map (file: file.target) (enabledTargets hm.xdg.configFile));
      x86 = lib.hasPrefix "x86_64-" entry.host.system;
      activation = hm.home.activation;
    in
    lib.concatStrings [
      (check (
        lib.any (
          file: file.target == "${lib.removePrefix "${hm.home.homeDirectory}/" hm.xdg.dataHome}/android-sdk"
        ) (enabledTargets hm.xdg.dataFile) == x86
        && (hm.home.sessionVariables ? ANDROID_HOME) == x86
      ) "${entry.name}: the x86_64-only Android SDK must be present exactly on x86_64 hosts")
      (check (
        hm.home.username == hm.my.user.name
      ) "${entry.name}: home.username is ${hm.home.username}, my.user.name is ${hm.my.user.name}")
      (check (hm.home.homeDirectory == hm.my.user.home)
        "${entry.name}: home.homeDirectory is ${hm.home.homeDirectory}, my.user.home is ${hm.my.user.home}"
      )
      (check (
        leakedGui == [ ]
      ) "${entry.name}: GUI packages reached a non-NixOS host: ${lib.concatStringsSep ", " leakedGui}")
      (check (lib.elem "t3code-cli" pnames == hm.my.t3.cli.enable)
        "${entry.name}: the T3 Code CLI must be installed exactly when my.t3.cli.enable is on (it is ${lib.boolToString hm.my.t3.cli.enable})"
      )
      (check (
        activation ? nixConfigSecretsStage == !entry.bootstrap
        && activation ? nixConfigSecretsPublish == !entry.bootstrap
      ) "${entry.name}: the secret activation steps must run in production and never in bootstrap")
      (check (
        entry.bootstrap
        || (
          lib.elem "writeBoundary" (activation.nixConfigSecretsStage.before or [ ])
          && lib.elem "linkGeneration" (activation.nixConfigSecretsPublish.after or [ ])
          && lib.hasInfix "host-secrets stage" (activation.nixConfigSecretsStage.data or "")
          && lib.hasInfix "host-secrets publish" (activation.nixConfigSecretsPublish.data or "")
        )
      ) "${entry.name}: host-secrets must stage before writeBoundary and publish after linkGeneration")
      (check (
        lib.elem "nr-linux" pnames && !lib.elem "nr" pnames
      ) "${entry.name}: nr must be the non-NixOS apply helper, not the nixos-rebuild one")
      (check (lib.elem "install-user-age-identity" pnames) "${entry.name}: install-user-age-identity is missing, so the identity cannot be recovered")
      # Reads the file activation installs, which builds only on its own
      # architecture; other architectures are proven by their own build in CI.
      (lib.optionalString (entry.host.system == pkgs.stdenv.hostPlatform.system) ''
        if ! grep -qxF -- ${lib.escapeShellArg "  IdentityFile ${hm.my.secrets.sshKey}"} ${sshConfigFile} \
          || grep -qF IdentityAgent ${sshConfigFile}; then
          ${fail "${entry.name}: ~/.ssh/config must name the host key and no agent socket"}
        fi
      '')
      (check sshInstalled "${entry.name}: activation must install ~/.ssh/config as a user-owned copy, not a store link")
      (check (
        lib.elem "codex" pnames
        && lib.elem "codex" hm.my.agents.crossModelPeers
        && lib.any (file: file.target == ".codex/AGENTS.md") (enabledTargets hm.home.file)
      ) "${entry.name}: Codex must be installed, allowed as a peer, and read ~/.codex/AGENTS.md")
      (check
        (
          lib.elem "installPackages" (activation.codexSettings.after or [ ])
          && lib.hasInfix "--settings ${hm.home.homeDirectory}/.codex/config.toml" (
            builtins.unsafeDiscardStringContext (activation.codexSettings.data or "")
          )
        )
        "${entry.name}: activation must merge the declared Codex settings into ~/.codex/config.toml after installPackages"
      )
      (check (lib.elem "sccache" pnames) "${entry.name}: sccache must be installed")
      (check
        (
          lib.elem "installPackages" (activation.cargoSettings.after or [ ])
          && lib.hasInfix "--format toml" (
            builtins.unsafeDiscardStringContext (activation.cargoSettings.data or "")
          )
          && lib.hasInfix "--settings ${hm.home.homeDirectory}/.cargo/config.toml" (
            builtins.unsafeDiscardStringContext (activation.cargoSettings.data or "")
          )
        )
        "${entry.name}: activation must merge the declared Cargo settings into ~/.cargo/config.toml as TOML after installPackages"
      )
      (check (desktopFiles == [ ])
        "${entry.name}: desktop configuration reached a non-NixOS host: ${lib.concatStringsSep ", " desktopFiles}"
      )
    ];

  # The token readers must point at the state directory host-secrets publishes
  # to. Read from the built wrapper and credential map, not the options that
  # produced them.
  assertConsumers =
    entry:
    let
      hm = entry.host.home.config;
      packageNamed = name: lib.findFirst (p: (p.pname or "") == name) null hm.home.packages;
      tokscale = packageNamed "tokscale";
      omp = packageNamed "omp";
      grok = packageNamed "grok-build";
      helper = packageNamed "docker-credential-sops";
      state = hm.my.secrets.stateDir;
    in
    lib.optionalString (entry.host.system == pkgs.stdenv.hostPlatform.system) (
      lib.concatStrings [
        (
          if tokscale == null then
            fail "${entry.name}: no tokscale wrapper in home.packages"
          else
            ''
              if ! grep -Fxq -- ${lib.escapeShellArg "TOKEN_FILE='${state}/tokscale_token'"} ${tokscale}/bin/tokscale; then
                ${fail "${entry.name}: the tokscale wrapper does not read ${state}/tokscale_token"}
              fi
            ''
        )
        (
          if omp == null then
            fail "${entry.name}: no omp package in home.packages"
          else
            ''
              if ! grep -Fxq -- ${lib.escapeShellArg "KEY_FILE='${state}/synthetic_api_key'"} ${omp}/bin/omp-synthetic-key; then
                ${fail "${entry.name}: OMP's key helper does not read ${state}/synthetic_api_key"}
              fi
              if ! grep -Fxq -- ${lib.escapeShellArg "KEY_FILE='${state}/openrouter_api_key'"} ${omp}/bin/omp-openrouter-key; then
                ${fail "${entry.name}: OMP's OpenRouter key helper does not read ${state}/openrouter_api_key"}
              fi
            ''
        )
        (
          if grok == null then
            fail "${entry.name}: no grok-build in home.packages"
          else
            ''
              if [ "$(readlink -f ${hm.home.path}/bin/grok || true)" != ${grok}/bin/grok ]; then
                ${fail "${entry.name}: grok on PATH is not the grok-build wrapper"}
              fi
              if [ -e ${hm.home.path}/bin/agent ] || [ -L ${hm.home.path}/bin/agent ]; then
                ${fail "${entry.name}: the profile puts an agent executable on PATH"}
              fi
            ''
        )
        (
          if helper == null then
            fail "${entry.name}: no docker-credential-sops in home.packages"
          else
            ''
              map=$(grep -o '/nix/store/[^"'"'"' ]*-docker-credential-map.json' ${helper}/bin/docker-credential-sops | head -n1)
              if [ -z "$map" ] || ! grep -qF -- ${lib.escapeShellArg "${state}/github_token"} "$map" || grep -qF /run/secrets "$map"; then
                ${fail "${entry.name}: the registry credential helper does not read ${state}"}
              fi
            ''
        )
      ]
    );

  distributionOwned = import ./lib/distribution-owned.nix;

  assertSystem =
    entry:
    let
      sm = entry.host.systemManager;
      managed = lib.attrNames (lib.filterAttrs (_: file: file.enable) sm.config.environment.etc);
      owned = lib.filter (
        name: lib.elem name distributionOwned || lib.hasPrefix "nvidia" name || lib.hasPrefix "../" name
      ) managed;
      variant = if entry.bootstrap then "bootstrap" else "production";
    in
    lib.concatStrings [
      (check (owned == [ ])
        "${entry.name}: the system layer manages distribution-owned files: ${lib.concatStringsSep ", " owned}"
      )
      (lib.optionalString (entry.host.system == pkgs.stdenv.hostPlatform.system) ''
        sm=${sm}
        unit=$(jq -r '.["pcscd.service"].storePath // empty' "$sm/services/services.json")
        if [ -z "$unit" ] || ! grep -q '^ExecStart=/nix/store/[^ ]*/bin/pcscd ' "$unit"; then
          ${fail "${entry.name}: pcscd.service is missing or does not run pcscd"}
        else
          dropdir=$(sed -n 's/^Environment="PCSCLITE_HP_DROPDIR=\(.*\)"$/\1/p' "$unit")
          if [ ! -d "$dropdir/ifd-ccid.bundle" ]; then
            ${fail "${entry.name}: pcscd's driver directory holds no ccid bundle"}
          fi
          unit_path=$(sed -n 's/^Environment="PATH=\(.*\)"$/\1/p' "$unit")
          missing_tool=0
          for tool in mkdir find grep sed systemctl; do
            if ! (PATH="$unit_path"; command -v "$tool" >/dev/null 2>&1); then
              missing_tool=1
            fi
          done
          total_entries=$(printf '%s\n' "$unit_path" | tr ':' '\n' | wc -l)
          unique_entries=$(printf '%s\n' "$unit_path" | tr ':' '\n' | sort -u | wc -l)
          if [ -z "$unit_path" ] || [ "$missing_tool" != 0 ] || [ "$total_entries" -ne "$unique_entries" ]; then
            ${fail "${entry.name}: pcscd.service lacks a duplicate-free default service PATH"}
          fi
        fi
        if [ -z "$(jq -r '.["pcscd.socket"].storePath // empty' "$sm/services/services.json")" ]; then
          ${fail "${entry.name}: pcscd.socket is missing"}
        fi
        conf=$(jq -r '.entries["nix/nix.conf"].source // empty' "$sm/etcFiles/etcFiles.json")/nix/nix.conf
        if ! grep -qx 'build-users-group = nixbld' "$conf"; then
          ${fail "${entry.name}: nix.conf does not keep builds on the nixbld users"}
        fi
        if ! grep -qx 'trusted-users = root' "$conf"; then
          ${fail "${entry.name}: nix.conf trusts more than root"}
        fi
        marker=$(jq -r '.entries["nix-config-host"].source // empty' "$sm/etcFiles/etcFiles.json")/nix-config-host
        if ! grep -qx 'host=${entry.fixture}' "$marker" || ! grep -qx 'variant=${variant}' "$marker"; then
          ${fail "${entry.name}: /etc/nix-config-host does not record host ${entry.fixture}, variant ${variant}"}
        fi
      '')
    ];

  # The T3 Code CLI trait must be exercised, or its presence assertion would
  # only ever see the trait off.
  t3CliFixtures = lib.filter (entry: entry.host.home.config.my.t3.cli.enable) fixtures;
in
pkgs.runCommand "non-nixos-outputs" { nativeBuildInputs = [ pkgs.jq ]; } ''
  fail=0
  ${lib.optionalString (fixtures == [ ]) (fail "tests/fixtures/hosts holds no fixture host")}
  ${lib.optionalString (t3CliFixtures == [ ]) (fail "no fixture declares my.t3.cli.enable")}
  ${assertPairs}
  ${lib.concatMapStrings assertEntry fixtures}
  ${lib.concatMapStrings assertSystem fixtures}
  ${lib.concatMapStrings assertConsumers fixtures}
  [ "$fail" = 0 ] || exit 1
  touch "$out"
''
