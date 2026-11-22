/*
  Check interface:

    import ./tests/user-identity-secrets.nix { inherit pkgs self; }

  Runs tests/user-identity-secrets.sh over the repository, then over fixture
  trees built here with fake keys, so each rule it enforces is proven to fail
  when broken even while hosts/ holds no Darwin host. Every tree holds a
  Darwin host and a NixOS host (a directory without host.nix), and encrypts
  its secret files to the recipients its .sops.yaml rules name, except where a
  mutation makes the two disagree:

  - a well-formed tree passes;
  - a host SSH file encrypted to a second recipient fails;
  - a NixOS host's per-host file encrypted to a second recipient, with its
    rule naming it too, fails, and a NixOS host without a recorded recipient fails;
  - a missing host SSH file, or a missing recorded recipient, fails;
  - a shared credential file missing, missing a recipient, or encrypted to
    an extra recipient fails;
  - a host recipient in the wifi.yaml, tailscale.yaml, or printers.yaml rule fails;
  - a wifi.yaml or printers.yaml encrypted to the host while its rule does not name it fails.
*/
{ pkgs, self }:
let
  inherit (pkgs) lib;
  credentials = lib.importJSON ../modules/shared/cli-credentials.json;
  groups = lib.unique (lib.mapAttrsToList (_: spec: spec.group) credentials);
in
pkgs.runCommand "user-identity-secrets-tests"
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
    check=${./user-identity-secrets.sh}

    check_tree() { bash "$check" "$1" ${lib.escapeShellArgs groups}; }

    age-keygen -o host.key 2>/dev/null
    age-keygen -o nixos.key 2>/dev/null
    age-keygen -o extra.key 2>/dev/null
    host=$(age-keygen -y host.key)
    nixos=$(age-keygen -y nixos.key)
    extra=$(age-keygen -y extra.key)
    printf 'value: fake\n' >plain.yaml

    encrypt() {
      sops --encrypt --age "$1" --input-type yaml --output-type yaml plain.yaml >"$2"
    }

    # A tree with one Darwin host and one NixOS host, plus the single mutation
    # named by $1. The NixOS host's recipient is the $nixos key.
    make_tree() {
      local tree=$TMPDIR/tree-$1
      mkdir -p "$tree/hosts/fakehost" "$tree/secrets/bootstrap/fakehost" "$tree/secrets/hosts/fakehost"
      mkdir -p "$tree/hosts/fakenixos" "$tree/secrets/bootstrap/fakenixos" "$tree/secrets/hosts/fakenixos"
      printf '{ kind = "darwin"; system = "aarch64-darwin"; }\n' >"$tree/hosts/fakehost/host.nix"
      printf '{ }\n' >"$tree/hosts/fakenixos/default.nix"
      printf '%s\n' "$host" >"$tree/secrets/bootstrap/fakehost/recipient.txt"
      printf '%s\n' "$nixos" >"$tree/secrets/bootstrap/fakenixos/recipient.txt"
      local git="$nixos,$host" services="$nixos,$host"
      local wifi_rule=$nixos wifi_file=$nixos tailscale_rule=$nixos printers_rule=$nixos printers_file=$nixos ssh=$host
      local nixos_wired_rule=$nixos nixos_wired_file=$nixos
      case $1 in
        second-recipient) ssh="$host,$nixos" ;;
        nixos-second-recipient) nixos_wired_rule="$nixos,$host" nixos_wired_file="$nixos,$host" ;;
        git-not-rekeyed) git=$nixos ;;
        extra-service-recipient) services="$nixos,$host,$extra" ;;
        in-wifi-rule) wifi_rule="$nixos,$host" wifi_file="$nixos,$host" ;;
        in-wifi-rule-comma-space) wifi_rule="$nixos, $host" ;;
        in-tailscale-rule) tailscale_rule="$nixos,$host" ;;
        in-printers-rule) printers_rule="$nixos, $host" ;;
        wifi-file-only) wifi_file="$nixos,$host" ;;
        printers-file-only) printers_file="$nixos,$host" ;;
      esac
      printf 'creation_rules:\n  - path_regex: secrets/git-hosting\\.yaml$\n    age: %s\n  - path_regex: secrets/provider-services\\.yaml$\n    age: %s\n  - path_regex: secrets/wifi\\.yaml$\n    age: %s\n  - path_regex: secrets/tailscale\\.yaml$\n    age: %s\n  - path_regex: secrets/printers\\.yaml$\n    age: %s\n  - path_regex: secrets/hosts/fakenixos/ssh\\.yaml$\n    age: %s\n  - path_regex: secrets/hosts/fakenixos/wired-network\\.yaml$\n    age: %s\n' \
        "$nixos,$host" "$nixos,$host" "$wifi_rule" "$tailscale_rule" "$printers_rule" "$nixos" "$nixos_wired_rule" >"$tree/.sops.yaml"
      encrypt "$git" "$tree/secrets/git-hosting.yaml"
      encrypt "$services" "$tree/secrets/provider-services.yaml"
      encrypt "$wifi_file" "$tree/secrets/wifi.yaml"
      encrypt "$tailscale_rule" "$tree/secrets/tailscale.yaml"
      encrypt "$printers_file" "$tree/secrets/printers.yaml"
      encrypt "$ssh" "$tree/secrets/hosts/fakehost/ssh.yaml"
      encrypt "$nixos" "$tree/secrets/hosts/fakenixos/ssh.yaml"
      encrypt "$nixos_wired_file" "$tree/secrets/hosts/fakenixos/wired-network.yaml"
      case $1 in
        missing-services) rm "$tree/secrets/provider-services.yaml" ;;
        missing-ssh) rm "$tree/secrets/hosts/fakehost/ssh.yaml" ;;
        missing-recipient) rm "$tree/secrets/bootstrap/fakehost/recipient.txt" ;;
        nixos-missing-recipient) rm "$tree/secrets/bootstrap/fakenixos/recipient.txt" ;;
      esac
      printf '%s\n' "$tree"
    }

    check_tree "$(make_tree valid)" || { echo 'a well-formed tree failed' >&2; exit 1; }

    # Each mutation must fail for its own reason, not for a neighbouring rule.
    expect_failure() {
      local mutation=$1 reason=$2
      if check_tree "$(make_tree "$mutation")" 2>err; then
        echo "user-identity-secrets passed a tree with mutation $mutation" >&2
        exit 1
      fi
      if ! grep -qF -- "$reason" err; then
        echo "user-identity-secrets failed mutation $mutation for another reason:" >&2
        cat err >&2
        exit 1
      fi
    }

    expect_failure second-recipient 'fakehost: secrets/hosts/fakehost/ssh.yaml must be encrypted to this host'
    expect_failure nixos-second-recipient 'fakenixos: secrets/hosts/fakenixos/wired-network.yaml must be encrypted to this host'
    expect_failure nixos-missing-recipient 'fakenixos: secrets/bootstrap/fakenixos/recipient.txt is missing'
    expect_failure missing-ssh 'ssh.yaml is missing'
    expect_failure missing-recipient 'recipient.txt is missing'
    expect_failure git-not-rekeyed 'secrets/git-hosting.yaml is not encrypted to exactly the recorded bootstrap recipients'
    expect_failure extra-service-recipient 'secrets/provider-services.yaml is not encrypted to exactly the recorded bootstrap recipients'
    expect_failure missing-services 'secrets/provider-services.yaml is missing'
    expect_failure in-wifi-rule 'wifi.yaml rule'
    expect_failure in-wifi-rule-comma-space 'wifi.yaml rule'
    expect_failure in-tailscale-rule 'tailscale.yaml rule'
    expect_failure in-printers-rule 'printers.yaml rule'
    expect_failure wifi-file-only 'secrets/wifi.yaml is encrypted to its recipient'
    expect_failure printers-file-only 'secrets/printers.yaml is encrypted to its recipient'
    echo 'user-identity-secrets: fake recipient checks passed'
    check_tree ${self}
    touch $out
  ''
