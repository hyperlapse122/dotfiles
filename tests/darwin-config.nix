# Evaluate Darwin declarations on Linux; run provisioning against recording stubs.
{
  pkgs,
  self,
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

  invalidHosts = import ../lib/hosts.nix { inherit lib; } ./fixtures/invalid-kind;

  assertDiscovery = lib.concatStrings [
    (check (
      !(builtins.tryEval (builtins.length invalidHosts.darwin)).success
    ) "unsupported host kind was accepted")
    (check (hosts.darwin != [ ]) "tests/fixtures/hosts holds no macOS fixture host")
    (lib.concatMapStrings (
      fixture:
      check (
        kindOf fixture == "darwin"
      ) "${fixture}: listed as macOS, but host.nix names kind ${toString (kindOf fixture)}"
    ) hosts.darwin)
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
  onePassword = lib.optional (lib.any (
    c: c.config.programs._1password-gui.enable
  ) nixosConfigs) "1password";
  darwinNames = lib.unique (
    lib.concatMap (
      e: namesOf e.host.config.home-manager.users.${e.host.config.my.user.name}.home.packages
    ) darwinFixtures
  );
  required = lib.subtractLists darwinNames nixosNames ++ onePassword;

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
      masWrappers = [ "appStoreMas" ];
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
      kakaoInstall = "if ! appStoreMas install ${kakaoTalkId} && ! appStoreMas get ${kakaoTalkId}; then";
      flightyInstall = "if ! appStoreMas install ${flightyId} && ! appStoreMas get ${flightyId}; then";
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
      (check (
        masLines != [ ]
        && lib.all (
          line: lib.hasInfix (masAsUser "$appStore") line && lib.hasSuffix " \"$@\"" line
        ) masLines
        && lib.all guarded masWrapperCalls
      ) "${entry.name}: App Store calls must remain guarded in the primary user's session")
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
      (check (
        !(user.services.podman.enable or false)
        && !(agents.minikube.enable or false)
        && !(agents.podman-machine-podman-machine-default.enable or false)
        && !(agents.container-environment.enable or false)
        && !(sessionVariables ? DOCKER_HOST)
        && !(sessionVariables ? REGISTRY_AUTH_FILE)
        && !(activation ? containersAuth)
      ) "${entry.name}: Podman automation reached Darwin")
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
      (check (
        !lib.elem "docker-podman-compat" pnames && lib.elem "kubectl" pnames && lib.elem "minikube" pnames
      ) "${entry.name}: keep Kubernetes clients without Docker compatibility")
      (check (
        lib.elem "nr-darwin" pnames && !lib.elem "nr" pnames && !lib.elem "nr-linux" pnames
      ) "${entry.name}: nr must be nr-darwin")
      (check (
        pinentry.pname == "dotfiles-pinentry"
      ) "${entry.name}: native pinentry must delegate to pinentry_mac")
      (check ((user.targets.darwin.defaults."org.gpgtools.pinentry-mac".UseKeychain or null) == false)
        "${entry.name}: pinentry_mac's UseKeychain default must be false, or Save in Keychain starts ticked"
      )
      (check (lib.hasInfix "Library/Application Support/VSCodium/User/settings.json" vscodiumData) "${entry.name}: the VSCodium settings merge must target Library/Application Support/VSCodium/User")
      (check (
        user.programs.ghostty.package == null
      ) "${entry.name}: Ghostty must come from the cask, not nixpkgs")
      (check (
        user.programs.ghostty.settings.font-family or [ ] == [
          "Jetendard"
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
      (check (lib.all (name: lib.elem name (map (brew: brew.name) config.homebrew.brews)) [
        "aria2"
        "container"
      ]) "${entry.name}: missing overlay formula")
      (check (
        (lib.any (lib.hasInfix "/bin/macos-xcode") rootLines) == production
        && !lib.hasInfix "xcodeMas" postActivation
        && (lib.any (lib.hasInfix "/apple-account.yaml") rootLines) == production
      ) "${entry.name}: Xcode must use runtime SOPS only in production")
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
      (check (sort koreanUnderRoots == sort (koreanTargets ++ testAuditTargets ++ pinnedTargets))
        "${entry.name}: the targets under the skill roots must be exactly ${
          builtins.toJSON (koreanTargets ++ testAuditTargets ++ pinnedTargets)
        }, got ${builtins.toJSON (sort koreanUnderRoots)}"
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

  # The wired network trait: in production, activation runs the packaged
  # reconciler once, after /etc and the Xcode step, with the declaration file,
  # the host identity, and its owner; bootstrap never runs it, and a
  # production output with the trait and no file fails an assertion.
  assertWiredNetwork =
    entry:
    let
      config = entry.host.config;
      production = !entry.bootstrap;
      script = plain config.system.activationScripts.script.text;
      beforeEtc = lib.head (lib.splitString "setting up /etc..." script);
      afterEtc = lib.concatStrings (lib.tail (lib.splitString "setting up /etc..." script));
      lines = map lib.trim (lib.splitString "\n" afterEtc);
      indices = lib.range 0 (lib.length lines - 1);
      # The call line must start with the store path, so an echo, a comment,
      # or any other prefix that keeps the text but skips the run fails.
      calls = lib.filter (
        i:
        let
          line = lib.elemAt lines i;
        in
        lib.hasPrefix "/nix/store/" line && lib.hasSuffix "/bin/macos-wired-network \\" line
      ) indices;
      xcodeCalls = lib.filter (i: lib.hasInfix "/bin/macos-xcode" (lib.elemAt lines i)) indices;
      arguments = if lib.length calls == 1 then lib.sublist (lib.head calls + 1) 3 lines else [ ];
      expected = [
        "--file ${lib.escapeShellArg (plain "${config.my.wiredNetwork.file}")} \\"
        "--identity ${lib.escapeShellArg "${config.my.user.home}/.config/nix-config/age/key.txt"} \\"
        "--owner ${lib.escapeShellArg config.my.user.name}"
      ];
      withoutFile = entry.host.extendModules {
        modules = [ { my.wiredNetwork.file = lib.mkForce null; } ];
      };
      failing = map (a: a.message) (lib.filter (a: !a.assertion) withoutFile.config.assertions);
    in
    lib.concatStrings [
      (check config.my.wiredNetwork.enable "${entry.name}: the fixture must enable my.wiredNetwork, or the checks below prove nothing")
      (check (
        !entry.host.options.my.wiredNetwork.enable.default
      ) "${entry.name}: my.wiredNetwork.enable must default to false")
      (check
        (
          if production then
            lib.length calls == 1
            && arguments == expected
            && !hasInfixInLines "macos-wired-network" beforeEtc
            && xcodeCalls != [ ]
            && lib.all (i: i < lib.head calls) xcodeCalls
          else
            !hasInfixInLines "macos-wired-network" script
        )
        "${entry.name}: activation must run the wired network reconciler once after /etc and after the Xcode step, with the declaration file, the host identity, and its owner in production, and never in bootstrap"
      )
      (check (!production || lib.any (lib.hasInfix "my.wiredNetwork.enable needs secrets/hosts/") failing)
        "${entry.name}: a production output with the trait and no wired network file must fail an assertion"
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
          "/System/Applications/App Store.app"
          "/System/Applications/Mail.app"
          "/System/Applications/Calendar.app"
          "/System/Applications/Reminders.app"
          "/System/Applications/Notes.app"
          "/System/Applications/Messages.app"
          "/System/Applications/FaceTime.app"
          "/System/Applications/Phone.app"
          "/System/Applications/Photos.app"
          "/System/Applications/Music.app"
          "/System/Applications/iPhone Mirroring.app"
        ]
        ++ hostApps
        ++ [ "/Applications/Ghostty.app" ]
        ++ lib.optional t3 "${home}/Applications/Home Manager Apps/${import ../packages/t3code-app-bundle.nix}"
        ++ [
          "/Applications/ChatGPT.app"
          "/Applications/Claude.app"
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

  assertNoDevicesElsewhere = lib.concatStrings [
    (check (
      nixosConfigs != [ ]
    ) "no NixOS host, so the mobileDevices absence check would pass vacuously")
    (lib.concatMapStrings (
      host:
      check (
        !host.config.home-manager.users.h82.home.activation ? mobileDevices
      ) "a NixOS host runs the macOS mobileDevices activation step"
    ) nixosConfigs)
  ];
in
pkgs.runCommand "darwin-config"
  {
    nativeBuildInputs = [
      pkgs.python3
      pkgs.bash
      pkgs.jq
    ];
  }
  ''
    python3 ${./test_darwin_provisioning.py} ${../scripts/macos-xcode.py} ${../scripts/macos-container.sh} ${../scripts/macos-container-state.sh} ${
      pkgs.writeText "darwin-activation-provisioning.json" (
        builtins.toJSON (
          map (entry: {
            inherit (entry) bootstrap;
            host = entry.host.config.my.hostName;
            home = entry.host.config.my.user.home;
            owner = entry.host.config.my.user.name;
            text = plain entry.host.config.system.activationScripts.postActivation.text;
          }) darwinFixtures
        )
      )
    }
    fail=0
    ${lib.optionalString (darwinFixtures == [ ]) (
      fail "tests/fixtures/hosts holds no macOS fixture host"
    )}
    ${assertDiscovery}
    ${assertNoDevicesElsewhere}
    ${assertZapFilter}
    ${assertMapping}
    ${lib.concatMapStrings assertEntry darwinFixtures}
    ${lib.concatMapStrings assertTlsInspectionCa darwinFixtures}
    ${lib.concatMapStrings assertNetworkRecovery darwinFixtures}
    ${lib.concatMapStrings assertWiredNetwork darwinFixtures}
    ${lib.concatMapStrings assertDock darwinFixtures}
    ${assertMobileDeviceTypes}
    [ "$fail" = 0 ] || exit 1
    touch "$out"
  ''
