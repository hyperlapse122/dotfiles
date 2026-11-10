/*
  Check interface:

    import ./tests/wifi-assertions.nix { inherit pkgs inputs; }

  Verifies that modules/nixos/wifi.nix's `my.wifi.networks` assertions
  actually fire on invalid labels and stay quiet on valid ones. This is a
  pure module-evaluation check (no build, no VM): a colliding or
  shell-unsafe label must fail evaluation with a clear message, not corrupt
  the SSID/PSK substitution silently.
*/
{ pkgs, inputs }:
let
  inherit (pkgs) lib;

  failedAssertions =
    networks:
    let
      cfg =
        (inputs.nixpkgs.lib.nixosSystem {
          system = pkgs.system;
          modules = [
            inputs.sops-nix.nixosModules.sops
            ../modules/nixos/system/secrets.nix
            ../modules/nixos/wifi.nix
            {
              boot.loader.grub.enable = false;
              fileSystems."/" = {
                device = "/dev/null";
                fsType = "ext4";
              };
              my.wifi.networks = networks;
            }
          ];
        }).config;
    in
    map (a: a.message) (builtins.filter (a: !a.assertion) cfg.assertions);

  cases = [
    {
      name = "case-insensitive duplicate labels";
      networks = [
        "Home"
        "home"
      ];
      expectFailure = true;
    }
    {
      name = "label with a hyphen";
      networks = [ "home-office" ];
      expectFailure = true;
    }
    {
      name = "label starting with a digit";
      networks = [ "4thfloor" ];
      expectFailure = true;
    }
    {
      name = "valid distinct labels";
      networks = [
        "home"
        "office"
      ];
      expectFailure = false;
    }
  ];

  checkCase =
    case:
    let
      failed = failedAssertions case.networks;
      failedAny = failed != [ ];
    in
    if case.expectFailure && !failedAny then
      ''
        echo 'expected my.wifi.networks = ${builtins.toJSON case.networks} (${case.name}) to fail an assertion, but it evaluated cleanly' >&2
        exit 1
      ''
    else if !case.expectFailure && failedAny then
      ''
        echo 'expected my.wifi.networks = ${builtins.toJSON case.networks} (${case.name}) to pass all assertions, but got: ${lib.concatStringsSep " ||| " failed}' >&2
        exit 1
      ''
    else
      ''
        echo 'ok: ${case.name}'
      '';
in
pkgs.runCommand "wifi-assertions-tests" { } ''
  ${lib.concatStringsSep "\n" (map checkCase cases)}
  touch $out
''
