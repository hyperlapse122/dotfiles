# omp's declared settings, executed rather than scraped: the generated
# activation block runs in a scratch HOME and the installed
# ~/.omp/agent/config.yml is compared byte-for-byte against the declared
# mapping. The exact-file comparison is the declared-set contract: the
# installed file must equal the declared mapping, catching both drift toward
# omp's runtime writes and omissions.
#
# Every production output also carries ompAuth, which runs after secret
# publication and the settings copy. Executed against a recording stub, it
# hands omp-auth-sync the managed omp and each published key file under its
# omp provider, does nothing on a dry run, and fails when the import fails.
# Bootstrap outputs publish no keys and carry no ompAuth.
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

  authSync = "${
    (import ../packages/agent-tools.nix { inherit pkgs; }).ompAuthSync
  }/bin/omp-auth-sync";
  providerFiles = {
    synthetic = "synthetic_api_key";
    openrouter = "openrouter_api_key";
    openai = "openai_api_key";
    anthropic = "anthropic_api_key";
    opencode-go = "opencode_go_api_key";
    exa = "exa_api_key";
  };

  assertAuth =
    entry:
    let
      auth = entry.user.home.activation.ompAuth or null;
      keyDirectory = entry.user.my.secrets.stateDir or "";
      # The check compares text only, so it carries no build dependency on omp.
      omp = builtins.unsafeDiscardStringContext "${entry.user.programs.omp.package}/bin/omp";
      expected = [
        "--omp"
        omp
      ]
      ++ lib.concatLists (
        lib.mapAttrsToList (provider: file: [
          "--credential"
          "${provider}=${keyDirectory}/${file}"
        ]) providerFiles
      );
    in
    if entry.bootstrap then
      lib.optionalString (auth != null) ''
        echo 'unexpected ompAuth on bootstrap output ${entry.name}' >&2
        failed=1
      ''
    else if auth == null then
      ''
        echo 'missing home.activation.ompAuth on production output ${entry.name}' >&2
        failed=1
      ''
    else
      ''
        for step in nixConfigSecretsPublish ompConfig; do
          case " ${toString (auth.after or [ ])} " in
            *" $step "*) ;;
            *) echo "ompAuth must run after $step on ${entry.name}" >&2; failed=1 ;;
          esac
        done
        if ! python3 ${./omp-activation.py} ${
          pkgs.writeText "omp-auth-block.sh" (builtins.unsafeDiscardStringContext (auth.data or ""))
        } ${authSync} ${pkgs.writeText "omp-auth-expected.json" (builtins.toJSON expected)}; then
          echo 'the ompAuth activation did not run as expected on ${entry.name}' >&2
          failed=1
        fi
      '';
in
pkgs.runCommand "omp-declared-settings"
  {
    inherit activationBlock expectedYaml;
    nativeBuildInputs = [ pkgs.python3 ];
  }
  ''
    failed=0
    home=$TMPDIR/home
    mkdir -p "$home"
    run() { "$@"; }
    export HOME="$home"
    source "$activationBlock"
    if ! cmp -s "$home/.omp/agent/config.yml" "$expectedYaml"; then
      echo "omp config drifted from the declared settings:" >&2
      diff "$expectedYaml" "$home/.omp/agent/config.yml" >&2 || true
      failed=1
    fi
    ${lib.optionalString (!lib.any (entry: !entry.bootstrap) entries) ''
      echo 'no production output to check ompAuth on' >&2
      failed=1
    ''}
    ${lib.concatMapStringsSep "\n" assertAuth entries}
    if [ "$failed" != 0 ]; then exit 1; fi
    touch "$out"
  ''
