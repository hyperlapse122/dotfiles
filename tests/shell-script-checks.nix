{
  pkgs,
  self,
  system,
  agentTools,
}:
{
  mobile-devices = pkgs.runCommand "mobile-devices-tests" { } ''
    bash ${./mobile-devices.sh} ${
      pkgs.lib.getExe (import ../packages/mobile-devices.nix { inherit pkgs; })
    }
    touch $out
  '';
  xcode-skills = pkgs.runCommand "xcode-skills-tests" { } ''
    bash ${./xcode-skills.sh} ${pkgs.lib.getExe (import ../packages/xcode-skills.nix { inherit pkgs; })}
    touch $out
  '';
  tokscale-wrapper =
    let
      packaged = import ../packages/tokscale.nix {
        inherit pkgs;
        hostName = "test-host";
        tokenFile = "${pkgs.writeText "tokscale-fake-token" "fake-token-123\n"}";
      };
    in
    pkgs.runCommand "tokscale-wrapper-tests" { } ''
      export HOME=$TMPDIR
      mkdir -p scripts tests
      cp ${../scripts/tokscale} scripts/tokscale
      cp ${./tokscale.sh} tests/tokscale.sh
      chmod +x scripts/tokscale
      patchShebangs scripts/tokscale
      bash tests/tokscale.sh scripts/tokscale
      bash tests/tokscale.sh --packaged ${packaged}/bin/tokscale test-host fake-token-123
      touch $out
    '';
  lint-staged-markdown =
    let
      miseToml = builtins.fromTOML (builtins.readFile ../mise.toml);
      miseLock = builtins.fromTOML (builtins.readFile ../mise.lock);
      tomlVersion = miseToml.tools."npm:markdownlint-cli2";
      lockVersion = (builtins.head miseLock.tools."npm:markdownlint-cli2").version;
      nixpkgsVersion = pkgs.markdownlint-cli2.version;
      taskRun = miseToml.tasks."lint-staged-markdown".run;
    in
    pkgs.runCommand "lint-staged-markdown-tests"
      {
        nativeBuildInputs = [
          pkgs.bash
          pkgs.git
          pkgs.markdownlint-cli2
          self.packages.${system}.agent-check
        ];
      }
      ''
        export HOME=$TMPDIR
        mkdir -p scripts tests .githooks
        cp ${../scripts/lint-staged-markdown} scripts/lint-staged-markdown
        cp ${../scripts/check-changed-files} scripts/check-changed-files
        cp ${./lint-staged-markdown.sh} tests/lint-staged-markdown.sh
        cp ${../.githooks/pre-commit} .githooks/pre-commit
        cp ${../.markdownlint-cli2.jsonc} .markdownlint-cli2.jsonc
        cp ${../mise.toml} mise.toml
        chmod +x scripts/lint-staged-markdown .githooks/pre-commit
        patchShebangs scripts/lint-staged-markdown .githooks/pre-commit tests/lint-staged-markdown.sh

        bash tests/lint-staged-markdown.sh scripts/lint-staged-markdown .githooks/pre-commit .markdownlint-cli2.jsonc "${tomlVersion}" "${lockVersion}" "${nixpkgsVersion}" "${taskRun}"
        touch $out
      '';
  ci-docs-only-paths =
    pkgs.runCommand "ci-docs-only-paths-tests" { nativeBuildInputs = [ pkgs.bash ]; }
      ''
        mkdir -p scripts tests
        cp ${../scripts/ci-docs-only-paths} scripts/ci-docs-only-paths
        cp ${./ci-docs-only-paths.sh} tests/ci-docs-only-paths.sh
        chmod +x scripts/ci-docs-only-paths
        patchShebangs scripts/ci-docs-only-paths
        bash tests/ci-docs-only-paths.sh scripts/ci-docs-only-paths
        touch $out
      '';
  markdown-lint =
    pkgs.runCommand "markdown-lint-tests" { nativeBuildInputs = [ pkgs.markdownlint-cli2 ]; }
      ''
        export HOME=$TMPDIR
        cd ${self}
        markdownlint-cli2
        touch $out
      '';
  age-identity-helpers =
    pkgs.runCommand "age-identity-helpers-tests" { nativeBuildInputs = [ pkgs.coreutils ]; }
      ''
        export HOME=$TMPDIR
        mkdir -p scripts tests
        cp ${../scripts/recover-age-identity} scripts/recover-age-identity
        cp ${../scripts/prepare-age-identity} scripts/prepare-age-identity
        cp ${./age-identity-helpers.sh} tests/age-identity-helpers.sh
        chmod +x scripts/recover-age-identity scripts/prepare-age-identity
        patchShebangs scripts/recover-age-identity scripts/prepare-age-identity
        bash tests/age-identity-helpers.sh \
          scripts/recover-age-identity scripts/prepare-age-identity
        touch $out
      '';
  android-sdk-release =
    pkgs.runCommand "android-sdk-release-tests" { nativeBuildInputs = [ pkgs.python3 ]; }
      ''
        export PYTHONDONTWRITEBYTECODE=1
        export ANDROID_SDK_RELEASE=${pkgs.lib.getExe agentTools.androidSdkRelease}
        python ${./test_android_sdk_release.py}
        touch $out
      '';
  android-sdk-repo-parity =
    pkgs.runCommand "android-sdk-repo-parity" { nativeBuildInputs = [ pkgs.python3 ]; }
      ''
        export PYTHONDONTWRITEBYTECODE=1
        export ANDROID_SDK_REPO_PARITY=${./android-sdk-repo-parity.py}
        python ${./test_android_sdk_repo_parity.py}
        python ${./android-sdk-repo-parity.py} \
          ${../packages/android-sdk-repo.json} \
          ${pkgs.path}/pkgs/development/mobile/androidenv/repo.json
        touch $out
      '';

}
