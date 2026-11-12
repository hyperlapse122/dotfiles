/*
  Fake secrets for the non-NixOS fixture hosts, generated at build time. Every
  value here is deliberately public test material; production never embeds a
  real key or token in the store.

    fakeSecrets = import ./lib/fake-secrets.nix { inherit pkgs; };

  Outputs:
  - key.txt: the fixture's age identity; tokens.yaml and ssh.yaml are
    encrypted to it alone.
  - other-key.txt: a valid age identity that is not a recipient of either file.
  - recipient.txt: the public recipient of key.txt.
  - tokens.yaml: the token schema from secrets/README.md. The Tokscale token
    and the Synthetic API key carry a space and the canary FAKE-CANARY, so a
    publisher that starts reading either fails, and any log that prints a
    token is caught.
  - ssh.yaml: `ssh_private_key`, a fresh ed25519 key; ssh.pub is its public
    half, for asserting what was published.
  - tls-inspection-ca.yaml: `certificate`, a fresh self-signed CA whose PEM
    is tls-inspection-ca.pem. tls-inspection-ca-other.yaml holds the same CA
    for other-key.txt only; tls-inspection-ca-key.yaml, -two.yaml, and
    -leaf.yaml hold a private key, two certificates, and a non-CA certificate.
  - wired-network.yaml: `mac`, `ipv4_address`, `ipv4_subnet_mask`,
    `ipv4_router`, and `dns_servers` in documentation address ranges.
    wired-network-other.yaml holds the same values for other-key.txt only;
    -no-router.yaml lacks `ipv4_router`, -no-dns.yaml has no DNS servers,
    -bad-mask.yaml has a non-contiguous subnet mask, and -bad-dns.yaml has a
    DNS entry that is not an address. Each of these alone differs from the
    valid file: -router-outside.yaml has a router outside the address's
    network, -ipv6-dns.yaml has an IPv6 DNS server, -prefix-0.yaml,
    -prefix-31.yaml, and -prefix-32.yaml have a /0, a /31, and a /32 subnet
    mask, and
    -bad-mac.yaml has a malformed MAC address.
*/
{ pkgs }:
pkgs.runCommand "fake-non-nixos-secrets"
  {
    nativeBuildInputs = [
      pkgs.age
      pkgs.sops
      pkgs.openssh
      pkgs.yq-go
      pkgs.openssl
    ];
  }
  ''
    mkdir -p $out
    age-keygen -o $out/key.txt 2>/dev/null
    age-keygen -o $out/other-key.txt 2>/dev/null
    recipient=$(age-keygen -y $out/key.txt)
    printf '%s\n' "$recipient" > $out/recipient.txt

    printf 'github_token: FAKE-CANARY-github\ngitlab_token: FAKE-CANARY-gitlab\njpi_token: FAKE-CANARY-jpi\ntokscale_token: FAKE-CANARY tokscale\nsynthetic_api_key: FAKE-CANARY pi\nexa_api_key: FAKE-CANARY exa\nopenrouter_api_key: FAKE-CANARY openrouter\n' > tokens.yaml
    sops --encrypt --age "$recipient" --input-type yaml --output-type yaml tokens.yaml > $out/tokens.yaml

    ssh-keygen -q -t ed25519 -N "" -C fake-non-nixos-host -f ssh_key
    cp ssh_key.pub $out/ssh.pub
    key="$(cat ssh_key)" yq -n '.ssh_private_key = strenv(key) + "\n"' > ssh.yaml
    sops --encrypt --age "$recipient" --input-type yaml --output-type yaml ssh.yaml > $out/ssh.yaml

    # Failure fixtures: the same SSH key encrypted to the other identity only,
    # tokens whose github_token publish-cli-auth rejects, tokens that lack
    # openrouter_api_key, and an SSH key field that is not a private key.
    other=$(age-keygen -y $out/other-key.txt)
    sops --encrypt --age "$other" --input-type yaml --output-type yaml ssh.yaml > $out/ssh-other.yaml
    printf 'github_token: FAKE-CANARY has spaces\ngitlab_token: FAKE-CANARY-gitlab\njpi_token: FAKE-CANARY-jpi\ntokscale_token: FAKE-CANARY tokscale\nsynthetic_api_key: FAKE-CANARY pi\nexa_api_key: FAKE-CANARY exa\nopenrouter_api_key: FAKE-CANARY openrouter\n' > bad-tokens.yaml
    sops --encrypt --age "$recipient" --input-type yaml --output-type yaml bad-tokens.yaml > $out/tokens-invalid.yaml
    grep -v '^openrouter_api_key:' tokens.yaml > short-tokens.yaml
    sops --encrypt --age "$recipient" --input-type yaml --output-type yaml short-tokens.yaml > $out/tokens-missing.yaml
    printf 'ssh_private_key: not a key\n' > bad-ssh.yaml
    sops --encrypt --age "$recipient" --input-type yaml --output-type yaml bad-ssh.yaml > $out/ssh-invalid.yaml

    # A self-signed CA standing in for the TLS inspection CA, and failure
    # fixtures: the same CA for the other identity only, a private key, two
    # certificates, and a certificate that is not a CA.
    ca() {
      openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
        -keyout "$1.key" -out "$1.pem" -days 3650 -subj "/CN=$1" -addext "basicConstraints=critical,$2" 2>/dev/null
    }
    ca fake-inspection-ca CA:TRUE
    ca fake-leaf CA:FALSE
    cp fake-inspection-ca.pem $out/tls-inspection-ca.pem
    caYaml() { cert="$(cat "$1")" yq -n '.certificate = strenv(cert) + "\n"'; }
    caYaml fake-inspection-ca.pem > ca.yaml
    sops --encrypt --age "$recipient" --input-type yaml --output-type yaml ca.yaml > $out/tls-inspection-ca.yaml
    sops --encrypt --age "$other" --input-type yaml --output-type yaml ca.yaml > $out/tls-inspection-ca-other.yaml
    caYaml fake-inspection-ca.key > ca-key.yaml
    sops --encrypt --age "$recipient" --input-type yaml --output-type yaml ca-key.yaml > $out/tls-inspection-ca-key.yaml
    cat fake-inspection-ca.pem fake-leaf.pem > two.pem
    caYaml two.pem > ca-two.yaml
    sops --encrypt --age "$recipient" --input-type yaml --output-type yaml ca-two.yaml > $out/tls-inspection-ca-two.yaml
    caYaml fake-leaf.pem > ca-leaf.yaml
    sops --encrypt --age "$recipient" --input-type yaml --output-type yaml ca-leaf.yaml > $out/tls-inspection-ca-leaf.yaml

    # The wired network declaration in documentation address ranges with a
    # locally administered MAC, and failure fixtures: the same file for the
    # other identity only, and the variants below. The prefix variants put the router on the address itself, so the router stays
    # inside whatever network the mask makes and only the mask is wrong.
    wired() {
      mask=255.255.255.0
      router=192.0.2.1
      mac='02:00:5E:00:53:01'
      dns='  - 198.51.100.20\n  - 198.51.100.21\n'
      case $1 in
        bad-mask) mask=255.0.255.0 ;;
        router-outside) router=203.0.113.1 ;;
        prefix-0) mask=0.0.0.0; router=192.0.2.100 ;;
        prefix-31) mask=255.255.255.254; router=192.0.2.100 ;;
        prefix-32) mask=255.255.255.255; router=192.0.2.100 ;;
        bad-mac) mac='02:00:5E:00:53:0G' ;;
        ipv6-dns) dns='  - 198.51.100.20\n  - 2001:db8::53\n' ;;
        bad-dns) dns='  - 198.51.100.20\n  - not-an-address\n' ;;
      esac
      printf 'mac: %s\nipv4_address: 192.0.2.100\nipv4_subnet_mask: %s\n' "$mac" "$mask"
      [ "$1" = no-router ] || printf 'ipv4_router: %s\n' "$router"
      if [ "$1" = no-dns ]; then
        printf 'dns_servers: []\n'
      else
        printf 'dns_servers:\n'
        printf "$dns"
      fi
    }
    wired full > wired.yaml
    sops --encrypt --age "$recipient" --input-type yaml --output-type yaml wired.yaml > $out/wired-network.yaml
    sops --encrypt --age "$other" --input-type yaml --output-type yaml wired.yaml > $out/wired-network-other.yaml
    for variant in no-router no-dns bad-mask bad-dns router-outside ipv6-dns prefix-0 prefix-31 prefix-32 bad-mac; do
      wired $variant > wired-$variant.yaml
      sops --encrypt --age "$recipient" --input-type yaml --output-type yaml wired-$variant.yaml > $out/wired-network-$variant.yaml
    done
  ''
