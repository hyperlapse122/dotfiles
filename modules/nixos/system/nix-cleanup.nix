{
  config,
  lib,
  ...
}:
let
  # The bootstrap output installs the machine and is thrown away afterwards, so
  # it accumulates no generations worth collecting.  Keeping nh out of it also
  # keeps the installer closure from carrying a tool nobody runs there.
  bootstrap = config.my.bootstrap or false;
in
{
  programs.nh = lib.mkIf (!bootstrap) {
    enable = true;
    clean = {
      enable = true;
      dates = "weekly";

      # --keep must stay at or above the boot loader's configurationLimit in
      # modules/nixos/system/boot.nix.  The boot menu is rewritten only by a rebuild
      # while this collection runs on a timer, so a smaller floor would leave
      # menu entries pointing at generations that are already gone -- the
      # rollback path docs/recovery.md sends you to when the system will not
      # boot.  --keep counts the newest profile generations regardless of age;
      # --keep-since is a separate window, and a generation survives if either
      # one covers it.
      #
      # Non-profile gcroots (build result symlinks, dev shells) are not covered
      # by the --keep count floor; they are governed by --keep-since 14d alone.
      # --keep-one preserves at least one gcroot per direnv project so inactive
      # development environments are not pruned entirely.
      extraArgs = "--keep 10 --keep-since 14d --keep-one";
    };
  };
}
