/*
  Check interface:

    import ./tests/omp.nix { inherit pkgs entries; }

  `entries` is the `{ name, user, ... }` list of the Home Manager user
  environments this architecture builds (tests/lib/configurations.nix
  `userEntries` on Linux, the darwin configurations' users on macOS).

  Verifies, per entry:
  - omp in user packages is the release binary packages/omp.nix installs, at
    the version packages/omp-release.json pins, not the upstream module's
    source-built default.
  - The ompConfig activation, executed in a scratch HOME, installs a
    ~/.omp/agent/config.yml byte-identical to the declared mapping below, which
    catches both drift toward omp's runtime writes and omissions.
  - On a production macOS output, the ompAuth activation runs after secret
    publication and the settings copy. Executed against a recording stub, it
    hands omp-auth-sync the managed omp and each published key file under its
    omp provider, does nothing on a dry run, and fails when the import fails.
    Bootstrap and NixOS outputs carry no ompAuth; NixOS imports from
    sops-install-secrets instead (tests/agent-api-key-secrets.nix).

  And once: the `omp` input in flake.lock is locked to the tag
  `v<version>` and the revision packages/omp-release.json pins, so the Home
  Manager module and the binary come from the same release. The two files are
  read separately; nothing derives one from the other.

  Every lookup carries an `or` fallback and every conditional block sits
  behind `lib.optionalString`, so a removed declaration fails inside the
  builder rather than during evaluation. The builder collects every failure
  instead of exiting at the first.
*/
{
  pkgs,
  entries,
}:
let
  inherit (pkgs) lib;

  esc = value: lib.escapeShellArg (toString value);

  omp = import ../packages/omp.nix { inherit pkgs; };
  pin = builtins.fromJSON (builtins.readFile ../packages/omp-release.json);
  lockNode = (builtins.fromJSON (builtins.readFile ../flake.lock)).nodes.omp or { };
  lockedRev = lockNode.locked.rev or "";
  lockedRef = lockNode.original.ref or "";
  pinnedRev = pin.rev or "";
  pinnedVersion = pin.version or "";

  # The expected file runs the same generator over the same mapping, so the
  # comparison is byte-exact; any drift between omp.nix and this mapping
  # fails here rather than on a host.
  expectedYaml = (pkgs.formats.yaml { }).generate "expected-omp-config.yml" {
    modelRoles = {
      default = "openrouter/deepseek/deepseek-v4.1-flash-1017:max";
      smol = "openrouter/deepseek/deepseek-v4.1-flash-1017:auto";
      slow = "openrouter/anthropic/claude-opus-5.5:medium";
      judge = "ollama/clef-flash:latest";
      dictation = "openrouter/openai/whisper-large-v3";
      speech = "local/phonon-31m";
      image = "openrouter/bytedance-seed/seedream-5-5";
      web = "web/parallel";
    };
    defaultThinkingLevel = "auto";
    composer.shape = "band";
    composer.tokenRate = true;
    theme.dark = "titanium";
    theme.light = "light";
    update.auto = false;
    symbolPreset = "nerd";
    setupVersion = 3;
  };

  authSync = "${
    (import ../packages/agent-tools.nix { inherit pkgs; }).ompAuthSync
  }/bin/omp-auth-sync";
  providerKeyFiles = {
    synthetic = "synthetic_api_key";
    openrouter = "openrouter_api_key";
    anthropic = "anthropic_api_key";
    opencode-go = "opencode_go_api_key";
    exa = "exa_api_key";
  };

  assertAuth =
    entry: user:
    let
      hostName = entry.name;
      auth = user.home.activation.ompAuth or null;
      expected = [
        "--omp"
        (builtins.unsafeDiscardStringContext "${toString omp}/bin/omp")
      ]
      ++ lib.concatLists (
        lib.mapAttrsToList (provider: file: [
          "--credential"
          "${provider}=${user.my.secrets.stateDir or ""}/${file}"
        ]) providerKeyFiles
      );
      expectAuth = (entry.kind or "") == "darwin" && !(entry.bootstrap or true);
    in
    ''
      ${lib.optionalString (expectAuth && auth == null) ''
        echo 'missing home.activation.ompAuth on production output ${hostName}' >&2
        failed=1
      ''}
      ${lib.optionalString (!expectAuth && auth != null) ''
        echo 'unexpected ompAuth on ${hostName}' >&2
        failed=1
      ''}
      ${lib.optionalString (expectAuth && auth != null) ''
        for step in nixConfigSecretsPublish ompConfig; do
          case ${esc " ${toString (auth.after or [ ])} "} in
            *" $step "*) ;;
            *) echo "ompAuth must run after $step on ${hostName}" >&2; failed=1 ;;
          esac
        done
        if ! python3 ${./omp-activation.py} ${
          pkgs.writeText "omp-auth-block.sh" (builtins.unsafeDiscardStringContext (auth.data or ""))
        } ${authSync} ${pkgs.writeText "omp-auth-expected.json" (builtins.toJSON expected)}; then
          echo 'the ompAuth activation did not run as expected on ${hostName}' >&2
          failed=1
        fi
      ''}
    '';

  assertEntry =
    entry:
    let
      hostName = entry.name;
      user = entry.user or { };
      package = lib.lists.findFirst (p: (p.pname or "") == "omp") null (user.home.packages or [ ]);
      activationData = user.home.activation.ompConfig.data or "";
    in
    ''
      ${lib.optionalString (package == null) ''
        echo 'missing omp in user packages on ${hostName}' >&2
        failed=1
      ''}
      ${lib.optionalString (package != null) ''
        # Compares output paths as strings, so a wrong package (such as the
        # module's source-built default) fails here without being built.
        if [ ${esc (builtins.unsafeDiscardStringContext (toString package))} != ${esc (builtins.unsafeDiscardStringContext (toString omp))} ]; then
          echo ${esc "omp on ${hostName} is not the release binary packages/omp.nix installs"} >&2
          failed=1
        fi
        if [ ${esc (package.version or "")} != ${esc pinnedVersion} ]; then
          echo ${esc "omp on ${hostName} is not the pinned version ${pinnedVersion}"} >&2
          failed=1
        fi
      ''}
      ${lib.optionalString (activationData == "") ''
        echo 'missing home.activation.ompConfig on ${hostName}' >&2
        failed=1
      ''}
      ${lib.optionalString (activationData != "") ''
        home=$TMPDIR/${esc hostName}
        mkdir -p "$home"
        if ! (export HOME="$home"; run() { "$@"; }; source ${pkgs.writeText "omp-activation-block.sh" activationData}); then
          echo 'the ompConfig activation failed on ${hostName}' >&2
          failed=1
        elif ! cmp -s "$home/.omp/agent/config.yml" ${expectedYaml}; then
          echo 'omp config drifted from the declared settings on ${hostName}:' >&2
          diff ${expectedYaml} "$home/.omp/agent/config.yml" >&2 || true
          failed=1
        fi
      ''}
      ${assertAuth entry user}
    '';
in
pkgs.runCommand "omp-tests"
  {
    nativeBuildInputs = [
      pkgs.diffutils
      pkgs.jq
      pkgs.python3
    ];
  }
  ''
    failed=0

    ${lib.optionalString (entries == [ ]) ''
      echo 'no Home Manager user environments to check' >&2
      failed=1
    ''}
    ${lib.optionalString
      (
        lib.any (entry: (entry.kind or "") == "darwin") entries
        && !lib.any (entry: (entry.kind or "") == "darwin" && !(entry.bootstrap or true)) entries
      )
      ''
        echo 'no production macOS output to check ompAuth on' >&2
        failed=1
      ''
    }

    if [ ${esc lockedRev} != ${esc pinnedRev} ] || [ -z ${esc pinnedRev} ]; then
      echo ${esc "the omp input drifted from the pinned release: packages/omp-release.json pins '${pinnedRev}', flake.lock locked '${lockedRev}'"} >&2
      failed=1
    fi
    if [ ${esc lockedRef} != ${esc "v${pinnedVersion}"} ]; then
      echo ${esc "the omp input must name the pinned release tag: flake.lock records ref '${lockedRef}', expected 'v${pinnedVersion}'"} >&2
      failed=1
    fi

    ${lib.optionalString pkgs.stdenv.hostPlatform.isDarwin ''
      # The pinned omp itself must accept omp-auth-sync's import: a managed key
      # replaces the provider's stored key while that provider's OAuth login and
      # another provider's key stay. Only Darwin runs it, because the Linux
      # release binary needs the host's nix-ld loader, which the sandbox lacks.
      export HOME=$TMPDIR/omp-store
      mkdir -p "$HOME"
      printf '%s' '{"version":1,"credentials":[{"provider":"synthetic","credential":{"type":"api_key","key":"FAKE hand","source":"login"}},{"provider":"deepseek","credential":{"type":"api_key","key":"FAKE other","source":"login"}},{"provider":"anthropic","credential":{"type":"oauth","access":"FAKE a","refresh":"FAKE r","expires":1}}]}' \
        | ${omp}/bin/omp auth import - 2>/dev/null
      printf 'FAKE managed synthetic\n' > "$HOME/synthetic"
      printf 'FAKE managed anthropic\n' > "$HOME/anthropic"
      if ! ${authSync} --omp ${omp}/bin/omp --credential "synthetic=$HOME/synthetic" --credential "anthropic=$HOME/anthropic"; then
        echo 'omp-auth-sync failed against the pinned omp' >&2
        failed=1
      fi
      stored=$(${omp}/bin/omp auth export 2>/dev/null | jq -c '[.credentials[] | [.provider, .credential.type, (.credential.key // .credential.access), (.credential.source // null)]] | sort')
      want='[["anthropic","api_key","FAKE managed anthropic","login"],["anthropic","oauth","FAKE a",null],["deepseek","api_key","FAKE other","login"],["synthetic","api_key","FAKE managed synthetic","login"]]'
      if [ "$stored" != "$want" ]; then
        echo "the pinned omp stored $stored after the import, expected $want" >&2
        failed=1
      fi
    ''}

    ${lib.concatMapStringsSep "\n" assertEntry entries}

    if [ "$failed" != "0" ]; then
      exit 1
    fi
    touch $out
  ''
