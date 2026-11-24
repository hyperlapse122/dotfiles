# omp's declared settings, executed rather than scraped: the generated
# activation block runs in a scratch HOME and the installed
# ~/.omp/agent/config.yml is compared byte-for-byte against the declared
# mapping. The exact-file comparison is the declared-set contract: the
# installed file must equal the declared mapping, catching both drift toward
# omp's runtime writes and omissions.
{
  pkgs,
  entries,
}:
let
  inherit (pkgs) lib;

  # Every darwin host imports the same shared user layer, so one generated
  # config file covers them all.
  firstUser = (lib.head entries).user;
  activationData = firstUser.home.activation.ompConfig.data or "";
  activationBlock =
    lib.throwIf (activationData == "") "omp-check: the darwin activation carries no ompConfig step"
      (pkgs.writeText "omp-activation-block.sh" activationData);

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
in
pkgs.runCommand "omp-declared-settings"
  {
    inherit activationBlock expectedYaml;
  }
  ''
    home=$TMPDIR/home
    mkdir -p "$home"
    run() { "$@"; }
    export HOME="$home"
    source "$activationBlock"
    if ! cmp -s "$home/.omp/agent/config.yml" "$expectedYaml"; then
      echo "omp config drifted from the declared settings:" >&2
      diff "$expectedYaml" "$home/.omp/agent/config.yml" >&2 || true
      exit 1
    fi
    touch "$out"
  ''
