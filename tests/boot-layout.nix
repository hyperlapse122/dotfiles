/*
  VM check interface:

    import ./tests/boot-layout.nix { inherit pkgs inputs; }

  disko's upstream test helper replaces the production by-id path with a
  disposable QEMU disk. It formats, mounts, unmounts, and boots the resulting
  installation; no host disk is touched.

  The VM runs once, on the first host directory under hosts/. Every host's
  layout differs from it only in the disk device path and sizes, and a second
  VM run would double a slow test. Instead, the boot-layout-invariants check
  (tests/boot-layout-invariants.nix) checks every host's hosts/<host>/disko.nix
  against the invariants in tests/lib/disko-invariants.nix, which
  modules/nixos/system/boot.nix and this VM script rely on. This test still
  refuses to evaluate on a broken layout, listing every broken invariant in
  one evaluation error.
*/
{ pkgs, inputs }:
let
  lib = pkgs.lib;
  evalConfig = import "${inputs.nixpkgs}/nixos/lib/eval-config.nix";
  # disko's makeDiskoTest still branches on config.boot.initrd.systemd.enable
  # inside its installed-system module after nixpkgs removed scripted initrd
  # with mkRemovedOptionModule (nix-community/disko#1304, #1305). Supply true
  # to that module so disko selects boot.initrd.secrets without tripping the
  # removed-option throw, while extraSystemConfig still sees the real assertion.
  withSystemdInitrd =
    module:
    if lib.isFunction module then
      lib.mirrorFunctionArgs module (
        args:
        module (
          args
          // {
            config = args.config // {
              boot = args.config.boot // {
                initrd = args.config.boot.initrd // {
                  systemd = args.config.boot.initrd.systemd // {
                    enable = true;
                  };
                };
              };
            };
          }
        )
      )
    else
      module;
  diskoLib = import "${inputs.disko}/lib" {
    inherit lib;
    makeTest = import "${inputs.nixpkgs}/nixos/tests/make-test-python.nix";
    eval-config = args: evalConfig (args // { modules = map withSystemdInitrd args.modules; });
    qemu-common = import "${inputs.nixpkgs}/nixos/lib/qemu-common.nix";
  };
  bootModule = ../modules/nixos/system/boot.nix;

  invariants = import ./lib/disko-invariants.nix { inherit lib; };
  inherit (invariants) hostNames diskOf problems;

  firstDisk =
    if hostNames == [ ] then
      throw "boot-layout: no host directory under hosts/"
    else if problems != [ ] then
      throw "boot-layout: host disk layouts break the boot invariants:\n  ${lib.concatStringsSep "\n  " problems}"
    else
      diskOf (lib.head hostNames);

  testDisk = lib.recursiveUpdate firstDisk {
    disko.devices.disk.main.content.partitions.luks.content.passwordFile = "/tmp/secret.key";
    disko.devices.disk.main.content.partitions.luks.content.content.subvolumes."/swap".swap.swapfile.size =
      "100M";
  };
  testSystem = {
    imports = [
      bootModule
      inputs.lanzaboote.nixosModules.lanzaboote
    ];
    options.my.bootstrap = lib.mkOption {
      type = lib.types.bool;
      default = true;
    };
    config.my.bootstrap = true;
  };
in
diskoLib.testLib.makeDiskoTest {
  inherit pkgs;
  name = "boot-layout";
  disko-config = testDisk;
  extraSystemConfig = testSystem;
  enableOCR = true;
  bootCommands = ''
    machine.wait_for_text("[Pp]assphrase for")
    machine.send_chars("secretsecret\n")
  '';
  extraTestScript = ''
    machine.succeed("cryptsetup isLuks /dev/vda2")
    machine.succeed("cryptsetup luksDump /dev/vda2 | grep -q 'Version:.*2'")
    machine.succeed("btrfs subvolume list / | grep -qs 'path root$'")
    machine.succeed("btrfs subvolume list / | grep -qs 'path home$'")
    machine.succeed("btrfs subvolume list / | grep -qs 'path nix$'")
    machine.succeed("btrfs subvolume list / | grep -qs 'path log$'")
    machine.succeed("btrfs subvolume list / | grep -qs 'path swap$'")
    machine.succeed("test -e /swap/swapfile")
  '';
}
