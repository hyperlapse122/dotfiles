# omp's declared settings and the shared cache trust, read from materialized
# outputs: the generated ~/.omp/agent/config.yml the activation installs and
# the /etc/nix/nix.conf each darwin host renders. The exact-file comparison is
# the declared-set contract: the installed file must equal the declared
# mapping, catching both drift toward omp's runtime writes and omissions.
{
  pkgs,
  configurations,
}:
let
  inherit (pkgs) lib;
  etcFile = import ./lib/etc-file.nix { inherit lib; };

  # Every darwin host imports the same shared user layer, so one generated
  # config file covers them all; nix.conf is rendered per host.
  first = lib.head (lib.attrNames configurations);
  firstConfig = configurations.${first}.config;
  firstUser = firstConfig.home-manager.users.${firstConfig.my.user.name};
  activationData = firstUser.home.activation.ompConfig.data or "";
  storePath = builtins.match ".*(/nix/store/[a-z0-9]+-omp-config[.]yml).*" activationData;
  configYaml = lib.throwIf (
    storePath == null
  ) "omp-check: the darwin activation carries no generated omp-config.yml" (builtins.head storePath);

  # The expected file runs the same generator over the same mapping, so the
  # comparison is byte-exact; any drift between omp.nix and this mapping
  # fails here rather than on a host.
  expectedYaml = (pkgs.formats.yaml { }).generate "expected-omp-config.yml" {
    modelRoles.default = "synthetic/hf:zai-org/GLM-5.3-Flash";
    composer.shape = "band";
    composer.tokenRate = true;
    theme.dark = "titanium";
    theme.light = "light";
    update.auto = false;
    symbolPreset = "nerd";
  };

  nixConf =
    name:
    let
      path = etcFile configurations.${name}.config "nix/nix.conf";
    in
    lib.throwIf (path == null) "omp-check: ${name} does not materialize /etc/nix/nix.conf" path;
  nixConfs = map nixConf (lib.attrNames configurations);
in
pkgs.runCommand "omp-declared-settings"
  {
    inherit configYaml expectedYaml;
    nixConfs = lib.concatStringsSep " " nixConfs;
  }
  ''
    if ! cmp -s "$configYaml" "$expectedYaml"; then
      echo "omp config drifted from the declared settings:" >&2
      diff "$expectedYaml" "$configYaml" >&2 || true
      exit 1
    fi
    for conf in $nixConfs; do
      for needle in \
        "https://cache.nixos.org" \
        "https://nix-community.cachix.org" \
        "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="; do
        grep -q -- "$needle" "$conf" || {
          echo "$conf is missing $needle" >&2
          exit 1
        }
      done
    done
    touch "$out"
  ''
