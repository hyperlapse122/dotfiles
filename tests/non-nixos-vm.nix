/*
  Check interface:

    import ./tests/non-nixos-vm.nix { inherit pkgs inputs fixtures; }

  Boots an Ubuntu 24.04 cloud image through numtide/nix-vm-test and applies
  the x86_64 non-NixOS fixture host with the non-NixOS `nr`, as a user would
  on a real machine. The fixture's system and Home Manager outputs are built
  on the host and reach the guest through its shared store, so the guest
  never evaluates the flake.

  Guest setup plays the manual prerequisites the docs name: an account with a
  non-default uid, passwordless sudo, the managed zsh in /etc/shells,
  subordinate id ranges, the uidmap helpers, and a Nix daemon. Then:

  - bootstrap applies without an identity: pcscd's socket is active and open
    only to the account's group, the managed zsh exists, the host
    marker names the bootstrap variant, and system-manager's profile points
    at the active system layer;
  - production without an identity stops before anything is published, both
    in nr's preflight and in the Home Manager activation itself, and leaves
    the Home Manager generation where bootstrap put it;
  - an identity that is not a recipient stops production the same way, and
    no token reaches the output;
  - after the identity is installed with install-user-age-identity,
    production publishes gh and glab configuration and the SSH key, owned by
    the account and private, and ssh uses that key;
  - a second production apply, a bootstrap apply, and production again all
    succeed and leave the published files intact;
  - no apply changes the distribution's user database, subordinate id ranges,
    or login-shell list.
*/
{
  pkgs,
  inputs,
  fixtures,
}:
let
  inherit (pkgs) lib;

  vmTest = import "${inputs.nix-vm-test}/lib.nix" {
    inherit (inputs) nixpkgs;
    system = pkgs.stdenv.hostPlatform.system;
  };

  fixtureOf =
    bootstrap:
    lib.findFirst (
      entry:
      entry.bootstrap == bootstrap
      && entry.host.system == pkgs.stdenv.hostPlatform.system
      && entry.host.home.config.my.user.name != "h82"
    ) (throw "tests/non-nixos-vm.nix: no x86_64 fixture with a non-default account") fixtures;

  production = fixtureOf false;
  bootstrap = fixtureOf true;
  user = production.host.home.config.my.user.name;
  home = production.host.home.config.my.user.home;
  hostName = production.fixture;

  secrets = import ./lib/fake-secrets.nix { inherit pkgs; };
  nr = (import ../packages/nix-tools.nix { inherit pkgs; }).nrLinux;
  installer = (import ../packages/gpg-tools.nix { inherit pkgs; }).installUserAgeIdentity;

  systemOut = variant: variant.host.systemManager;
  homeOut = variant: variant.host.home.activationPackage;

  # A shell command run as the account, with the session a login would give.
  asUser =
    command:
    lib.escapeShellArgs [
      "runuser"
      "-u"
      user
      "--"
      "env"
      "HOME=${home}"
      "USER=${user}"
      "XDG_RUNTIME_DIR=/run/user/1001"
      "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1001/bus"
      "PATH=${nr}/bin:${pkgs.nix}/bin:/usr/sbin:/usr/bin:/sbin:/bin"
      "bash"
      "-c"
      command
    ];

  nrSwitch =
    variant:
    asUser "NR_SYSTEM_OUT=${systemOut variant} NR_HOME_OUT=${homeOut variant} nr switch --host ${hostName}${lib.optionalString variant.bootstrap " --bootstrap"}";

  published = [
    "${home}/.config/gh/hosts.yml"
    "${home}/.config/glab-cli/config.yml"
    "${home}/.ssh/id_ed25519_nix_config"
  ];

  distributionOwned = map (name: "/etc/${name}") (import ./lib/distribution-owned.nix);

  test = vmTest.ubuntu."24_04" {
    memorySize = 3072;
    extraPathsToRegister = [
      (systemOut production)
      (systemOut bootstrap)
      (homeOut production)
      (homeOut bootstrap)
      secrets
      nr
      installer
      pkgs.nix
      pkgs.shadow
    ];
    testScript = ''
      vm.wait_for_unit("multi-user.target")

      # --- the manual prerequisites -------------------------------------------
      vm.succeed("useradd --create-home --uid 1001 --shell /bin/bash ${user}")
      vm.succeed("grep -q '^${user}:' /etc/subuid || usermod --add-subuids 100000-165535 ${user}")
      vm.succeed("grep -q '^${user}:' /etc/subgid || usermod --add-subgids 100000-165535 ${user}")
      vm.succeed("echo '${user} ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/${user} && chmod 0440 /etc/sudoers.d/${user}")
      vm.succeed("echo ${home}/.nix-profile/bin/zsh >> /etc/shells")
      vm.succeed(
          "test -u /usr/bin/newuidmap || install -m 4755 ${pkgs.shadow}/bin/newuidmap /usr/bin/newuidmap; "
          "test -u /usr/bin/newgidmap || install -m 4755 ${pkgs.shadow}/bin/newgidmap /usr/bin/newgidmap"
      )
      vm.succeed("loginctl enable-linger ${user}")
      vm.wait_for_unit("user@1001.service")
      # A Nix daemon from the host store stands in for the Nix installation, so
      # the account can register its Home Manager profile.
      vm.succeed(
          "groupadd -r nixbld && for i in 1 2 3 4; do useradd -r -g nixbld -G nixbld -M -s /usr/sbin/nologin nixbld$i; done; "
          "mkdir -p /nix/var/nix/profiles/per-user /nix/var/nix/gcroots/per-user && "
          "systemd-run --unit nix-daemon ${pkgs.nix}/bin/nix-daemon"
      )
      vm.wait_for_unit("nix-daemon.service")
      owned_before = vm.succeed("sha256sum ${lib.escapeShellArgs distributionOwned}")

      def assert_distribution_untouched(step):
          after = vm.succeed("sha256sum ${lib.escapeShellArgs distributionOwned}")
          assert after == owned_before, f"{step} changed distribution-owned files:\n{owned_before}\n{after}"

      def assert_nothing_published(step):
          for path in ${builtins.toJSON published} + ["${home}/.local/state/cli-auth"]:
              status, _ = vm.execute(f"test -e {path}")
              assert status != 0, f"{step} published {path}"

      def assert_generation_unchanged(step):
          current = vm.succeed(${builtins.toJSON (asUser "readlink -f ${home}/.local/state/home-manager/gcroots/current-home")})
          assert current == generation, f"{step} switched the Home Manager generation to {current}"

      # --- bootstrap, before any identity exists -----------------------------
      vm.succeed(${builtins.toJSON (nrSwitch bootstrap)})
      vm.wait_for_unit("pcscd.socket")
      # Plain pcsclite has no polkit, so the socket is the access boundary.
      socket = vm.succeed("stat -c '%a %U %G' /run/pcscd/pcscd.comm").split()
      assert socket == ["660", "root", "${user}"], f"pcscd socket is {socket}"
      vm.succeed(${builtins.toJSON (asUser "test -x ${home}/.nix-profile/bin/zsh")})
      # The generation the refused production applies below must leave in place.
      generation = vm.succeed(${builtins.toJSON (asUser "readlink -f ${home}/.local/state/home-manager/gcroots/current-home")})
      vm.succeed("grep -qx 'variant=bootstrap' /etc/nix-config-host")
      vm.succeed("grep -qx 'host=${hostName}' /etc/nix-config-host")
      vm.succeed(
          "test \"$(readlink -f /nix/var/nix/profiles/system-manager-profiles/system-manager)\" = ${systemOut bootstrap}"
      )
      assert_nothing_published("bootstrap")
      assert_distribution_untouched("bootstrap")

      # --- production without an identity -----------------------------------
      out = vm.fail(${builtins.toJSON "${nrSwitch production} 2>&1"})
      assert "recover-age-identity --user --host ${hostName}" in out, out
      # The activation refuses on its own too, not only nr's preflight.
      out = vm.fail(${builtins.toJSON (asUser "${homeOut production}/activate 2>&1")})
      assert "no age identity" in out, out
      assert_nothing_published("production without an identity")
      assert_generation_unchanged("production without an identity")

      # --- an identity that is not a recipient ----------------------------------
      vm.succeed(${builtins.toJSON (asUser "install -d -m 700 ${home}/.config/nix-config/age && install -m 600 ${secrets}/other-key.txt ${home}/.config/nix-config/age/key.txt")})
      out = vm.fail(${builtins.toJSON "${nrSwitch production} 2>&1"})
      assert "not a recipient" in out, out
      assert "FAKE-CANARY" not in out, "a token reached the output"
      assert_nothing_published("production with a foreign identity")
      assert_generation_unchanged("production with a foreign identity")

      # --- the right identity, installed the documented way -------------------
      vm.succeed(${builtins.toJSON (asUser "rm ${home}/.config/nix-config/age/key.txt && ${installer}/bin/install-user-age-identity --recipient $(cat ${secrets}/recipient.txt) < ${secrets}/key.txt")})

      snapshots = []
      for step in ["production", "second production", "bootstrap again", "production again"]:
          variant = ${builtins.toJSON (nrSwitch bootstrap)} if step == "bootstrap again" else ${builtins.toJSON (nrSwitch production)}
          out = vm.succeed(variant + " 2>&1")
          assert "FAKE-CANARY" not in out, f"{step}: a token reached the output"
          for path in ${builtins.toJSON published}:
              mode, owner = vm.succeed(f"stat -c '%a %U' {path}").split()
              assert mode == "600" and owner == "${user}", f"{step}: {path} is {mode} {owner}"
          snapshots.append(vm.succeed("sha256sum ${lib.escapeShellArgs published}"))
          assert_distribution_untouched(step)

      assert len(set(snapshots)) == 1, "a later apply changed the published files"
      vm.succeed(${builtins.toJSON (asUser "grep -q FAKE-CANARY-github ${home}/.config/gh/hosts.yml")})
      vm.succeed(${builtins.toJSON (asUser "ssh -G example.invalid | grep -qE '^identityfile (~|${home})/.ssh/id_ed25519_nix_config$'")})
      vm.succeed(${builtins.toJSON ("test \"$(ssh-keygen -y -f ${home}/.ssh/id_ed25519_nix_config | cut -d' ' -f1,2)\" = \"$(cut -d' ' -f1,2 ${secrets}/ssh.pub)\"")})
      journal = vm.succeed("journalctl --no-pager")
      assert "FAKE-CANARY" not in journal, "a token reached the journal"
    '';
  };
in
test.sandboxed
