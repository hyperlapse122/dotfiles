{
  pkgs,
  self,
}:
{
  update-dependencies-reconcile =
    pkgs.runCommand "update-dependencies-reconcile-tests"
      {
        nativeBuildInputs = [
          pkgs.actionlint
          pkgs.git
          pkgs.jq
          pkgs.yq-go
          pkgs.gawk
          pkgs.python3
        ];
      }
      ''
        export HOME=$TMPDIR
        export PYTHONDONTWRITEBYTECODE=1
        export UPDATE_CHECK_NAMES='${builtins.toJSON (builtins.attrNames self.checks.x86_64-linux)}'
        actionlint -shellcheck= -pyflakes= ${../.github/workflows/update-dependencies.yml}
        bash ${./update-dependencies-reconcile.sh} \
          ${../.github/workflows/update-dependencies.yml} \
          ${../.gitignore} \
          ${../scripts/ci-update-publish} \
          ${../scripts/ci-update-verify} \
          ${./update-workflow.py}
        touch $out
      '';
  ci-workflow-docs-skip =
    pkgs.runCommand "ci-workflow-docs-skip-tests"
      {
        nativeBuildInputs = [
          pkgs.actionlint
          pkgs.git
          pkgs.gnugrep
          (pkgs.python3.withPackages (p: [ p.pyyaml ]))
          pkgs.nix
        ];
      }
      ''
        # GitHub reports an invalid concurrency or if expression only
        # when the workflow runs.
        actionlint -shellcheck= -pyflakes= ${../.github/workflows/check.yml}
        bash ${./check-workflow-docs-skip.sh} ${../.github/workflows/check.yml}
        touch $out
      '';

}
