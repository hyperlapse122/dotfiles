/*
  Check interface:

    import ./tests/host-secrets.nix { inherit pkgs; }

  Runs the packaged scripts/host-secrets against a scratch HOME and the fake
  secrets from tests/lib/fake-secrets.nix, in the order Home Manager
  activation runs it on a non-NixOS host:

  - without an identity, `stage` fails, names the identity path and the
    recovery command, and leaves nothing staged or published;
  - with an identity that is not a recipient, `stage` fails the same way and
    prints no token;
  - an identity with the wrong mode or a symlinked identity is refused;
  - an SSH file the identity cannot decrypt, a token publish-cli-auth
    rejects, a tokens file that lacks openrouter_api_key, or an SSH field
    that is no private key fails stage, names the cause, and leaves no
    plaintext behind;
  - with the right identity, `stage` then `publish` leave gh and glab
    configuration at 0600, the tokens at 0400 in ~/.local/state/cli-auth, and
    the SSH key at 0600 matching the encrypted one, with no staging left;
  - a second run over the published state succeeds with the same result;
  - `publish` refuses to write the SSH key through a symlink.
*/
{ pkgs }:
let
  secrets = import ./lib/fake-secrets.nix { inherit pkgs; };
  hostSecrets = import ../packages/host-secrets.nix { inherit pkgs; };
in
pkgs.runCommand "host-secrets-tests"
  {
    nativeBuildInputs = [
      hostSecrets
      pkgs.openssh
      pkgs.gnugrep
    ];
  }
  ''
    fail() { echo "host-secrets: FAIL: $*" >&2; exit 1; }
    pass() { echo "host-secrets: ok - $*"; }

    # host-secrets with the fixture's arguments; TOKENS and SSH pick the
    # encrypted files, and the paths follow the current HOME.
    TOKENS=${secrets}/tokens.yaml
    SSH=${secrets}/ssh.yaml
    hs() {
      host-secrets "$1" --host fakehost --tokens "$TOKENS" --ssh "$SSH" \
        --state-dir "$HOME/.local/state/cli-auth" --ssh-key "$HOME/.ssh/id_ed25519_nix_config" \
        --github-user gh-user --gitlab-user gl-user --jpi-user jpi-user
    }

    fresh_home() {
      export HOME=$TMPDIR/home-$1
      mkdir -p "$HOME"
    }

    install_key() {
      mkdir -p "$HOME/.config/nix-config/age"
      chmod 700 "$HOME/.config/nix-config/age"
      install -m 600 "$1" "$HOME/.config/nix-config/age/key.txt"
    }

    nothing_published() {
      [ ! -e "$HOME/.local/state/.cli-auth-stage" ] || fail "$1: a staging directory was left behind"
      [ ! -e "$HOME/.local/state/cli-auth" ] || fail "$1: tokens were published"
      [ ! -e "$HOME/.ssh/id_ed25519_nix_config" ] || fail "$1: the SSH key was published"
      [ ! -e "$HOME/.config/gh/hosts.yml" ] || fail "$1: gh configuration was published"
    }

    # --- no identity -------------------------------------------------------
    fresh_home missing
    if hs stage 2>err; then fail 'stage succeeded without an identity'; fi
    grep -q "$HOME/.config/nix-config/age/key.txt" err || fail "the missing identity path is not named: $(cat err)"
    grep -q 'recover-age-identity --user --host fakehost' err || fail "the recovery command is not named: $(cat err)"
    nothing_published 'no identity'
    pass 'stage without an identity fails, names the path and the recovery command, and leaves nothing'

    # --- an identity that is not a recipient --------------------------------
    fresh_home stranger
    install_key ${secrets}/other-key.txt
    if hs stage >out 2>err; then fail 'stage succeeded with a foreign identity'; fi
    grep -q 'not a recipient' err || fail "the foreign identity is not explained: $(cat err)"
    if grep -q FAKE-CANARY out err; then fail 'a token reached the output'; fi
    nothing_published 'foreign identity'
    pass 'stage with a foreign identity fails without printing a token'

    # --- an identity with a loose mode, or behind a symlink ----------------
    fresh_home loose
    install_key ${secrets}/key.txt
    chmod 644 "$HOME/.config/nix-config/age/key.txt"
    if hs stage 2>err; then fail 'stage accepted a 0644 identity'; fi
    grep -q 'mode 0600' err || fail "the loose mode is not named: $(cat err)"
    # A user-owned 0600 target passes every check but the symlink one.
    fresh_home linked
    install -D -m 600 ${secrets}/key.txt "$TMPDIR/real-key.txt"
    mkdir -p "$HOME/.config/nix-config/age"
    ln -s "$TMPDIR/real-key.txt" "$HOME/.config/nix-config/age/key.txt"
    if hs stage 2>err; then fail 'stage accepted a symlinked identity'; fi
    grep -q 'no age identity' err || fail "the symlinked identity is not refused as such: $(cat err)"
    pass 'stage refuses a loose-mode or symlinked identity'

    # --- failures after the first decrypt ------------------------------------
    for case in ssh-other tokens-invalid tokens-missing ssh-invalid; do
      fresh_home "$case"
      install_key ${secrets}/key.txt
      TOKENS=${secrets}/tokens.yaml SSH=${secrets}/ssh.yaml
      case $case in
        ssh-other) SSH=${secrets}/ssh-other.yaml expected='cannot decrypt the host SSH key' ;;
        tokens-invalid) TOKENS=${secrets}/tokens-invalid.yaml expected='failed validation' ;;
        tokens-missing) TOKENS=${secrets}/tokens-missing.yaml expected='cannot decrypt openrouter_api_key' ;;
        ssh-invalid) SSH=${secrets}/ssh-invalid.yaml expected='not a valid private key' ;;
      esac
      if hs stage >out 2>err; then fail "stage succeeded with $case"; fi
      grep -q "$expected" err || fail "$case is not explained: $(cat err)"
      if grep -q FAKE-CANARY out err; then fail "$case: a token reached the output"; fi
      nothing_published "$case"
    done
    TOKENS=${secrets}/tokens.yaml SSH=${secrets}/ssh.yaml
    pass 'a failure after the first decrypt leaves no plaintext and prints no token'

    # --- the right identity --------------------------------------------------
    fresh_home valid
    install_key ${secrets}/key.txt
    for round in first second; do
      hs stage 2>err || fail "$round stage failed: $(cat err)"
      hs publish 2>err || fail "$round publish failed: $(cat err)"
      for file in .config/gh/hosts.yml .config/glab-cli/config.yml .ssh/id_ed25519_nix_config; do
        [ "$(stat -c %a "$HOME/$file")" = 600 ] || fail "$round: $file is not 0600"
      done
      for token in github_token gitlab_token jpi_token tokscale_token synthetic_api_key exa_api_key openrouter_api_key; do
        [ "$(stat -c %a "$HOME/.local/state/cli-auth/$token")" = 400 ] || fail "$round: $token is not 0400"
      done
      [ "$(stat -c %a "$HOME/.local/state/cli-auth")" = 700 ] || fail "$round: the token directory is not 0700"
      grep -q FAKE-CANARY-github "$HOME/.config/gh/hosts.yml" || fail "$round: gh did not receive the token"
      [ "$(ssh-keygen -y -f "$HOME/.ssh/id_ed25519_nix_config" | cut -d' ' -f1,2)" = "$(cut -d' ' -f1,2 ${secrets}/ssh.pub)" ] ||
        fail "$round: the published SSH key is not the host key"
      [ ! -e "$HOME/.local/state/.cli-auth-stage" ] || fail "$round: staging was left behind"
    done
    pass 'stage then publish install every secret privately, twice in a row'

    # --- a retired token leaves the state directory ---------------------------
    fresh_home retired
    install_key ${secrets}/key.txt
    mkdir -p "$HOME/.local/state/cli-auth"
    printf 'FAKE-CANARY retired\n' >"$HOME/.local/state/cli-auth/opencode_api_key"
    hs stage 2>err || fail "retired: stage failed: $(cat err)"
    hs publish 2>err || fail "retired: publish failed: $(cat err)"
    [ ! -e "$HOME/.local/state/cli-auth/opencode_api_key" ] || fail 'publish left the retired opencode_api_key behind'
    [ -f "$HOME/.local/state/cli-auth/synthetic_api_key" ] || fail 'publish did not publish synthetic_api_key'
    pass 'publish deletes a retired token and publishes its replacement'

    # --- publish never writes through a symlink -----------------------------
    fresh_home planted
    install_key ${secrets}/key.txt
    mkdir -p "$HOME/.ssh"
    ln -s "$TMPDIR/elsewhere" "$HOME/.ssh/id_ed25519_nix_config"
    hs stage || fail 'stage failed before the symlink case'
    if hs publish 2>err; then fail 'publish wrote through a symlink'; fi
    [ ! -e "$TMPDIR/elsewhere" ] || fail 'the symlink target was written'
    [ ! -e "$HOME/.local/state/.cli-auth-stage" ] || fail 'a refused publish left staging behind'
    pass 'publish refuses a symlinked SSH key path and cleans up'

    touch $out
  ''
