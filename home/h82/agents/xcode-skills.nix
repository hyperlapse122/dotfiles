{
  config,
  lib,
  pkgs,
  ...
}:
let
  helper = lib.getExe (import ../../../packages/xcode-skills.nix { inherit pkgs; });
  state = "${config.home.homeDirectory}/${config.my.xcodeSkillsStateDir}";
  roots = lib.concatMapStringsSep " " (
    root: "--root ${lib.escapeShellArg "${config.home.homeDirectory}/${root}"}"
  ) config.my.agentSkillRoots;
  names = lib.concatMapStringsSep " " (name: "--name ${lib.escapeShellArg name}") (
    lib.attrNames config.my.agentSkills
  );
in
{
  options.my.xcodeSkillsStateDir = lib.mkOption {
    type = lib.types.str;
    internal = true;
    readOnly = true;
    default = ".local/state/nix-config/xcode-skills";
    description = ''
      Directory, relative to the home directory, that holds the one copy of
      the skills the selected Xcode exports. Every skill root links into it.
    '';
  };

  # Xcode is installed outside Nix and its skills carry no license, so they
  # are exported on the machine at activation and never enter the store.
  # Home Manager on nix-darwin activates on every apply, after the system
  # step that installs Xcode, so an Xcode upgrade with no Nix change still
  # refreshes the skills. The helper reports its own failures and exits 0.
  #
  # The release entry runs first: a declared skill that takes the name of an
  # installed Xcode skill would otherwise meet a foreign symlink at its link
  # target and checkLinkTargets would stop activation.

  config = lib.mkIf (config.my.kind == "darwin" && !config.my.bootstrap) {
    home.activation.xcodeSkillsRelease = lib.hm.dag.entryBefore [ "checkLinkTargets" ] ''
      if [[ -v DRY_RUN ]]; then
        echo "Releasing Xcode skills claimed by declared skills"
      elif ! ${helper} --release --state ${lib.escapeShellArg state} ${roots} ${names}; then
        echo "xcodeSkillsRelease: the helper failed" >&2
      fi
    '';
    home.activation.xcodeSkillsInstall = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      if [[ -v DRY_RUN ]]; then
        echo "Installing Xcode skills"
      elif ! ${helper} --install --xcrun /usr/bin/xcrun --state ${lib.escapeShellArg state} ${roots}; then
        echo "xcodeSkillsInstall: the helper failed" >&2
      fi
    '';
  };
}
