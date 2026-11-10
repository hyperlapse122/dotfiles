/*
  Check interface:

    import ./tests/git-cli-repo-flags.nix { inherit pkgs self fixtures; }

  Runs the gh and glab packages each Home Manager user installs the way the
  shared agent instructions tell an agent to name a repository outside a
  checkout, and asserts that each request goes to the named host and project
  rather than to github.com, gitlab.com, or the current directory:

    gh pr view 1 --repo HOST/OWNER/REPO
    gh repo view HOST/OWNER/REPO
    GH_REPO=HOST/OWNER/REPO gh api --hostname HOST 'repos/{owner}/{repo}'
    GITLAB_HOST=HOST glab mr view 1 --repo https://HOST/GROUP/PROJECT
    GITLAB_HOST=HOST glab repo view https://HOST/GROUP/PROJECT
    GITLAB_HOST=HOST GITLAB_REPO=https://HOST/GROUP/PROJECT glab api 'projects/:fullpath'
    GITLAB_HOST=HOST GITLAB_REPO=https://HOST/GROUP/PROJECT glab repo delete --yes

  The packages come from each user's `home.packages`, found by `pname`, so the
  check runs what the profile installs, and a user without gh or glab fails.
  The user list is `userEntries` from `tests/lib/configurations.nix`.

  The build sandbox has no network, so every request fails to resolve its
  host. Each CLI prints the request it was about to send first (GH_DEBUG=api,
  GLAB_DEBUG_HTTP=1), and that is what the check reads, so the delete never
  leaves the sandbox. The hosts sit under the reserved .invalid zone, the
  tokens are fake, and HOME is empty, so no real configuration or credential
  takes part. A help-text check would stay green while glab sent a bare
  HOST/OWNER/REPO, or a delete without GITLAB_HOST, to gitlab.com, which it
  does.

  Each output goes to a file first and grep reads that file, so no pipe can
  report a miss when grep stops early. See
  .compound-engineering/artifacts/solutions/logic-errors/printf-pipe-grep-q-under-pipefail-reports-a-miss.md
  Every miss is recorded, so one red build names all of them.
*/
{
  pkgs,
  self,
  fixtures ? null,
}:
let
  inherit (pkgs) lib;
  configurations = import ./lib/configurations.nix (
    { inherit pkgs self; } // lib.optionalAttrs (fixtures != null) { inherit fixtures; }
  );

  packageOf =
    user: pname: lib.findFirst (p: (p.pname or null) == pname) null (user.home.packages or [ ]);

  # Interpolating a missing package would fail evaluation, which a mutation
  # test cannot tell from a passing check, so a missing one becomes a builder
  # failure instead.
  probeEntry =
    entry:
    let
      gh = packageOf entry.user "gh";
      glab = packageOf entry.user "glab";
      label = lib.escapeShellArg entry.name;
    in
    if gh == null || glab == null then
      ''
        echo "missing: "${label}" installs no ${if gh == null then "gh" else "glab"}" >> "$failures"
      ''
    else
      ''
        probe ${label} ${gh}/bin/gh ${glab}/bin/glab
      '';
in
pkgs.runCommand "git-cli-repo-flags" { } ''
  export HOME="$(mktemp -d)"
  export NO_COLOR=1 GH_TOKEN=fake-token GH_ENTERPRISE_TOKEN=fake-token GITLAB_TOKEN=fake-token
  export GH_DEBUG=api GLAB_DEBUG_HTTP=1
  failures="$HOME/failures"
  : > "$failures"
  cd "$HOME"

  ghHost=ghe.invalid
  glHost=gitlab.invalid
  glUrl="https://$glHost/group/project"

  # run <name> <command...>: capture a run that is expected to fail offline
  run() {
    name=$1
    shift
    timeout 60 "$@" > "$HOME/$name" 2>&1 || true
  }

  # expect <name> <fixed string> <description>
  expect() {
    if ! grep -qF -e "$2" "$HOME/$1"; then
      echo "missing: $label: $3" >> "$failures"
      sed 's/^/  | /' "$HOME/$1" >> "$failures"
    fi
  }

  # probe <label> <gh> <glab>
  probe() {
    label=$1
    gh=$2
    glab=$3

    run gh-pr-view "$gh" pr view 1 --repo "$ghHost/owner/repo"
    expect gh-pr-view "Host: $ghHost" "gh pr view --repo HOST/OWNER/REPO does not reach HOST"

    run gh-repo-view "$gh" repo view "$ghHost/owner/repo"
    expect gh-repo-view "Host: $ghHost" "gh repo view HOST/OWNER/REPO does not reach HOST"

    run gh-api env GH_REPO="$ghHost/owner/repo" "$gh" api --hostname "$ghHost" 'repos/{owner}/{repo}'
    expect gh-api "Host: $ghHost" "gh api --hostname HOST does not reach HOST"
    expect gh-api "/repos/owner/repo " "gh api does not fill {owner}/{repo} from GH_REPO"

    run glab-mr-view env GITLAB_HOST="$glHost" "$glab" mr view 1 --repo "$glUrl"
    expect glab-mr-view "Host: $glHost" "glab mr view --repo FULL_URL does not reach HOST"
    expect glab-mr-view "/projects/group%2Fproject/" "glab mr view --repo FULL_URL does not name the project"

    run glab-repo-view env GITLAB_HOST="$glHost" "$glab" repo view "$glUrl"
    expect glab-repo-view "Host: $glHost" "glab repo view FULL_URL does not reach HOST"
    expect glab-repo-view "/projects/group%2Fproject" "glab repo view FULL_URL does not name the project"

    run glab-api env GITLAB_HOST="$glHost" GITLAB_REPO="$glUrl" "$glab" api 'projects/:fullpath'
    expect glab-api "Host: $glHost" "glab api with GITLAB_REPO=FULL_URL does not reach HOST"
    expect glab-api "/projects/group%2Fproject " "glab api does not fill :fullpath from GITLAB_REPO"

    run glab-repo-delete env GITLAB_HOST="$glHost" GITLAB_REPO="$glUrl" "$glab" repo delete --yes
    expect glab-repo-delete "Host: $glHost" "glab repo delete with GITLAB_HOST does not reach HOST"
    expect glab-repo-delete "DELETE /api/v4/projects/group%2Fproject " "glab repo delete does not name the project"
  }

  ${configurations.userGuard}
  ${lib.concatMapStrings probeEntry configurations.userEntries}

  if [ -s "$failures" ]; then
    cat "$failures" >&2
    exit 1
  fi

  touch $out
''
