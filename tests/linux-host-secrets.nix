/*
  Check interface:

    import ./tests/linux-host-secrets.nix { inherit pkgs self; }

  Runs tests/linux-host-secrets.sh over the repository, then over fixture
  trees built here with fake keys, so each rule it enforces is proven to fail
  when broken even while hosts/ holds no non-NixOS host. Every tree encrypts
  its secret files to the recipients its .sops.yaml rules name, except where a
  mutation makes the two disagree:

  - a well-formed tree passes;
  - a host SSH file encrypted to a second recipient fails;
  - a missing host SSH file, or a missing recorded recipient, fails;
  - a host recipient missing from the tokens.yaml rule fails;
  - a tokens.yaml rule that names the host while the file was never re-keyed
    for it fails;
  - a host recipient in the wifi.yaml, tailscale.yaml, or printers.yaml rule fails;
  - a wifi.yaml or printers.yaml encrypted to the host while its rule does not name it fails.
*/
{ pkgs, self }:
pkgs.runCommand "linux-host-secrets-tests"
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
    check=${./linux-host-secrets.sh}

    bash "$check" ${self}

    age-keygen -o host.key 2>/dev/null
    age-keygen -o nixos.key 2>/dev/null
    host=$(age-keygen -y host.key)
    nixos=$(age-keygen -y nixos.key)
    printf 'value: fake\n' >plain.yaml

    encrypt() {
      sops --encrypt --age "$1" --input-type yaml --output-type yaml plain.yaml >"$2"
    }

    # A tree with one non-NixOS host, plus the single mutation named by $1.
    make_tree() {
      local tree=$TMPDIR/tree-$1
      mkdir -p "$tree/hosts/fakehost" "$tree/secrets/bootstrap/fakehost" "$tree/secrets/hosts/fakehost"
      printf '{ kind = "linux"; system = "x86_64-linux"; }\n' >"$tree/hosts/fakehost/host.nix"
      printf '%s\n' "$host" >"$tree/secrets/bootstrap/fakehost/recipient.txt"
      local tokens_rule="$nixos,$host" tokens_file="$nixos,$host"
      local wifi_rule=$nixos wifi_file=$nixos tailscale_rule=$nixos printers_rule=$nixos printers_file=$nixos ssh=$host
      case $1 in
        second-recipient) ssh="$host,$nixos" ;;
        not-in-tokens-rule) tokens_rule=$nixos tokens_file=$nixos ;;
        tokens-not-rekeyed) tokens_file=$nixos ;;
        in-wifi-rule) wifi_rule="$nixos,$host" wifi_file="$nixos,$host" ;;
        in-wifi-rule-comma-space) wifi_rule="$nixos, $host" ;;
        in-tailscale-rule) tailscale_rule="$nixos,$host" ;;
        in-printers-rule) printers_rule="$nixos, $host" ;;
        wifi-file-only) wifi_file="$nixos,$host" ;;
        printers-file-only) printers_file="$nixos,$host" ;;
      esac
      printf 'creation_rules:\n  - path_regex: secrets/tokens\\.yaml$\n    age: %s\n  - path_regex: secrets/wifi\\.yaml$\n    age: %s\n  - path_regex: secrets/tailscale\\.yaml$\n    age: %s\n  - path_regex: secrets/printers\\.yaml$\n    age: %s\n' \
        "$tokens_rule" "$wifi_rule" "$tailscale_rule" "$printers_rule" >"$tree/.sops.yaml"
      encrypt "$tokens_file" "$tree/secrets/tokens.yaml"
      encrypt "$wifi_file" "$tree/secrets/wifi.yaml"
      encrypt "$tailscale_rule" "$tree/secrets/tailscale.yaml"
      encrypt "$printers_file" "$tree/secrets/printers.yaml"
      encrypt "$ssh" "$tree/secrets/hosts/fakehost/ssh.yaml"
      case $1 in
        missing-ssh) rm "$tree/secrets/hosts/fakehost/ssh.yaml" ;;
        missing-recipient) rm "$tree/secrets/bootstrap/fakehost/recipient.txt" ;;
      esac
      printf '%s\n' "$tree"
    }

    bash "$check" "$(make_tree valid)" || { echo 'a well-formed tree failed' >&2; exit 1; }

    # Each mutation must fail for its own reason, not for a neighbouring rule.
    expect_failure() {
      local mutation=$1 reason=$2
      if bash "$check" "$(make_tree "$mutation")" 2>err; then
        echo "linux-host-secrets passed a tree with mutation $mutation" >&2
        exit 1
      fi
      if ! grep -qF -- "$reason" err; then
        echo "linux-host-secrets failed mutation $mutation for another reason:" >&2
        cat err >&2
        exit 1
      fi
    }

    expect_failure second-recipient 'recipient alone'
    expect_failure missing-ssh 'ssh.yaml is missing'
    expect_failure missing-recipient 'recipient.txt is missing'
    expect_failure not-in-tokens-rule 'tokens.yaml rule'
    expect_failure tokens-not-rekeyed 'secrets/tokens.yaml is not encrypted to its recipient'
    expect_failure in-wifi-rule 'wifi.yaml rule'
    expect_failure in-wifi-rule-comma-space 'wifi.yaml rule'
    expect_failure in-tailscale-rule 'tailscale.yaml rule'
    expect_failure in-printers-rule 'printers.yaml rule'
    expect_failure wifi-file-only 'secrets/wifi.yaml is encrypted to its recipient'
    expect_failure printers-file-only 'secrets/printers.yaml is encrypted to its recipient'
    touch $out
  ''
