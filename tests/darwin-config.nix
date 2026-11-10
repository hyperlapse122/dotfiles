/*
  Check interface:

    import ./tests/darwin-config.nix { inherit pkgs self linuxFixtures darwinFixtures; }

  `linuxFixtures` and `darwinFixtures` are tests/lib/linux-fixtures.nix and
  tests/lib/darwin-fixtures.nix. Evaluates the macOS fixture hosts on Linux,
  where no darwin derivation can be built, and renders what their options say
  into the builder. The materialized generation is read on a macOS builder by
  tests/darwin-outputs.nix.

  - Host discovery: every fixture whose host.nix names kind darwin is a macOS
    fixture and no other kind is; every macOS fixture yields a production and
    a bootstrap output.
  - GUI apps (modules/shared/darwin-apps.nix): every package a NixOS user has and no
    non-NixOS Linux fixture has, plus the 1Password GUI where NixOS enables
    it, has a macOS decision, and each decision is exactly one of a cask, a
    Nix package, or left out. The set is derived from the evaluated
    configurations, so a package added on NixOS fails here until it has one.
    Telegram maps to the telegram-desktop cask, the NixOS client, and the
    telegram cask (Telegram for macOS) is absent.
  - Homebrew: the casks are exactly the mapping's casks plus its macOS-only
    ones; an apply never removes an unlisted app and upgrades listed ones;
    every third-party cask's tap is tapped and trusted.
  - The user environment takes the non-NixOS path: production runs the
    host-secrets steps and bootstrap runs none; ~/.ssh/config names the host
    key; `nr` is nr-darwin; the YubiKey pinentry is
    the darwin filter, with pinentry_mac's Keychain checkbox unticked by
    default; VSCodium's settings live under Application Support; Ghostty has
    the NixOS font families and no nixpkgs package.
  - Containers: both variants init one rootful libkrun Podman machine with
    the configured memory and CPUs, reconcile an existing machine to them,
    keep the watchdog's VM alive across an agent reload at interactive
    priority, export the machine's socket to shells and GUI apps, write
    auth.json, and link `docker` to Podman; production adds the minikube
    login agent and bootstrap has none. No OrbStack cask, credHelpers merge,
    or Docker Hub index alias remains.
  - Codex: the pinned package is installed, the Codex settings merge runs
    with `--format toml` on ~/.codex/config.toml after installPackages, and
    `codex` is among the Compound Engineering peers.
  - Rust: sccache is installed and the Cargo settings merge runs with
    `--format toml` on ~/.cargo/config.toml after installPackages.
  - Compound Engineering peers: a login agent enabled at load runs
    `/bin/sh -c` with exactly two `/bin/launchctl setenv` lines, which set
    CROSS_MODEL_PEERS, joined with `,` alone, to the set of peers the
    installed packages call for (tests/lib/cross-model-peers.nix) and
    CROSS_MODEL_MAX_PEERS to 2; the session variables carry the same two
    values.
  - The system layer turns off store auto-optimisation, installs the shared
    font list, switches appearance automatically with AppleInterfaceStyle
    unset, and records the host and variant in /etc/nix-config-host.
  - Xcode: postActivation installs (mas install, then mas get) or upgrades
    App Store id 497799835 before Home Manager runs, every mas call runs in
    the primary user's session with SUDO_UID and SUDO_GID, and every mas,
    xcode-select, and xcodebuild action sits in an `if !` guard, so none can
    abort the `set -e` activate script. homebrew.masApps stays empty and
    programs.mas off.
  - KakaoTalk: after the Xcode step and before Home Manager, postActivation
    installs (mas install, then mas get) or upgrades App Store id 869223134
    through its own wrapper in the primary user's session, every call guarded
    the same way. A failed install names the App Store sign-in, a failed
    upgrade names the sign-in and the app bundle; unresolved ids name
    system.primaryUser.
  - Flighty: after the KakaoTalk step and before Home Manager, the same
    App Store step installs or upgrades App Store id 1358823008 the same way,
    with `flighty:` messages.
  - Retired casks: after the Flighty step and before Home Manager,
    postActivation uninstalls the installed grok-bot cask with
    `brew uninstall --cask --force`, never `--zap`, through the absolute brew
    path under `sudo --preserve-env=PATH --user` for the primary user with
    brew's prefix on PATH, the way nix-darwin calls brew bundle, since
    Homebrew refuses to run as root. Only a `brew list` failure with empty
    stderr or "Error: Cask 'grok-bot' is not installed." counts as no cask;
    any other failure prints brew's stderr on one line and skips the
    uninstall. Every brew call sits in an `if !` guard, each branch prints one
    line, and none exits, so a failure never aborts the apply. The cask has
    no entry in modules/shared/darwin-apps.nix.
  - Android SDK: Home Manager links it at ~/Library/Android/sdk and declares
    no android-sdk data file; ANDROID_HOME and ANDROID_SDK_ROOT name that
    path, and the PATH assignment gains its emulator directory; the linked
    SDK builds one arm64-v8a Google APIs image per pinned platform and no
    x86_64 image.
  - Mobile devices: my.mobileDevices defaults to one android and no ios
    device and rejects an empty model or version; the mobileDevices step runs
    after linkGeneration and calls the mobile-devices helper only outside a
    dry run, from an `elif !` condition whose branch only echoes, so a
    failing helper cannot abort activation. The call passes /usr/bin/xcrun,
    the SDK root, every declared device, and the newest pinned API with an
    arm64-v8a image, which tests/lib/android-pin.nix reads from the pin. No
    non-NixOS Linux fixture has the step.

  - Korean skills: Home Manager links the humanizer, grammar-checker, and
    style-guide directories of the korean-skills-v1.0.0 tree under
    ~/.claude/skills, ~/.gemini/antigravity-cli/skills, and ~/.codex/skills,
    each as exactly one enabled file, and the in-tree test-audit skill
    directory beside them, plus every skill of the pinned compound-engineering
    input under ~/.gemini/antigravity-cli/skills, and nothing else under those
    roots; OMP receives its contributed ~/.omp/agent/skills root; nothing
    lands under ~/.agents/skills or ~/.gemini/config/skills.

  - TLS inspection CA: my.tlsInspectionCa.enable defaults to false and the
    fixture enables it. In production, the bundle step runs before the /etc
    step with this generation's CA bundle as its base, the CA file, the host
    identity and its owner, and /etc/ssl/nix-config as its output; the trust
    step runs after it inside an `if !` guard; shells and nix-daemon name /etc/ssl/nix-config/ca-certificates.crt
    in all six CA variables, a RunAtLoad login agent sets them for GUI apps,
    and the trait without a CA file fails an assertion. Bootstrap runs no
    step, has no agent, and keeps nix-darwin's default bundle.
  - Network recovery: my.networkRecovery.enable defaults to false and the
    fixture enables it. In production a root daemon runs the packaged script
    at load and every 5 seconds with /var/db/network-recovery and the
    Tailscale app's CLI, logging to /var/log/network-recovery.log, newsyslog
    rotates that log, and the user's session sets
    CLAUDE_BYTE_STREAM_IDLE_TIMEOUT_MS to 60000. Bootstrap has none of it.
  - Dock: the pinned apps are the shared list in order, with the fixture's
    my.dock.hostApps between ChatGPT and Discord and T3 Code (Nightly) only
    with my.t3.desktop; Downloads is the one right-side folder, as a fanned
    stack sorted by date added; recent apps are hidden, the tile size is 32,
    and position, auto-hide, magnification, and minimize settings are unset.

  Every comparison is rendered into the builder, so a failure names the
  fixture and the reason instead of aborting evaluation. No darwin store path
  is interpolated, so the check builds on Linux.
*/
{
  pkgs,
  self,
  linuxFixtures,
  darwinFixtures,
}:
let
  inherit (pkgs) lib;

  fail = message: ''
    echo ${lib.escapeShellArg message} >&2
    fail=1
  '';

  check = condition: message: lib.optionalString (!condition) (fail message);

  plain = builtins.unsafeDiscardStringContext;

  # lib.hasInfix matches ".*<infix>.*", and on Linux Nix's regex engine
  # recurses once per character it scans, so a search across a whole
  # activation script, Dock plists included, overflows the evaluator's stack.
  # Search one line at a time for an infix that holds no newline.
  hasInfixInLines = infix: text: lib.any (lib.hasInfix infix) (lib.splitString "\n" text);

  # A store path's hash or name can spell "zap" by chance, so the zap check
  # reads the whole activation script with every store path replaced by a
  # fixed word.
  withoutStorePaths =
    text:
    lib.concatStrings (
      map (part: if lib.isString part then part else "/nix/store/STOREPATH") (
        builtins.split "/nix/store/[0-9a-z]{32}-[-+._?=A-Za-z0-9]+" (plain text)
      )
    );

  # The zap check's own regression cases, so a widened cut cannot hide a real
  # --zap and a narrowed one cannot let a store path fail the check again.
  assertZapFilter = lib.concatStrings [
    (check (
      !lib.hasInfix "zap" (withoutStorePaths "/nix/store/r8m1ldyh1jglwgqzapjizark25g4l97w-activate")
    ) "zap check: a store hash that spells zap must not count as a zap")
    (check (
      !lib.hasInfix "zap" (withoutStorePaths "/nix/store/r8m1ldyh1jglwgqqapjizark25g4l97w-zapper/bin/x")
    ) "zap check: a store path name that holds zap must not count as a zap")
    (check (lib.hasInfix "zap" (withoutStorePaths "/nix/store/r8m1ldyh1jglwgqqapjizark25g4l97w-brew/bin/brew uninstall --cask --zap foo")) "zap check: a real --zap after a store path must still count as a zap")
  ];

  namesOf = packages: lib.unique (map (p: p.pname or (lib.getName p)) packages);

  androidPin = import ./lib/android-pin.nix { inherit lib; };
  expectedPeers = import ./lib/cross-model-peers.nix { inherit lib; };

  hosts = import ../lib/hosts.nix { inherit lib; } ./fixtures/hosts;
  kindOf = fixture: (import (./fixtures/hosts + "/${fixture}/host.nix")).kind or null;

  assertDiscovery = lib.concatStrings [
    (check (hosts.darwin != [ ]) "tests/fixtures/hosts holds no macOS fixture host")
    (lib.concatMapStrings (
      fixture:
      check (
        kindOf fixture == "darwin"
      ) "${fixture}: listed as macOS, but host.nix names kind ${toString (kindOf fixture)}"
    ) hosts.darwin)
    (lib.concatMapStrings (
      fixture:
      check (
        kindOf fixture != "darwin"
      ) "${fixture}: host.nix names kind darwin, but it is listed as a Linux host"
    ) hosts.linux)
    (check (
      lib.sort lib.lessThan (lib.unique (map (e: e.fixture) darwinFixtures))
      == lib.sort lib.lessThan hosts.darwin
    ) "the macOS fixture assembly does not cover exactly the macOS fixture hosts")
    (lib.concatMapStrings (
      fixture:
      let
        variants = map (e: e.bootstrap) (lib.filter (e: e.fixture == fixture) darwinFixtures);
      in
      check (
        lib.elem false variants && lib.elem true variants
      ) "${fixture}: expected a production and a bootstrap output"
    ) hosts.darwin)
  ];

  # The NixOS-only package set the mapping must cover.
  nixosConfigs = lib.attrValues (
    lib.filterAttrs (name: _: !lib.hasSuffix "-bootstrap" name) self.nixosConfigurations
  );
  nixosNames = lib.unique (
    lib.concatMap (c: namesOf c.config.home-manager.users.h82.home.packages) nixosConfigs
  );
  linuxNames = lib.unique (lib.concatMap (e: namesOf e.host.home.config.home.packages) linuxFixtures);
  onePassword = lib.optional (lib.any (
    c: c.config.programs._1password-gui.enable
  ) nixosConfigs) "1password";
  required = lib.subtractLists linuxNames nixosNames ++ onePassword;

  mapping = import ../modules/shared/darwin-apps.nix;
  kinds = [
    "cask"
    "nix"
    "leftOut"
  ];
  expectedCasks = mapping.casks;

  assertMapping = lib.concatStrings [
    (check (required != [ ]) "no package is NixOS-only, so the mapping check would pass vacuously")
    (lib.concatMapStrings (
      name:
      check (
        mapping.apps ? ${name}
      ) "${name}: installed on NixOS but has no macOS decision in modules/shared/darwin-apps.nix"
    ) required)
    (lib.concatStrings (
      lib.mapAttrsToList (
        name: app:
        check (
          lib.length (lib.attrNames app) == 1 && lib.elem (lib.head (lib.attrNames app)) kinds
        ) "${name}: the macOS decision must be exactly one of cask, nix, or leftOut"
      ) mapping.apps
    ))
    # Pinned by name, not taken from the mapping: other assertions and the
    # docs rely on these casks, and dropping one from the mapping must fail.
    (lib.concatMapStrings
      (cask: check (lib.elem cask mapping.casks) "${cask} is not among the macOS casks")
      [
        "chatgpt"
        "ghostty"
        "1password"
        "parallels"
        "tailscale-app"
      ]
    )
    (check (!lib.elem "orbstack" mapping.casks) "orbstack is still among the macOS casks")
    # macOS runs the NixOS Telegram client, not Telegram for macOS.
    (check (
      mapping.apps.telegram-desktop or null == { cask = "telegram-desktop"; }
    ) "telegram-desktop: the macOS decision must be the telegram-desktop cask")
    (check (!lib.elem "telegram" mapping.casks) "telegram is still among the macOS casks")
    (check (
      mapping.tapOf "owner/tap/cask" == "owner/tap" && mapping.tapOf "ghostty" == null
    ) "tapOf must return owner/tap for a third-party cask and null for a core cask")
  ];

  sort = lib.sort lib.lessThan;

  assertEntry =
    entry:
    let
      config = entry.host.config;
      user = config.home-manager.users.${config.my.user.name};
      activation = user.home.activation;
      pnames = namesOf user.home.packages;
      casks = map (cask: cask.name) config.homebrew.casks;
      taps = map (tap: tap.name) config.homebrew.taps;
      thirdParty = lib.filter (cask: mapping.tapOf cask != null) expectedCasks;
      sessionVariables = user.home.sessionVariables;
      ryukVariables = lib.filter (name: sessionVariables ? ${name}) [
        "TESTCONTAINERS_RYUK_CONTAINER_PRIVILEGED"
        "TESTCONTAINERS_RYUK_PRIVILEGED"
      ];
      # By target, so an entry renamed onto the drop-in directory is still caught.
      dropIns = lib.filter (target: lib.hasPrefix "containers/registries.conf.d" target) (
        map (file: file.target) (lib.filter (file: file.enable) (lib.attrValues user.xdg.configFile))
      );
      agents = user.launchd.agents;
      agentConfig = name: agents.${name}.config or { };
      watchdog = agentConfig "podman-machine-podman-machine-default";
      minikubeAgent = agentConfig "minikube";
      minikubeArgs = plain (lib.concatStringsSep " " (minikubeAgent.ProgramArguments or [ ]));
      minikubePath = plain (minikubeAgent.EnvironmentVariables.PATH or "");
      guiEnvironment = plain (
        lib.concatStringsSep " " ((agentConfig "container-environment").ProgramArguments or [ ])
      );
      peers = expectedPeers user.home.packages;
      peerAgent = agents.cross-model-peers or { };
      peerArgs = map plain (peerAgent.config.ProgramArguments or [ ]);
      # Each setenv line as its words, split on single spaces, so a list
      # joined with ", " gains a word and fails the length test.
      peerSetenvs = map (lib.splitString " ") (
        lib.filter (line: line != "") (
          map lib.trim (lib.splitString "\n" (if lib.length peerArgs == 3 then lib.elemAt peerArgs 2 else ""))
        )
      );
      peerSetenvValue =
        name:
        let
          matches = lib.filter (
            words:
            lib.length words == 4
            &&
              lib.take 3 words == [
                "/bin/launchctl"
                "setenv"
                name
              ]
          ) peerSetenvs;
        in
        if lib.length matches == 1 then lib.last (lib.head matches) else null;
      peerSet = value: if value == null then null else sort (lib.splitString "," value);
      machinesData = plain (activation.podmanMachines.data or "");
      machineInits = lib.length (lib.filter lib.isList (builtins.split "machine init " machinesData));
      resourcesStep = activation.podmanMachineResources or { };
      # The helper stops the machine, so a dry run must reach only the echo.
      resourcesBranches = lib.splitString "else" (plain (resourcesStep.data or ""));
      resourcesGuarded =
        lib.length resourcesBranches == 2
        && lib.hasInfix "if [[ -v DRY_RUN ]]; then" (lib.head resourcesBranches)
        && !lib.hasInfix "podman-machine-resources/bin" (lib.head resourcesBranches)
        && lib.hasInfix "podman-machine-resources/bin" (lib.last resourcesBranches);
      nixApps = lib.attrNames (lib.filterAttrs (_: app: app ? nix) mapping.apps);
      missingNixApps = lib.filter (
        name: !lib.elem name pnames && (name != "t3code-desktop" || user.my.t3.desktop.enable)
      ) nixApps;
      credentialHelper = lib.findFirst (
        p: (p.pname or "") == "docker-credential-sops"
      ) null user.home.packages;
      routingTable = credentialHelper.routingTable or { };
      codex = lib.findFirst (p: (p.pname or "") == "codex") null user.home.packages;
      sshText = plain user.my.ssh.configFile.drvAttrs.text;
      pinentry = user.services.gpg-agent.pinentry.package;
      vscodiumData = plain (activation.vscodiumSettings.data or "");
      codexData = plain (activation.codexSettings.data or "");
      cargoData = plain (activation.cargoSettings.data or "");
      markerEntry = lib.findFirst (e: (e.enable or false) && (e.target or "") == "nix-config-host") null (
        lib.attrValues (config.environment.etc or { })
      );
      marker = if markerEntry == null then "" else markerEntry.text or "";
      production = !entry.bootstrap;
      primaryUser = config.system.primaryUser;
      xcodeId = "497799835";
      kakaoTalkId = "869223134";
      flightyId = "1358823008";
      masExe = plain (lib.getExe entry.host.pkgs.mas);
      postActivation = plain config.system.activationScripts.postActivation.text;
      activationWithoutStorePaths = withoutStorePaths config.system.activationScripts.script.text;
      homeManagerCall = "Activating home-manager configuration";
      beforeHomeManager = lib.head (lib.splitString homeManagerCall postActivation);
      rootLines = map lib.trim (lib.splitString "\n" beforeHomeManager);
      guarded = line: lib.hasPrefix "if ! " line || lib.hasPrefix "elif ! " line;
      masAsUser =
        prefix:
        ''/bin/launchctl asuser "${prefix}Uid" /usr/bin/env SUDO_UID="${prefix}Uid" SUDO_GID="${prefix}Gid" ${masExe} '';
      masLines = lib.filter (lib.hasInfix masExe) rootLines;
      masWrappers = [
        "xcodeMas"
        "appStoreMas"
      ];
      masWrapperCalls = lib.filter (
        line:
        lib.any (wrapper: lib.hasInfix "${wrapper} " line && !lib.hasPrefix "${wrapper}()" line) masWrappers
      ) rootLines;
      lineIndex = line: lib.lists.findFirstIndex (l: l == line) null rootLines;
      brewExe = "${config.homebrew.prefix}/bin/brew";
      brewLines = lib.filter (lib.hasInfix brewExe) rootLines;
      retiredBrewCalls = lib.filter (
        line: lib.hasInfix "retiredBrew " line && !lib.hasPrefix "retiredBrew()" line
      ) rootLines;
      retiredList = "if ! retiredList=$(retiredBrew list --cask grok-bot 2>&1 >/dev/null); then";
      retiredStart = lineIndex retiredList;
      retiredBlock = [
        retiredList
        ''if [ -z "$retiredList" ] || [ "$retiredList" = "Error: Cask 'grok-bot' is not installed." ]; then''
        ''echo "retired casks: no grok-bot cask to remove" >&2''
        "else"
        ''echo "retired casks: could not tell whether grok-bot is installed: ''${retiredList//$'\n'/ }; run brew list --cask grok-bot as ${primaryUser}" >&2''
        "fi"
        "elif ! retiredBrew uninstall --cask --force grok-bot; then"
        ''echo "retired casks: uninstalling grok-bot failed; run brew uninstall --cask --force grok-bot as ${primaryUser}" >&2''
        "else"
        ''echo "retired casks: removed the grok-bot cask" >&2''
        "fi"
      ];
      xcodeInstall = "if ! xcodeMas install ${xcodeId} && ! xcodeMas get ${xcodeId}; then";
      kakaoInstall = "if ! appStoreMas install ${kakaoTalkId} && ! appStoreMas get ${kakaoTalkId}; then";
      flightyInstall = "if ! appStoreMas install ${flightyId} && ! appStoreMas get ${flightyId}; then";
      xcodebuildActions = lib.filter (
        line:
        lib.hasInfix "-license accept" line
        || lib.hasInfix "-runFirstLaunch" line
        || lib.hasInfix "xcode-select -s" line
      ) rootLines;
      # Where T3 Code's device hub looks when ANDROID_HOME is unset.
      androidSdkRoot = "${config.my.user.home}/Library/Android/sdk";
      # By target, so an entry renamed onto the path is still found.
      androidSdkFile = lib.findFirst (file: file.enable && file.target == "Library/Android/sdk") null (
        lib.attrValues user.home.file
      );
      # One derivation per API level and image type, named after its ABIs.
      androidImages = map (image: image.name) (androidSdkFile.source.systemImages or [ ]);
      androidDataFiles = lib.filter (file: file.enable && file.target == "android-sdk") (
        lib.attrValues user.xdg.dataFile
      );
      # The PATH assignment itself, so another line naming the directory
      # cannot stand in for it.
      pathLines = lib.filter (lib.hasPrefix "export PATH=") (
        map lib.trim (lib.splitString "\n" (plain user.home.sessionVariablesExtra))
      );
      # The Korean writing skills: the harness roots and skill names are
      # literals, so a mutated registry or root cannot move the expectation.
      koreanRoots = [
        ".claude/skills"
        ".gemini/antigravity-cli/skills"
        ".codex/skills"
      ];
      koreanNames = [
        "humanizer"
        "grammar-checker"
        "style-guide"
      ];
      koreanTargets = lib.concatMap (root: map (name: "${root}/${name}") koreanNames) koreanRoots;
      # The vendored test-audit skill shares those roots; its source is the
      # in-tree skill directory inside the flake's source tree.
      testAuditTargets = map (root: "${root}/test-audit") koreanRoots;
      # The pinned design and stack skills and the local design-lenses and
      # ux-flows skills share those roots too; tests/pinned-skills.nix checks
      # their content on Linux.
      pinnedTargets = lib.concatMap (
        root:
        map (name: "${root}/${name}") [
          "frontend-design"
          "web-design-guidelines"
          "vercel-react-best-practices"
          "vercel-composition-patterns"
          "vercel-react-native-skills"
          "expo-native-ui"
          "expo-upgrade"
          "expo-ui"
          "expo-animation"
          "expo-router"
          "expo-data-fetching"
          "playwright-best-practices"
          "ux-writing"
          "cli-design"
          "design-lenses"
          "ux-flows"
        ]
      ) koreanRoots;
      # Antigravity loads no plugins, so its root also holds every skill of
      # the pinned Compound Engineering input, named by that input.
      ceSkillsDir = "${self.inputs.compound-engineering-plugin}/skills";
      ceTargets = map (name: ".gemini/antigravity-cli/skills/${name}") (
        lib.attrNames (
          lib.filterAttrs (
            name: type: type == "directory" && builtins.pathExists "${ceSkillsDir}/${name}/SKILL.md"
          ) (builtins.readDir ceSkillsDir)
        )
      );
      # Resolved targets of enabled entries, not attribute names. The source is
      # compared as a string with its context dropped, so no darwin derivation
      # is built, and the store path is never interpolated.
      enabledFiles = lib.filter (file: file.enable) (lib.attrValues user.home.file);
      enabledTargets = map (file: file.target) enabledFiles;
      koreanFilesAt = target: lib.filter (file: file.target == target) enabledFiles;
      koreanSourceOf = file: plain (toString (file.source or ""));
      underDir = dir: target: target == dir || lib.hasPrefix "${dir}/" target;
      koreanUnderRoots = lib.filter (
        target: lib.any (root: underDir root target) koreanRoots
      ) enabledTargets;
      koreanElsewhere = lib.filter (
        target: underDir ".agents/skills" target || underDir ".gemini/config/skills" target
      ) enabledTargets;
      devicesStep = activation.mobileDevices or { };
      devicesData = plain (devicesStep.data or "");
      # The helper creates devices, so a dry run must reach only the echo:
      # its one call is the `elif !` condition after the DRY_RUN branch, and
      # activation is `set -e`, so a non-zero exit must reach only the one
      # echo of that branch, right before fi.
      devicesLines = lib.filter (line: line != "") (map lib.trim (lib.splitString "\n" devicesData));
      devicesCount = lib.length devicesLines;
      devicesLine =
        offset: if devicesCount > offset then lib.elemAt devicesLines (devicesCount - 1 - offset) else "";
      devicesCall = devicesLine 2;
      devicesGuarded =
        devicesCount >= 5
        && lib.head devicesLines == "if [[ -v DRY_RUN ]]; then"
        && lib.filter (lib.hasInfix "mobile-devices/bin/mobile-devices ") devicesLines == [ devicesCall ];
      devicesContained =
        lib.hasPrefix "elif ! " devicesCall
        && lib.hasSuffix "; then" devicesCall
        && lib.hasPrefix "echo \"mobileDevices: " (devicesLine 1)
        && lib.hasSuffix " >&2" (devicesLine 1)
        && devicesLine 0 == "fi";
      devices = user.my.mobileDevices or [ ];
      platformCount = platform: lib.length (lib.filter (device: device.platform == platform) devices);
    in
    lib.concatStrings [
      (check config.homebrew.enable "${entry.name}: homebrew is off, so an apply installs none of the casks")
      (check (sort casks == sort expectedCasks)
        "${entry.name}: homebrew.casks is ${builtins.toJSON (sort casks)}, the mapping gives ${builtins.toJSON (sort expectedCasks)}"
      )
      (check (config.homebrew.onActivation.cleanup == "none")
        "${entry.name}: homebrew cleanup is ${config.homebrew.onActivation.cleanup}, so an apply removes apps installed outside the list"
      )
      (check config.homebrew.onActivation.upgrade "${entry.name}: homebrew upgrade is off, so an apply never updates listed apps")
      (check config.homebrew.onActivation.autoUpdate "${entry.name}: homebrew autoUpdate is off, so brew bundle never refreshes cask metadata and upgrade sees no newer version")
      (check (missingNixApps == [ ])
        "${entry.name}: apps the mapping installs from Nix are missing: ${lib.concatStringsSep ", " missingNixApps}"
      )
      (check (user.my.t3.desktop.enable && lib.elem "t3code-desktop" pnames)
        "${entry.name}: the macOS fixture must enable and install the T3 Code desktop app, or its darwin-outputs assertions vanish"
      )
      (check (routingTable ? "docker.io" && !(routingTable ? "https://index.docker.io/v1/"))
        "${entry.name}: the credential helper must route docker.io and no longer the Docker Hub index alias"
      )
      (check (codex != null) "${entry.name}: codex must be installed")
      (check (lib.elem "codex" peers) "${entry.name}: codex is installed, so CROSS_MODEL_PEERS must allow it")
      (check
        (
          lib.elem "installPackages" (activation.codexSettings.after or [ ])
          && lib.hasInfix "--format toml" codexData
          && lib.hasInfix "--settings ${config.my.user.home}/.codex/config.toml" codexData
        )
        "${entry.name}: activation must merge the declared Codex settings into ~/.codex/config.toml as TOML after installPackages"
      )
      (check (lib.elem "sccache" pnames) "${entry.name}: sccache must be installed")
      (check
        (
          lib.elem "installPackages" (activation.cargoSettings.after or [ ])
          && lib.hasInfix "--format toml" cargoData
          && lib.hasInfix "--settings ${config.my.user.home}/.cargo/config.toml" cargoData
        )
        "${entry.name}: activation must merge the declared Cargo settings into ~/.cargo/config.toml as TOML after installPackages"
      )
      (check
        (
          sort taps == sort (lib.unique (map mapping.tapOf thirdParty))
          && sort config.nix-homebrew.trust.casks == sort thirdParty
        )
        "${entry.name}: homebrew.taps and nix-homebrew.trust.casks must match the third-party casks in expectedCasks"
      )
      (check config.nix-homebrew.enable "${entry.name}: nix-homebrew is off, so a new Mac needs Homebrew installed by hand")
      (check (
        activation ? nixConfigSecretsStage == production
        && activation ? nixConfigSecretsPublish == production
      ) "${entry.name}: the host-secrets steps must run in production and never in bootstrap")
      (check (!activation ? dockerCredHelpers) "${entry.name}: the OrbStack credHelpers merge still runs")
      (check (
        lib.hasInfix "IdentityFile ${user.my.secrets.sshKey}" sshText
        && !lib.hasInfix "IdentityAgent" sshText
      ) "${entry.name}: ~/.ssh/config must name the host key and no agent socket")
      (check
        (
          machineInits == 1
          && lib.hasInfix "machine init podman-machine-default " machinesData
          && lib.hasInfix "--rootful" machinesData
          && lib.hasInfix "--memory 8192" machinesData
          && lib.hasInfix "--cpus 4" machinesData
        )
        "${entry.name}: activation must init exactly podman-machine-default, rootful, with 8192 MiB and 4 CPUs"
      )
      (check (
        (user.services.podman.settings.containers.machine.provider or null) == "libkrun"
        && activation ? podmanContainersConfig
      ) "${entry.name}: containers.conf must select the libkrun machine provider")
      (check
        (
          lib.elem "podmanMachines" (resourcesStep.after or [ ])
          && lib.hasInfix "podman-machine-resources" (plain (resourcesStep.data or ""))
          && lib.hasInfix "podman-machine-default 8192 4" (plain (resourcesStep.data or ""))
        )
        "${entry.name}: activation must reconcile the machine to 8192 MiB and 4 CPUs after podmanMachines"
      )
      (check resourcesGuarded "${entry.name}: a dry run must not run the machine reconciliation helper")
      (check (lib.hasInfix "TMPDIR=$(/usr/bin/getconf DARWIN_USER_TEMP_DIR)" (lib.last resourcesBranches)) "${entry.name}: the reconciliation helper must run with the user's temporary directory")
      (check
        (
          (agents.podman-machine-podman-machine-default.enable or false)
          && (watchdog.AbandonProcessGroup or null) == true
          && (watchdog.ProcessType or null) == "Interactive"
          && (watchdog.RunAtLoad or null) == true
        )
        "${entry.name}: the machine watchdog must abandon its process group, run at interactive priority, and start at load"
      )
      (check
        (
          lib.hasSuffix "podman/podman-machine-default-api.sock" (sessionVariables.DOCKER_HOST or "")
          && sessionVariables ? REGISTRY_AUTH_FILE
          && (sessionVariables.TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE or null) == "/var/run/docker.sock"
          && ryukVariables == [ ]
        )
        "${entry.name}: the session must name the machine's socket, auth.json and the VM's Docker socket, and no Ryuk privilege variable"
      )
      (check (
        (agents.container-environment.enable or false)
        && lib.hasInfix "launchctl setenv DOCKER_HOST" guiEnvironment
        && lib.hasInfix "podman/podman-machine-default-api.sock" guiEnvironment
        && lib.hasInfix "launchctl setenv TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE" guiEnvironment
        && ((agentConfig "container-environment").RunAtLoad or null) == true
      ) "${entry.name}: a login agent must export the machine's socket to GUI apps")
      (check (
        peers != [ ]
      ) "${entry.name}: no installed package calls for a CE peer, so the peer check would cover none")
      (check
        (
          (peerAgent.enable or false)
          && (peerAgent.config.RunAtLoad or null) == true
          &&
            lib.take 2 peerArgs == [
              "/bin/sh"
              "-c"
            ]
          && lib.length peerSetenvs == 2
          && peerSet (peerSetenvValue "CROSS_MODEL_PEERS") == peers
          && peerSetenvValue "CROSS_MODEL_MAX_PEERS" == "2"
        )
        "${entry.name}: a login agent must set CROSS_MODEL_PEERS to ${lib.concatStringsSep "," peers} and CROSS_MODEL_MAX_PEERS to 2 for GUI apps"
      )
      (check
        (
          peerSet (sessionVariables.CROSS_MODEL_PEERS or null) == peers
          && (sessionVariables.CROSS_MODEL_MAX_PEERS or null) == "2"
        )
        "${entry.name}: the session must set CROSS_MODEL_PEERS to ${lib.concatStringsSep "," peers} and CROSS_MODEL_MAX_PEERS to 2"
      )
      (check (lib.elem "docker-podman-compat" pnames) "${entry.name}: docker must be the Podman link")
      (check (
        activation ? containersAuth
      ) "${entry.name}: containersAuth must be wired; native darwin-outputs verifies its effects")
      (check (dropIns == [ ]) "${entry.name}: the store-linked registries.conf.d drop-in reached macOS")
      (check
        (
          if production then
            (agents.minikube.enable or false)
            && lib.hasInfix "minikube-darwin-start" minikubeArgs
            # The node gets half of the machine: 4096 MiB and 2 CPUs, last.
            && lib.hasSuffix " 4096 2" minikubeArgs
            && (minikubeAgent.RunAtLoad or null) == true
            && (minikubeAgent.KeepAlive.SuccessfulExit or null) == false
            && (minikubeAgent.AbandonProcessGroup or null) == true
            && lib.hasInfix "-podman-" minikubePath
            && lib.hasInfix "-minikube-" minikubePath
          else
            !(agents.minikube.enable or false)
        )
        "${entry.name}: the minikube login agent must run in production, retried on failure, and never in bootstrap"
      )
      (check (
        lib.elem "nr-darwin" pnames && !lib.elem "nr" pnames && !lib.elem "nr-linux" pnames
      ) "${entry.name}: nr must be nr-darwin")
      (check (
        lib.hasInfix "pinentry-card-darwin" (plain (pinentry.drvAttrs.installPhase or ""))
        && lib.hasInfix "pinentry-mac" (plain (pinentry.drvAttrs.installPhase or ""))
      ) "${entry.name}: the YubiKey pinentry must be the darwin filter in front of pinentry_mac")
      (check ((user.targets.darwin.defaults."org.gpgtools.pinentry-mac".UseKeychain or null) == false)
        "${entry.name}: pinentry_mac's UseKeychain default must be false, or Save in Keychain starts ticked"
      )
      (check (lib.hasInfix "Library/Application Support/VSCodium/User/settings.json" vscodiumData) "${entry.name}: the VSCodium settings merge must target Library/Application Support/VSCodium/User")
      (check (
        user.programs.ghostty.package == null
      ) "${entry.name}: Ghostty must come from the cask, not nixpkgs")
      (check (
        user.programs.ghostty.settings.font-family or [ ] == [
          "JetBrainsMono Nerd Font"
          "D2CodingLigature Nerd Font"
          "D2KodingLigature Nerd Font"
          "Twitter Color Emoji"
        ]
      ) "${entry.name}: Ghostty's font-family differs from the NixOS terminal's")
      (check (
        !config.nix.settings.auto-optimise-store
      ) "${entry.name}: auto-optimise-store must be off on macOS")
      (check (
        namesOf config.fonts.packages == namesOf (import ../modules/shared/font-packages.nix pkgs)
      ) "${entry.name}: the macOS font list differs from modules/shared/font-packages.nix")
      (check (
        config.system.defaults.NSGlobalDomain.AppleInterfaceStyleSwitchesAutomatically == true
        && config.system.defaults.NSGlobalDomain.AppleInterfaceStyle == null
      ) "${entry.name}: appearance must switch automatically, with AppleInterfaceStyle unset")
      (check (
        lib.hasInfix "host=${entry.fixture}\n" marker
        && lib.hasInfix "variant=${if entry.bootstrap then "bootstrap" else "production"}\n" marker
      ) "${entry.name}: /etc/nix-config-host must record the host and variant")
      (check (lib.hasInfix homeManagerCall postActivation && masLines != [ ])
        "${entry.name}: postActivation must run the Xcode step, with mas, before Home Manager's activation"
      )
      (check
        (lib.all (
          line: lib.hasInfix (masAsUser "$xcode") line || lib.hasInfix (masAsUser "$appStore") line
        ) masLines)
        "${entry.name}: every mas call must run through launchctl asuser with SUDO_UID and SUDO_GID of the primary user"
      )
      (check (
        lib.elem "xcodeUid=$(/usr/bin/id -u ${primaryUser} 2>/dev/null) || xcodeUid=" rootLines
        && lib.elem "xcodeGid=$(/usr/bin/id -g ${primaryUser} 2>/dev/null) || xcodeGid=" rootLines
      ) "${entry.name}: the Xcode step must resolve the uid and gid of ${primaryUser} at activation time")
      (check
        (
          lib.all (line: lib.hasSuffix " \"$@\"" line) masLines
          && masWrapperCalls != [ ]
          && lib.all guarded masWrapperCalls
        )
        "${entry.name}: every mas call must be guarded by if !, so a failed App Store call cannot abort activation"
      )
      (check (lib.elem xcodeInstall rootLines) "${entry.name}: Xcode (497799835) must be installed with mas install, falling back to mas get")
      (check (lib.elem "elif ! xcodeMas upgrade ${xcodeId}; then" rootLines) "${entry.name}: an installed Xcode must be upgraded with mas upgrade 497799835")
      (check (lib.any
        (line: lib.hasPrefix "echo \"xcode: " line && lib.hasInfix "sign in to the App Store" line)
        rootLines
      ) "${entry.name}: a failed Xcode install must print a message naming the App Store sign-in")
      (check
        (
          lib.elem "appStoreUid=$(/usr/bin/id -u ${primaryUser} 2>/dev/null) || appStoreUid=" rootLines
          && lib.elem "appStoreGid=$(/usr/bin/id -g ${primaryUser} 2>/dev/null) || appStoreGid=" rootLines
        )
        "${entry.name}: the KakaoTalk step must resolve the uid and gid of ${primaryUser} at activation time"
      )
      (check (lib.elem kakaoInstall rootLines) "${entry.name}: KakaoTalk (869223134) must be installed with mas install, falling back to mas get")
      (check
        (
          let
            missing = lineIndex "elif [[ ! -d /Applications/KakaoTalk.app ]]; then";
            install = lineIndex kakaoInstall;
            upgrade = lineIndex "elif ! appStoreMas upgrade ${kakaoTalkId}; then";
          in
          missing != null && install != null && upgrade != null && missing < install && install < upgrade
        )
        "${entry.name}: KakaoTalk must be installed when /Applications/KakaoTalk.app is missing and upgraded with mas upgrade 869223134 otherwise"
      )
      (check (
        let
          xcode = lineIndex xcodeInstall;
          kakao = lineIndex kakaoInstall;
        in
        xcode != null && kakao != null && xcode < kakao
      ) "${entry.name}: the KakaoTalk step must run after the Xcode step and before Home Manager")
      (check (lib.any
        (line: lib.hasPrefix "echo \"kakaotalk: " line && lib.hasInfix "sign in to the App Store" line)
        rootLines
      ) "${entry.name}: a failed KakaoTalk install must print a message naming the App Store sign-in")
      (check (lib.any
        (
          line:
          lib.hasPrefix "echo \"kakaotalk: cannot resolve" line && lib.hasInfix "system.primaryUser" line
        )
        rootLines
      ) "${entry.name}: unresolved ids must print a message naming system.primaryUser, not the App Store")
      (lib.concatMapStrings
        (
          app:
          check
            (
              let
                upgrade = lineIndex "elif ! appStoreMas upgrade ${app.id}; then";
                message = lib.elemAt rootLines (upgrade + 1);
              in
              upgrade != null
              && lib.hasPrefix "echo \"${app.tag}: App Store upgrade failed; " message
              && lib.hasInfix "signed in to the App Store" message
              && lib.hasInfix "/Applications/${app.name}.app came from the App Store" message
            )
            "${entry.name}: a failed ${app.name} upgrade must print a ${app.tag} message naming the App Store sign-in and /Applications/${app.name}.app"
        )
        [
          {
            name = "KakaoTalk";
            id = kakaoTalkId;
            tag = "kakaotalk";
          }
          {
            name = "Flighty";
            id = flightyId;
            tag = "flighty";
          }
        ]
      )
      (check (lib.elem flightyInstall rootLines) "${entry.name}: Flighty (1358823008) must be installed with mas install, falling back to mas get")
      (check
        (
          let
            missing = lineIndex "elif [[ ! -d /Applications/Flighty.app ]]; then";
            install = lineIndex flightyInstall;
            upgrade = lineIndex "elif ! appStoreMas upgrade ${flightyId}; then";
          in
          missing != null && install != null && upgrade != null && missing < install && install < upgrade
        )
        "${entry.name}: Flighty must be installed when /Applications/Flighty.app is missing and upgraded with mas upgrade 1358823008 otherwise"
      )
      (check (
        let
          kakao = lineIndex kakaoInstall;
          flighty = lineIndex flightyInstall;
        in
        kakao != null && flighty != null && kakao < flighty
      ) "${entry.name}: the Flighty step must run after the KakaoTalk step and before Home Manager")
      (check (lib.any
        (line: lib.hasPrefix "echo \"flighty: " line && lib.hasInfix "sign in to the App Store" line)
        rootLines
      ) "${entry.name}: a failed Flighty install must print a message naming the App Store sign-in")
      (check
        (lib.any (
          line: lib.hasPrefix "echo \"flighty: cannot resolve" line && lib.hasInfix "system.primaryUser" line
        ) rootLines)
        "${entry.name}: unresolved ids must print a Flighty message naming system.primaryUser, not the App Store"
      )
      (check
        (
          lib.length xcodebuildActions == 3
          && lib.all (
            line:
            guarded line
            && (lib.hasInfix "/usr/bin/xcodebuild " line || lib.hasInfix "/usr/bin/xcode-select " line)
          ) xcodebuildActions
          && lib.elem "if ! /usr/bin/xcodebuild -license check >/dev/null 2>&1; then" rootLines
          && lib.elem "if ! /usr/bin/xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1; then" rootLines
        )
        "${entry.name}: xcode-select, the license, and first launch must run by absolute path, only when pending, guarded by if !"
      )
      (check
        (
          brewLines == [
            ''PATH="${config.homebrew.prefix}/bin:$PATH" /usr/bin/sudo --preserve-env=PATH --user=${primaryUser} --set-home /usr/bin/env NONINTERACTIVE=1 ${brewExe} "$@"''
          ]
          && lib.elem "retiredBrew() {" rootLines
        )
        "${entry.name}: every brew call of the retired-cask step must run through /usr/bin/sudo --preserve-env=PATH --user=${primaryUser} with brew's prefix on PATH and the absolute brew path, since Homebrew refuses to run as root"
      )
      (check (retiredBrewCalls != [ ] && lib.all guarded retiredBrewCalls)
        "${entry.name}: every brew call of the retired-cask step must be guarded by if !, so a failed brew cannot abort activation"
      )
      (check
        (
          retiredStart != null && lib.sublist retiredStart (lib.length retiredBlock) rootLines == retiredBlock
        )
        "${entry.name}: the grok-bot cask must be uninstalled with --force when installed, a brew list failure other than not-installed must print brew's stderr, with one line per outcome and no exit on failure"
      )
      (check (
        !hasInfixInLines "zap" activationWithoutStorePaths
      ) "${entry.name}: no activation step may zap a cask, since --zap deletes the app's user data")
      (check
        (
          let
            flighty = lineIndex flightyInstall;
          in
          flighty != null && retiredStart != null && flighty < retiredStart
        )
        "${entry.name}: the retired-cask step must run after the App Store app steps and before Home Manager"
      )
      (check (!lib.elem "grok-bot" mapping.casks)
        "${entry.name}: modules/shared/darwin-apps.nix must map no grok-bot, or an apply would install the cask it removes"
      )
      (check (config.homebrew.masApps == { } && !(config.programs.mas.enable or false))
        "${entry.name}: homebrew.masApps must stay empty and programs.mas off; both can abort or end activation"
      )
      (lib.concatMapStrings (
        target:
        let
          name = baseNameOf target;
          files = koreanFilesAt target;
        in
        check
          (
            lib.length files == 1
            && lib.hasSuffix "-korean-skills-v1.0.0/${name}" (koreanSourceOf (lib.head files))
          )
          "${entry.name}: ${target} must be exactly one enabled home.file whose source is the ${name} directory of the korean-skills-v1.0.0 tree, got ${builtins.toJSON (map koreanSourceOf files)}"
      ) koreanTargets)
      (lib.concatMapStrings (
        target:
        let
          files = koreanFilesAt target;
        in
        check
          (
            lib.length files == 1
            && lib.hasSuffix "/home/h82/agents/skills/test-audit" (koreanSourceOf (lib.head files))
          )
          "${entry.name}: ${target} must be exactly one enabled home.file whose source is the in-tree test-audit skill directory, got ${builtins.toJSON (map koreanSourceOf files)}"
      ) testAuditTargets)
      (check
        (sort koreanUnderRoots == sort (koreanTargets ++ testAuditTargets ++ pinnedTargets ++ ceTargets))
        "${entry.name}: the targets under the skill roots must be exactly ${
          builtins.toJSON (koreanTargets ++ testAuditTargets ++ pinnedTargets ++ ceTargets)
        }, got ${builtins.toJSON (sort koreanUnderRoots)}"
      )
      (check (lib.length (koreanFilesAt ".omp/agent/skills") == 1)
        "${entry.name}: OMP must receive the contributed skill root; native OMP checks verify its contents"
      )
      (check (koreanElsewhere == [ ])
        "${entry.name}: Korean skills must not be installed under .agents/skills or .gemini/config/skills, got ${builtins.toJSON koreanElsewhere}"
      )
      (check (androidSdkFile != null && androidDataFiles == [ ])
        "${entry.name}: the Android SDK must be linked at ~/Library/Android/sdk, and no android-sdk data file declared"
      )
      (check
        (
          (sessionVariables.ANDROID_HOME or null) == androidSdkRoot
          && (sessionVariables.ANDROID_SDK_ROOT or null) == androidSdkRoot
          && lib.any (
            line:
            lib.hasInfix ":${androidSdkRoot}/emulator:" line
            || lib.hasInfix ":${androidSdkRoot}/emulator\"" line
          ) pathLines
        )
        "${entry.name}: ANDROID_HOME and ANDROID_SDK_ROOT must be ${androidSdkRoot}, and PATH must gain its emulator directory"
      )
      (check
        (
          lib.length androidImages == lib.length androidPin.platforms
          && lib.all (
            name: lib.hasInfix "-google_apis-arm64-v8a" name && !lib.hasInfix "x86_64" name
          ) androidImages
        )
        "${entry.name}: the Android SDK must build one arm64-v8a Google APIs image per pinned platform and no x86_64 image, got ${builtins.toJSON androidImages}"
      )
      (check (
        devicesStep != { } && lib.elem "linkGeneration" (devicesStep.after or [ ])
      ) "${entry.name}: activation must run the mobileDevices step after linkGeneration")
      (check devicesGuarded "${entry.name}: a dry run must not run the mobile-devices helper")
      (check devicesContained "${entry.name}: the mobile-devices helper call must be an elif ! condition whose branch only echoes, so a non-zero exit cannot abort activation")
      (check (platformCount "ios" == 0 && platformCount "android" == 1)
        "${entry.name}: my.mobileDevices must default to one android and no ios device, got ${builtins.toJSON devices}"
      )
      (check
        (
          lib.hasInfix "--xcrun /usr/bin/xcrun " devicesCall
          && lib.hasInfix "--sdk-root ${lib.escapeShellArg androidSdkRoot} " devicesCall
          && lib.all (device: lib.hasInfix (androidPin.deviceArg device) devicesCall) devices
        )
        "${entry.name}: the mobile-devices helper must get /usr/bin/xcrun, ${androidSdkRoot}, and every declared device"
      )
      (check (lib.hasInfix "--java-home ${lib.escapeShellArg (plain user.programs.java.package.home)} " devicesCall) "${entry.name}: the mobile-devices helper must get --java-home ${user.programs.java.package.home}, the JDK programs.java installs, because activation does not set JAVA_HOME")
      (check (lib.hasInfix "--android-api ${lib.escapeShellArg androidPin.newestArm64Api} " devicesCall) "${entry.name}: the mobile-devices helper must get --android-api ${androidPin.newestArm64Api}, the newest pinned API with an arm64-v8a image")
    ];

  # An empty model or version would render `--device ios:`, which the helper
  # rejects as a usage error before it reaches any device, so the option
  # types must refuse it at evaluation. The module is evaluated alone, with
  # option checking off so its other definitions stay unforced; the valid
  # list is the control that keeps the two rejections from passing vacuously.
  mobileDevicesWith =
    devices:
    let
      evaluated = lib.evalModules {
        modules = [
          ../home/h82/dev/mobile-devices.nix
          {
            _module.check = false;
            my.mobileDevices = devices;
          }
        ];
        specialArgs = { inherit pkgs; };
      };
    in
    (builtins.tryEval (builtins.deepSeq evaluated.config.my.mobileDevices true)).success;
  assertMobileDeviceTypes = lib.concatStrings [
    (check (mobileDevicesWith [
      {
        platform = "ios";
        model = "iPhone 18 Pro";
        version = "27.0";
      }
    ]) "my.mobileDevices rejects a valid device, so the empty-value checks below prove nothing")
    (check (
      !mobileDevicesWith [
        {
          platform = "ios";
          model = "";
        }
      ]
    ) "my.mobileDevices accepts an empty model, which renders --device ios: and fails the helper")
    (check (
      !mobileDevicesWith [
        {
          platform = "android";
          model = "pixel_9";
          version = "";
        }
      ]
    ) "my.mobileDevices accepts an empty version")
  ];

  # The TLS inspection CA trait: in production the bundle step runs before
  # the /etc step from this generation's CA bundle, the trust step after it,
  # and shells, nix-daemon, and a login agent for GUI apps all name the
  # bundle; bootstrap runs none of it and keeps nix-darwin's default.
  tlsBundle = "/etc/ssl/nix-config/ca-certificates.crt";
  tlsVariables = [
    "SSL_CERT_FILE"
    "NIX_SSL_CERT_FILE"
    "NODE_EXTRA_CA_CERTS"
    "REQUESTS_CA_BUNDLE"
    "CURL_CA_BUNDLE"
    "GIT_SSL_CAINFO"
  ];
  assertTlsInspectionCa =
    entry:
    let
      config = entry.host.config;
      production = !entry.bootstrap;
      variables = config.environment.variables;
      daemonCaFile =
        config.launchd.daemons.nix-daemon.serviceConfig.EnvironmentVariables.NIX_SSL_CERT_FILE or null;
      agent = config.launchd.user.agents.tls-inspection-ca-environment or null;
      agentScript = plain (lib.concatStringsSep " " (agent.serviceConfig.ProgramArguments or [ ]));
      script = plain config.system.activationScripts.script.text;
      beforeEtc = lib.head (lib.splitString "setting up /etc..." script);
      afterEtc = lib.concatStrings (lib.tail (lib.splitString "setting up /etc..." script));
      base = plain config.environment.etc."ssl/certs/ca-certificates.crt".source;
      bundleCall = "/bin/tls-inspection-ca bundle";
      trustCall = "/bin/tls-inspection-ca trust --certificate /etc/ssl/nix-config/tls-inspection-ca.pem";
      bundleArguments = [
        "--certificate-file ${lib.escapeShellArg (plain "${config.my.tlsInspectionCa.certificateFile}")}"
        "--identity ${lib.escapeShellArg "${config.my.user.home}/.config/nix-config/age/key.txt"}"
        "--identity-owner ${lib.escapeShellArg config.my.user.name}"
        "--base ${base}"
        "--out-dir /etc/ssl/nix-config"
        "--daemon org.nixos.nix-daemon"
      ];
      # The apply runs under set -e, so only a guarded call keeps a failing
      # trust check from aborting it.
      guardedTrust = lib.any (
        line: lib.hasPrefix "if ! " line && lib.hasSuffix "${trustCall}; then" line
      ) (map lib.trim (lib.splitString "\n" afterEtc));
      unset = lib.filter (name: name != "NIX_SSL_CERT_FILE") tlsVariables;
      withoutFile = entry.host.extendModules {
        modules = [ { my.tlsInspectionCa.certificateFile = lib.mkForce null; } ];
      };
      failing = map (a: a.message) (lib.filter (a: !a.assertion) withoutFile.config.assertions);
    in
    lib.concatStrings [
      (check (config.my.tlsInspectionCa.enable) "${entry.name}: the fixture must enable my.tlsInspectionCa, or the checks below prove nothing")
      (check (
        !entry.host.options.my.tlsInspectionCa.enable.default
      ) "${entry.name}: my.tlsInspectionCa.enable must default to false")
      (check
        (
          if production then
            lib.all (name: variables.${name} or null == tlsBundle) tlsVariables
          else
            variables.NIX_SSL_CERT_FILE or null == "/etc/ssl/certs/ca-certificates.crt"
            && lib.all (name: !variables ? ${name}) unset
        )
        "${entry.name}: shells must name the TLS inspection CA bundle in production and nix-darwin's default bundle in bootstrap"
      )
      (check (daemonCaFile == (if production then tlsBundle else "/etc/ssl/certs/ca-certificates.crt"))
        "${entry.name}: nix-daemon must read the TLS inspection CA bundle in production and the default bundle in bootstrap"
      )
      (check
        (
          if production then
            agent != null
            && agent.serviceConfig.RunAtLoad or false
            && lib.all (
              name: lib.hasInfix "/bin/launchctl setenv ${name} ${tlsBundle}" agentScript
            ) tlsVariables
          else
            agent == null
        )
        "${entry.name}: a login agent must set every CA variable to the bundle for GUI apps in production, and none may exist in bootstrap"
      )
      (check
        (
          if production then
            lib.hasInfix bundleCall beforeEtc
            && lib.all (argument: lib.hasInfix argument beforeEtc) bundleArguments
            && !hasInfixInLines bundleCall afterEtc
            && guardedTrust
            && !lib.hasInfix trustCall beforeEtc
          else
            !hasInfixInLines "tls-inspection-ca" script
        )
        "${entry.name}: the bundle step must run before /etc with this generation's CA bundle, the CA file, the host identity and its owner, into /etc/ssl/nix-config, and the trust step after it inside an if ! guard, in production only"
      )
      (check (
        !production || lib.any (lib.hasInfix "my.tlsInspectionCa.enable needs secrets/hosts/") failing
      ) "${entry.name}: a production output with the trait and no CA file must fail an assertion")
    ];

  # The network recovery trait: in production a root daemon runs the packaged
  # script every 5 seconds, newsyslog rotates its log, and Claude Code sessions
  # get a 60-second stream idle timeout; bootstrap carries none of it.
  assertNetworkRecovery =
    entry:
    let
      config = entry.host.config;
      production = !entry.bootstrap;
      daemon = config.launchd.daemons.network-recovery or null;
      arguments = daemon.serviceConfig.ProgramArguments or [ ];
      rotation = config.environment.etc."newsyslog.d/network-recovery.conf".text or null;
      idle =
        config.home-manager.users.${config.my.user.name}.home.sessionVariables.CLAUDE_BYTE_STREAM_IDLE_TIMEOUT_MS
          or null;
    in
    lib.concatStrings [
      (check config.my.networkRecovery.enable "${entry.name}: the fixture must enable my.networkRecovery, or the checks below prove nothing")
      (check (
        !entry.host.options.my.networkRecovery.enable.default
      ) "${entry.name}: my.networkRecovery.enable must default to false")
      (check
        (
          if production then
            daemon != null
            && lib.hasSuffix "/bin/network-recovery" (plain (lib.head (arguments ++ [ "" ])))
            &&
              lib.drop 1 arguments == [
                "--state-dir"
                "/var/db/network-recovery"
                "--tailscale"
                "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
              ]
            && (daemon.serviceConfig.StartInterval or null) == 5
            && (daemon.serviceConfig.RunAtLoad or false)
            && (daemon.serviceConfig.StandardOutPath or null) == "/var/log/network-recovery.log"
          else
            daemon == null
        )
        "${entry.name}: a root daemon must run the network recovery script every 5 seconds in production, and none may exist in bootstrap"
      )
      (check (
        if production then
          rotation != null && lib.hasInfix "/var/log/network-recovery.log" rotation
        else
          rotation == null
      ) "${entry.name}: newsyslog must rotate the network recovery log in production only")
      (check (idle == (if production then "60000" else null))
        "${entry.name}: Claude Code sessions must get CLAUDE_BYTE_STREAM_IDLE_TIMEOUT_MS=60000 in production and nothing in bootstrap"
      )
    ];

  # The Dock pins the shared apps in order with the host's own apps between
  # ChatGPT and Discord, T3 Code only with its trait, Downloads as the one
  # folder, and sets only show-recents and tilesize among the other keys.
  assertDock =
    entry:
    let
      config = entry.host.config;
      home = config.my.user.home;
      hostApps = config.my.dock.hostApps or [ ];
      expected =
        t3:
        [
          "/Applications/Google Chrome.app"
          "/System/Applications/Mail.app"
          "/System/Applications/Messages.app"
          "/System/Applications/Phone.app"
          "/System/Applications/FaceTime.app"
          "/System/Applications/iPhone Mirroring.app"
          "/System/Applications/Calendar.app"
          "/System/Applications/Reminders.app"
          "/System/Applications/Notes.app"
          "/System/Applications/Photos.app"
          "/Applications/Ghostty.app"
        ]
        ++ lib.optional t3 "${home}/Applications/Home Manager Apps/T3 Code (Nightly).app"
        ++ [
          "${home}/Applications/Home Manager Apps/VSCodium.app"
          "/Applications/Xcode.app"
          "/Applications/Claude.app"
          "/Applications/ChatGPT.app"
        ]
        ++ hostApps
        ++ [
          "/Applications/Discord.app"
          "/Applications/1Password.app"
          "/System/Applications/System Settings.app"
        ];
      appsOf =
        c:
        map (tile: tile.tile-data.file-data._CFURLString or null) (
          lib.defaultTo [ ] c.system.defaults.dock.persistent-apps
        );
      withoutT3 =
        (entry.host.extendModules {
          modules = [ { my.t3.desktop.enable = lib.mkForce false; } ];
        }).config;
      dock = config.system.defaults.dock;
      unmanaged = [
        "autohide"
        "orientation"
        "magnification"
        "mineffect"
        "minimize-to-application"
        "largesize"
      ];
    in
    lib.concatStrings [
      (check (config.my.t3.desktop.enable && hostApps != [ ])
        "${entry.name}: the fixture must enable my.t3.desktop and set my.dock.hostApps, or the order checks prove nothing"
      )
      (check (
        appsOf config == expected true
      ) "${entry.name}: the Dock's pinned apps differ from the declared order")
      (check (
        appsOf withoutT3 == expected false
      ) "${entry.name}: without my.t3.desktop the Dock must pin no T3 Code and keep the rest in order")
      (check
        (
          dock.persistent-others or null == [
            {
              tile-data = {
                file-data = {
                  _CFURLString = "file://${home}/Downloads";
                  _CFURLStringType = 15;
                };
                arrangement = 2;
                displayas = 0;
                showas = 1;
              };
              tile-type = "directory-tile";
            }
          ]
        )
        "${entry.name}: the Dock's right side must hold only Downloads, sorted by date added as a fanned stack"
      )
      (check (
        dock.show-recents or null == false && dock.tilesize or null == 32
      ) "${entry.name}: the Dock must hide recent apps and use tile size 32")
      (check (lib.all (key: dock.${key} or null == null)
        unmanaged
      ) "${entry.name}: the Dock must leave ${lib.concatStringsSep ", " unmanaged} to the user")
    ];

  # Device creation is macOS-only; the module must not reach other hosts.
  assertNoDevicesElsewhere = lib.concatStrings [
    (check (
      linuxFixtures != [ ]
    ) "no non-NixOS Linux fixture, so the mobileDevices absence check would pass vacuously")
    (lib.concatMapStrings (
      e:
      check (
        !e.host.home.config.home.activation ? mobileDevices
      ) "${e.name}: a non-NixOS Linux host runs the mobileDevices activation step"
    ) linuxFixtures)
  ];
in
pkgs.runCommand "darwin-config" { } ''
  fail=0
  ${lib.optionalString (darwinFixtures == [ ]) (
    fail "tests/fixtures/hosts holds no macOS fixture host"
  )}
  ${assertDiscovery}
  ${assertZapFilter}
  ${assertMapping}
  ${lib.concatMapStrings assertEntry darwinFixtures}
  ${lib.concatMapStrings assertTlsInspectionCa darwinFixtures}
  ${lib.concatMapStrings assertNetworkRecovery darwinFixtures}
  ${lib.concatMapStrings assertDock darwinFixtures}
  ${assertNoDevicesElsewhere}
  ${assertMobileDeviceTypes}
  [ "$fail" = 0 ] || exit 1
  touch "$out"
''
