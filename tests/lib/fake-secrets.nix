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
  ''
