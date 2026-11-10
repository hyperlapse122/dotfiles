/*
  Check interface:

    import ./tests/sops-recipients.nix { inherit pkgs self; }

  Runs tests/sops-recipients.sh over the repository, then over fixture trees
  built here with fake keys, so each rule it enforces is proven to fail when
  broken. Every tree encrypts its secret files to the recipients its .sops.yaml
  rules name, except where a mutation makes the two disagree:

  - a well-formed tree passes, including a nested secrets/hosts/<name>/ssh.yaml
    and two overlapping rules, where the file follows the first;
  - a file encrypted to one recipient beyond its rule fails, at the top level
    and in a nested directory;
  - a file missing a recipient its rule names fails;
  - a file whose sops block gains any non-age key group while its age recipients
    still match fails;
  - a file encrypted to the second of two overlapping rules fails, because the
    first rule wins;
  - a rule whose age list has a space after each comma passes;
  - a file matching no rule, a file without a sops block, a secrets/*.yml
    file no rule names, a file whose sops block holds no age key at all, a
    first matching rule written as key_groups, and a tree with no encrypted
    file each fail.
*/
{ pkgs, self }:
pkgs.runCommand "sops-recipients-tests"
  {
    nativeBuildInputs = [
      pkgs.age
      pkgs.sops
      pkgs.yq-go
      pkgs.gnugrep
      pkgs.gnused
    ];
  }
  ''
    check=${./sops-recipients.sh}

    bash "$check" ${self}

    age-keygen -o a.key 2>/dev/null
    age-keygen -o b.key 2>/dev/null
    age-keygen -o extra.key 2>/dev/null
    a=$(age-keygen -y a.key)
    b=$(age-keygen -y b.key)
    extra=$(age-keygen -y extra.key)
    printf 'value: fake\n' >plain.yaml

    encrypt() {
      sops --encrypt --age "$1" --input-type yaml --output-type yaml plain.yaml >"$2"
    }

    # A tree with a nested file and two top-level files, plus the single
    # mutation named by $1.
    make_tree() {
      local tree=$TMPDIR/tree-$1
      local ssh=$a tokens="$a,$b" wifi=$a
      local rules="creation_rules:
      - path_regex: secrets/hosts/fakehost/ssh\\.yaml$
        age: $a
      - path_regex: secrets/tokens\\.yaml$
        age: $a,$b
      - path_regex: secrets/wifi\\.yaml$
        age: $a
    "
      case $1 in
        comma-space) rules=''${rules//$a,$b/$a, $b} ;;
        extra-recipient) tokens="$a,$b,$extra" ;;
        nested-extra-recipient) ssh="$a,$extra" ;;
        missing-recipient) tokens=$a ;;
        overlap-first-rule) rules="$rules  - path_regex: secrets/wifi\\.yaml$
        age: $b
    " ;;
        overlap-second-rule)
          rules="$rules  - path_regex: secrets/wifi\\.yaml$
        age: $b
    "
          wifi=$b
          ;;
      esac
      mkdir -p "$tree/secrets/hosts/fakehost"
      printf '%s' "$rules" >"$tree/.sops.yaml"
      encrypt "$ssh" "$tree/secrets/hosts/fakehost/ssh.yaml"
      encrypt "$tokens" "$tree/secrets/tokens.yaml"
      encrypt "$wifi" "$tree/secrets/wifi.yaml"
      case $1 in
        *-group)
          GROUP=''${1%-group} yq -i '.sops[strenv(GROUP)] = [{"fp": "FAKEFINGERPRINT", "created_at": "2026-01-01T00:00:00Z", "enc": "fake"}]' "$tree/secrets/tokens.yaml"
          ;;
        pgp-only-file)
          yq -i 'del(.sops.age) | .sops.pgp = [{"fp": "FAKEFINGERPRINT", "created_at": "2026-01-01T00:00:00Z", "enc": "fake"}]' "$tree/secrets/tokens.yaml"
          ;;
        key-groups-rule)
          printf '%s' "creation_rules:
      - path_regex: secrets/hosts/fakehost/ssh\\.yaml$
        age: $a
      - path_regex: secrets/tokens\\.yaml$
        key_groups:
          - age: [$a, $b]
      - path_regex: secrets/wifi\\.yaml$
        age: $a
    " >"$tree/.sops.yaml"
          ;;
        no-rule) encrypt "$a" "$tree/secrets/orphan.yaml" ;;
        yml-file) encrypt "$a" "$tree/secrets/orphan.yml" ;;
        no-sops-block) cp plain.yaml "$tree/secrets/plain.yaml" ;;
        no-encrypted-file) rm -r "$tree/secrets" && mkdir "$tree/secrets" ;;
      esac
      printf '%s\n' "$tree"
    }

    bash "$check" "$(make_tree valid)" || { echo 'a well-formed tree failed' >&2; exit 1; }
    bash "$check" "$(make_tree comma-space)" || { echo 'a rule with spaces after its commas failed' >&2; exit 1; }
    bash "$check" "$(make_tree overlap-first-rule)" || { echo 'a file following the first of two overlapping rules failed' >&2; exit 1; }

    # Each mutation must fail for its own reason, not for a neighbouring rule.
    expect_failure() {
      local mutation=$1 reason=$2
      if bash "$check" "$(make_tree "$mutation")" 2>err; then
        echo "sops-recipients passed a tree with mutation $mutation" >&2
        exit 1
      fi
      if ! grep -qF -- "$reason" err; then
        echo "sops-recipients failed mutation $mutation for another reason:" >&2
        cat err >&2
        exit 1
      fi
    }

    expect_failure extra-recipient "secrets/tokens.yaml: encrypted to $extra, which its .sops.yaml rule does not name"
    expect_failure nested-extra-recipient "secrets/hosts/fakehost/ssh.yaml: encrypted to $extra, which its .sops.yaml rule does not name"
    expect_failure missing-recipient "secrets/tokens.yaml: not encrypted to $b, which its .sops.yaml rule names"
    for group in pgp kms gcp_kms azure_kv hc_vault key_groups; do
      expect_failure "$group-group" "secrets/tokens.yaml: lists a $group key group"
    done
    expect_failure overlap-second-rule "secrets/wifi.yaml: encrypted to $b, which its .sops.yaml rule does not name"
    expect_failure pgp-only-file 'secrets/tokens.yaml: lists a pgp key group'
    expect_failure key-groups-rule 'secrets/tokens.yaml: its .sops.yaml rule uses key_groups'
    expect_failure no-rule 'secrets/orphan.yaml: matches no creation rule'
    expect_failure yml-file 'secrets/orphan.yml: matches no creation rule'
    expect_failure no-sops-block 'secrets/plain.yaml: has no sops block'
    expect_failure no-encrypted-file 'found no encrypted secrets/**/*.yaml'

    touch $out
  ''
