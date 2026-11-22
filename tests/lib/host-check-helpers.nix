{ pkgs, self }:
let
  configurations = import ./configurations.nix {
    inherit pkgs self;
  };

  # Runs `assertConfiguration` over every configuration the flake builds.
  # Each per-configuration fragment records a failure in `fail` instead of
  # exiting, so one red build names every affected configuration.
  forEveryConfiguration = assertConfiguration: ''
    ${configurations.guard}
    fail=0
    ${pkgs.lib.concatMapStrings assertConfiguration configurations.entries}
    [ "$fail" = 0 ] || exit 1
  '';

  # Runs `assertUser` over every Home Manager user environment the flake
  # builds for this architecture.
  forEveryUser = assertUser: ''
    ${configurations.guard}
    fail=0
    ${pkgs.lib.concatMapStrings assertUser configurations.userEntries}
    [ "$fail" = 0 ] || exit 1
  '';

  # A configuration whose user went missing reports each package as
  # absent inside the builder rather than aborting evaluation.
  userPackagesOf = entry: entry.user.home.packages or [ ];

  userPackageOf =
    pname: entry: pkgs.lib.lists.findFirst (p: (p.pname or "") == pname) null (userPackagesOf entry);

  # Every store-path interpolation stays inside an optionalString guard so
  # that removing the package fails inside the builder with the message
  # below, rather than aborting evaluation with a null coercion error.
  assertUserPackage =
    {
      pname,
      executables,
      desktopEntries,
    }:
    entry:
    let
      package = userPackageOf pname entry;
    in
    ''
      ${pkgs.lib.optionalString (package == null) ''
        echo 'missing ${pname} in user packages on ${entry.name}' >&2
        fail=1
      ''}
      ${pkgs.lib.optionalString (package != null) ''
        ${pkgs.lib.concatMapStrings (executable: ''
          if [ ! -x ${package}/bin/${executable} ]; then
            echo '${pname} package ships no bin/${executable} executable on ${entry.name}' >&2
            fail=1
          fi
        '') executables}
        ${pkgs.lib.concatMapStrings (desktopEntry: ''
          if [ ! -f ${package}/share/applications/${desktopEntry} ]; then
            echo '${pname} package ships no ${desktopEntry} entry on ${entry.name}' >&2
            fail=1
          fi
        '') desktopEntries}
      ''}
    '';
in
{
  inherit
    configurations
    forEveryConfiguration
    forEveryUser
    userPackagesOf
    userPackageOf
    assertUserPackage
    ;
}
