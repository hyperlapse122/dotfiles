{
  pkgs,
  inputs,
  vmChecks,
}:
let
  inherit (inputs) self;
  system = pkgs.stdenv.hostPlatform.system;
  agentTools = import ../packages/agent-tools.nix { inherit pkgs; };
  configurations = import ./lib/configurations.nix { inherit pkgs self; };
  darwinFixtures = import ./lib/darwin-fixtures.nix { inherit inputs; };
  sharedChecks = import ./shared-checks.nix { inherit pkgs inputs; };
  # Register checks that pull a NixOS system or Home Manager generation into the hosts shard.
  hostClosureChecks = {
    inherit (sharedChecks) decide;
    acpx-delivery = import ./acpx-delivery.nix { inherit pkgs self; };
    agent-browser-deps = import ./agent-browser-deps.nix { inherit pkgs self; };
    agent-instructions = import ./agent-instructions.nix { inherit pkgs self; };
    agent-unmanaged = import ./agent-unmanaged.nix {
      inherit pkgs;
      systems = map (
        entry: pkgs.writeText "system-activation" entry.config.system.activationScripts.script
      ) configurations.entries;
      entries = configurations.userEntries;
    };
    android-sdk = import ./android-sdk.nix { inherit pkgs self; };
    baloo-extractor = import ./baloo-extractor.nix { inherit pkgs self; };
    boot-splash = import ./boot-splash.nix { inherit pkgs self; };
    cargo-settings = import ./cargo-settings.nix { inherit pkgs self; };
    desktop-autostart = import ./desktop-autostart.nix { inherit pkgs self; };
    desktop-ssh = import ./desktop-ssh.nix { inherit pkgs self; };
    elf-load-segments = import ./elf-load-segments.nix { inherit pkgs self; };
    emoji-font = import ./emoji-font.nix { inherit pkgs self; };
    flutter = import ./flutter.nix { inherit pkgs self; };
    ghostty-font = import ./ghostty-font.nix { inherit pkgs self; };
    ghostty-service = import ./ghostty-service.nix { inherit pkgs self; };
    ghq = import ./ghq.nix { inherit pkgs self; };
    git-lfs = import ./git-lfs.nix { inherit pkgs self; };
    git-trim = import ./git-trim.nix { inherit pkgs self; };
    gpg-agent-no-cache = import ./gpg-agent-no-cache.nix { inherit pkgs self; };
    host-options = import ./host-options.nix { inherit pkgs self; };
    iphone-restore = import ./iphone-restore.nix { inherit pkgs self; };
    kde-theme = import ./kde-theme.nix { inherit pkgs self; };
    kernel-sysctl = import ./kernel-sysctl.nix { inherit pkgs self; };
    korean-skills = import ./korean-skills.nix { inherit pkgs self; };
    kubernetes-tools = import ./kubernetes-tools.nix { inherit pkgs self; };
    minikube-autostart = import ./minikube-autostart.nix { inherit pkgs self; };
    mise-settings = import ./mise-settings.nix { inherit pkgs self; };
    nix-cleanup = import ./nix-cleanup.nix { inherit pkgs self; };
    nixos-wired-network-config = import ./nixos-wired-network-config.nix { inherit pkgs self; };
    nvidia-closure = import ./nvidia-closure.nix { inherit pkgs self; };
    official-skills = import ./official-skills.nix { inherit pkgs self; };
    pi = import ./pi.nix { inherit pkgs self; };
    pinned-skills = import ./pinned-skills.nix { inherit pkgs self; };
    podman-containers = import ./podman-containers.nix { inherit pkgs self; };
    printing = import ./printing.nix { inherit pkgs self; };
    proton-vpn = import ./proton-vpn.nix { inherit pkgs self; };
    python3-runtime = import ./python3-runtime.nix { inherit pkgs self; };
    serve-html-profiles = import ./serve-html-profiles.nix { inherit pkgs self; };
    session-variables = import ./session-variables.nix { inherit pkgs self; };
    shell-utilities = import ./shell-utilities.nix { inherit pkgs self; };
    ssh-server = import ./ssh-server.nix { inherit pkgs self; };
    t3code-traits = import ./t3code-traits.nix { inherit pkgs self; };
    test-audit-skill = import ./test-audit-skill.nix { inherit pkgs self; };
    tokscale = import ./tokscale.nix { inherit pkgs self; };
    udev-device-access = import ./udev-device-access.nix { inherit pkgs self; };
    user-avatar = import ./user-avatar.nix { inherit pkgs self; };
    vscodium = import ./vscodium.nix { inherit pkgs self; };
    winbox = import ./winbox.nix { inherit pkgs self; };
    yubikey-fido = import ./yubikey-fido.nix { inherit pkgs self; };
    zsh-prezto = import ./zsh-prezto.nix {
      inherit pkgs;
      entries = configurations.userEntries;
    };
  };
  checkShards = import ./check-shards.nix {
    inherit pkgs checks;
    hostClosureChecks = builtins.attrNames hostClosureChecks;
  };
  checks =
    sharedChecks
    // import ./python-script-checks.nix { inherit pkgs; }
    // import ./workflow-checks.nix { inherit pkgs self agentTools; }
    // import ./shell-script-checks.nix {
      inherit
        pkgs
        self
        system
        agentTools
        ;
    }
    // import ./non-nixos-scripts.nix { inherit pkgs; }
    // hostClosureChecks
    // {
      agent-api-key-secrets = import ./agent-api-key-secrets.nix { inherit pkgs self; };
      agent-plugins = import ./agent-plugins.nix { inherit pkgs self; };
      agent-settings = import ./agent-settings.nix { inherit pkgs agentTools; };
      boot-layout-invariants = import ./boot-layout-invariants.nix { inherit pkgs self; };
      bootstrap-recipients = import ./bootstrap-recipients.nix { inherit pkgs; };
      bootstrap-secrets = import ./bootstrap-secrets.nix { inherit pkgs self; };
      chatgpt = import ./chatgpt.nix { inherit pkgs self; };
      check-shards-guard = import ./check-shards-guard.nix {
        inherit pkgs;
        # attrNames forces no check, so the guard never evaluates itself.
        checkNames = builtins.attrNames checks;
        inherit (checkShards) members;
      };
      claude = import ./claude.nix { inherit pkgs self; };
      claude-code = import ./claude-code.nix { inherit pkgs self; };
      claude-code-agents-catalog = import ./claude-code-agents-catalog.nix { inherit pkgs agentTools; };
      claude-desktop = import ./claude-desktop.nix { inherit pkgs self; };
      codex = import ./codex.nix { inherit pkgs self; };
      codex-settings = import ./codex-settings.nix { inherit pkgs self; };
      desktop-packages = import ./desktop-packages.nix { inherit pkgs self; };
      firefox-developer-edition = import ./firefox-developer-edition.nix { inherit pkgs self; };
      git-cli-repo-flags = import ./git-cli-repo-flags.nix { inherit pkgs self; };
      grok-absent = import ./grok-absent.nix { inherit pkgs self darwinFixtures; };
      harness-agents-catalog = import ./harness-agents-catalog.nix { inherit pkgs agentTools; };
      host-name-guard = import ./host-name-guard.nix { inherit pkgs self; };
      host-secrets = import ./host-secrets.nix { inherit pkgs; };
      kde-power = import ./kde-power.nix { inherit pkgs self; };
      macos-wired-network = import ./macos-wired-network.nix { inherit pkgs; };
      network-recovery = import ./network-recovery.nix { inherit pkgs; };
      nixos-wired-network = import ./nixos-wired-network.nix { inherit pkgs; };
      nr = import ./nr.nix { inherit pkgs self; };
      ollama-user-service = import ./ollama-user-service.nix { inherit pkgs self; };
      opencode = import ./opencode.nix { inherit pkgs self; };
      plasma-taskbar = import ./plasma-taskbar.nix { inherit pkgs self; };
      sops-recipients = import ./sops-recipients.nix { inherit pkgs self; };
      synthetic-models = import ./synthetic-models.nix { inherit pkgs; };
      t3code = import ./t3code.nix { inherit pkgs self system; };
      tailscale-single-router = import ./tailscale-single-router.nix { inherit pkgs configurations; };
      text-template = import ./text-template.nix { inherit pkgs; };
      tls-inspection-ca = import ./tls-inspection-ca.nix { inherit pkgs; };
      user-identity-secrets = import ./user-identity-secrets.nix { inherit pkgs self; };
      vm-checks-guard = import ./vm-checks-guard.nix {
        inherit pkgs vmChecks;
        # removeAttrs does not force the removed value, so the guard never
        # evaluates itself.
        checks = builtins.removeAttrs checks [ "vm-checks-guard" ];
      };
      wifi-assertions = import ./wifi-assertions.nix { inherit pkgs inputs; };
      wireplumber-bluetooth = import ./wireplumber-bluetooth.nix { inherit pkgs self; };
    };
in
{
  inherit checks;
  inherit (checkShards) shards;
}
