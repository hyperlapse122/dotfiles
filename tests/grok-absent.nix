{
  pkgs,
  self,
  darwinFixtures,
}:
let
  inherit (import ./lib/host-check-helpers.nix { inherit pkgs self; }) configurations userPackagesOf;
  inherit (pkgs) lib;
  isGrokName = name: lib.hasInfix "grok-bot" (lib.toLower name);
  grokNamesOf = names: lib.unique (builtins.filter isGrokName names);
  # A package counts by its pname or its name, so a renamed wrapper
  # such as grok-bot-cli is caught as well as grok-bot.
  grokPackagesOf =
    packages:
    grokNamesOf (
      lib.concatMap (p: [
        (p.pname or "")
        (p.name or "")
      ]) packages
    );
  darwinApps = import ../modules/shared/darwin-apps.nix;
  grokApps = grokNamesOf (builtins.attrNames darwinApps.apps);
  report =
    names: message:
    lib.optionalString (names != [ ]) ''
      echo ${lib.escapeShellArg "${message}: ${toString names}"} >&2
      fail=1
    '';
  assertUser = entry: ''
    ${report (grokPackagesOf (userPackagesOf entry)) "Grok Bot packages are still in the user packages on ${entry.name}"}
  '';
  assertNixos = entry: ''
    ${report (grokPackagesOf (
      entry.config.environment.systemPackages or [ ]
    )) "Grok Bot packages are still in environment.systemPackages on ${entry.name}"}
    ${report (grokNamesOf (
      builtins.attrNames (entry.config.systemd.services or { })
    )) "${entry.name} still has Grok Bot system units"}
    ${report (grokNamesOf (
      builtins.attrNames (entry.config.systemd.user.services or { })
    )) "${entry.name} still has Grok Bot user units"}
  '';
  # Real Mac hosts and the macOS fixtures alike, read from the
  # evaluated configuration, so a cask, App Store app, or package a
  # module adds outside modules/shared/darwin-apps.nix is caught too.
  darwinEntries =
    map (entry: { inherit (entry) name host; }) darwinFixtures
    ++ lib.mapAttrsToList (name: host: { inherit name host; }) self.darwinConfigurations;
  assertDarwin =
    entry:
    let
      inherit (entry.host) config;
      user = config.home-manager.users.${config.my.user.name} or { };
    in
    ''
      ${report (grokNamesOf (
        map (cask: cask.name) config.homebrew.casks
      )) "the macOS casks of ${entry.name} still include Grok Bot"}
      ${report (grokNamesOf (builtins.attrNames config.homebrew.masApps)) "the App Store apps of ${entry.name} still include Grok Bot"}
      ${report (grokPackagesOf (
        config.environment.systemPackages or [ ]
      )) "Grok Bot packages are still in environment.systemPackages on ${entry.name}"}
      ${assertUser {
        inherit (entry) name;
        inherit user;
      }}
    '';
in
pkgs.runCommand "grok-absent" { } ''
  ${configurations.guard}
  fail=0
  ${lib.concatMapStrings assertUser configurations.userEntries}
  ${lib.concatMapStrings assertNixos configurations.entries}
  ${lib.optionalString (darwinFixtures == [ ]) ''
    echo 'no macOS fixture host, so the evaluated-cask side of this check would cover none' >&2
    fail=1
  ''}
  ${lib.concatMapStrings assertDarwin darwinEntries}
  ${report grokApps "modules/shared/darwin-apps.nix still maps Grok Bot apps"}
  [ "$fail" = 0 ] || exit 1
  touch $out
''
