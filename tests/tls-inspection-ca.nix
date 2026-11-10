/*
  Check interface:

    import ./tests/tls-inspection-ca.nix { inherit pkgs; }

  Runs the packaged scripts/tls-inspection-ca against the fake CA from
  tests/lib/fake-secrets.nix, with `launchctl` and `security` stubbed on PATH
  as macOS provides them at activation:

  - `bundle` with an identity that is not a recipient, with no identity, a
    symlinked identity, or one with a loose mode fails, names the cause, and
    leaves an existing bundle byte-identical;
  - a decrypted private key, two certificates, or a non-CA certificate fails
    validation and writes nothing;
  - with the right identity, the bundle is the given base followed by the CA,
    both files are 0644 in a 0755 directory, and no run prints the CA body;
  - nix-daemon is restarted only when the bundle changed and the daemon is
    loaded;
  - `trust` adds nothing when the admin trust settings make the CA an SSL
    root and SSL verification passes; it adds SSL-only admin trust when the
    entry is missing, grants only another policy, or SSL verification fails;
    a failed add or a missing `security` warns and exits 0.
*/
{ pkgs }:
let
  secrets = import ./lib/fake-secrets.nix { inherit pkgs; };
  tool = import ../packages/tls-inspection-ca.nix { inherit pkgs; };
in
pkgs.runCommand "tls-inspection-ca-tests"
  {
    nativeBuildInputs = [
      tool
      pkgs.openssl
      pkgs.python3
    ];
  }
  ''
    fail() { echo "tls-inspection-ca: FAIL: $*" >&2; exit 1; }
    pass() { echo "tls-inspection-ca: ok - $*"; }
    cd "$TMPDIR"

    # Stubs for the macOS commands. Each appends its arguments to calls.log;
    # files under $TMPDIR/state choose their answers.
    mkdir -p stubs state
    cat >stubs/launchctl <<'SH'
    #!/bin/sh
    echo "launchctl $*" >>"$TMPDIR/calls.log"
    case $1 in print) [ -e "$TMPDIR/state/daemon-loaded" ] ;; esac
    SH
    cat >stubs/security <<'SH'
    #!/bin/sh
    echo "security $*" >>"$TMPDIR/calls.log"
    case $1 in
      trust-settings-export) cp "$TMPDIR/state/admin.plist" "$3" ;;
      verify-cert) [ -e "$TMPDIR/state/verify-ok" ] ;;
      add-trusted-cert) [ -e "$TMPDIR/state/add-ok" ] ;;
    esac
    SH
    chmod +x stubs/*
    export PATH=$PWD/stubs:$PATH

    owner=$(id -un)
    install -D -m 600 ${secrets}/key.txt key/key.txt
    install -D -m 600 ${secrets}/other-key.txt other/key.txt
    printf 'BASE ROOTS\n' >base.crt
    body=$(sed -n 2p ${secrets}/tls-inspection-ca.pem)

    run_bundle() {
      tls-inspection-ca bundle --certificate-file "$1" --identity "$2" --identity-owner "$owner" \
        --base "$3" --out-dir "$TMPDIR/out" --daemon org.nixos.nix-daemon
    }

    # --- a first bundle -------------------------------------------------------
    : >calls.log
    touch state/daemon-loaded
    run_bundle ${secrets}/tls-inspection-ca.yaml key/key.txt base.crt >out.log 2>err.log ||
      fail "bundle failed with the right identity: $(cat err.log)"
    cat base.crt ${secrets}/tls-inspection-ca.pem >expected.crt
    cmp -s expected.crt out/ca-certificates.crt || fail 'the bundle is not the base followed by the CA'
    cmp -s ${secrets}/tls-inspection-ca.pem out/tls-inspection-ca.pem || fail 'the CA file is not the decrypted CA'
    [ "$(stat -c %a out)" = 755 ] || fail 'the bundle directory is not 0755'
    [ "$(stat -c %a out/ca-certificates.crt)" = 644 ] || fail 'the bundle is not 0644'
    [ "$(stat -c %a out/tls-inspection-ca.pem)" = 644 ] || fail 'the CA file is not 0644'
    if grep -qF "$body" out.log err.log; then fail 'bundle printed the CA'; fi
    grep -qx 'launchctl kickstart -k system/org.nixos.nix-daemon' calls.log ||
      fail 'a new bundle did not restart the loaded daemon'
    pass 'bundle writes the base followed by the CA, privately readable by all, and restarts the daemon'

    # --- unchanged inputs, then a new base ------------------------------------
    : >calls.log
    run_bundle ${secrets}/tls-inspection-ca.yaml key/key.txt base.crt 2>err.log || fail "second bundle failed: $(cat err.log)"
    if grep -q kickstart calls.log; then fail 'an unchanged bundle restarted the daemon'; fi
    printf 'NEW BASE ROOTS' >new-base.crt
    run_bundle ${secrets}/tls-inspection-ca.yaml key/key.txt new-base.crt 2>err.log || fail "new-base bundle failed: $(cat err.log)"
    { printf 'NEW BASE ROOTS\n'; cat ${secrets}/tls-inspection-ca.pem; } >expected.crt
    cmp -s expected.crt out/ca-certificates.crt || fail 'the bundle does not start with the given base'
    [ "$(grep -c kickstart calls.log)" = 1 ] || fail 'a changed bundle did not restart the daemon once'
    : >calls.log; rm -f state/daemon-loaded
    printf 'THIRD BASE\n' >third-base.crt
    run_bundle ${secrets}/tls-inspection-ca.yaml key/key.txt third-base.crt 2>err.log || fail "third bundle failed: $(cat err.log)"
    if grep -q kickstart calls.log; then fail 'bundle restarted a daemon that is not loaded'; fi
    pass 'bundle restarts nix-daemon only when the bundle changed and the daemon is loaded'

    # --- failures leave the previous bundle ------------------------------------
    cp out/ca-certificates.crt previous.crt
    cp out/tls-inspection-ca.pem previous.pem
    expect_failure() {
      if run_bundle "$1" "$2" base.crt >out.log 2>err.log; then fail "bundle succeeded: $3"; fi
      grep -q "$4" err.log || fail "$3 is not explained: $(cat err.log)"
      if grep -qF "$body" out.log err.log; then fail "$3: bundle printed the CA"; fi
      cmp -s previous.crt out/ca-certificates.crt || fail "$3: the bundle changed"
      cmp -s previous.pem out/tls-inspection-ca.pem || fail "$3: the CA file changed"
    }
    expect_failure ${secrets}/tls-inspection-ca.yaml other/key.txt 'a foreign identity' 'not a recipient'
    expect_failure ${secrets}/tls-inspection-ca-other.yaml key/key.txt 'a file for another host' 'not a recipient'
    expect_failure ${secrets}/tls-inspection-ca.yaml missing/key.txt 'no identity' 'no age identity at'
    install -D -m 600 ${secrets}/key.txt real/key.txt
    mkdir -p linked
    ln -s "$PWD/real/key.txt" linked/key.txt
    expect_failure ${secrets}/tls-inspection-ca.yaml linked/key.txt 'a symlinked identity' 'no age identity at'
    install -D -m 644 ${secrets}/key.txt loose/key.txt
    expect_failure ${secrets}/tls-inspection-ca.yaml loose/key.txt 'a loose identity' 'mode 0600'
    expect_failure ${secrets}/tls-inspection-ca-key.yaml key/key.txt 'a private key' 'not exactly one certificate'
    expect_failure ${secrets}/tls-inspection-ca-two.yaml key/key.txt 'two certificates' 'not exactly one certificate'
    expect_failure ${secrets}/tls-inspection-ca-leaf.yaml key/key.txt 'a leaf certificate' 'not a CA'
    pass 'every bundle failure names its cause and leaves the previous files'

    # --- trust -----------------------------------------------------------------
    hash=$(openssl x509 -in ${secrets}/tls-inspection-ca.pem -noout -fingerprint -sha1 | sed 's/^.*=//; s/://g')
    # admin_plist HASH SETTING... writes the admin trust settings for HASH, one
    # entry per SETTING: a policy name for a trustRoot grant on that policy,
    # "any" for an unconstrained trustRoot grant, "empty" for an empty
    # dictionary, or "deny-ssl" for an SSL deny; no SETTING means no entries.
    admin_plist() {
      python3 - "$@" <<'PY'
    import plistlib, sys
    def setting(p):
        if p == "any":
            return {"kSecTrustSettingsResult": 1}
        if p == "empty":
            return {}
        if p == "deny-ssl":
            return {"kSecTrustSettingsPolicyName": "sslServer", "kSecTrustSettingsResult": 3}
        return {"kSecTrustSettingsPolicyName": p, "kSecTrustSettingsResult": 1}
    settings = [setting(p) for p in sys.argv[2:]]
    with open("state/admin.plist", "wb") as f:
        plistlib.dump({"trustVersion": 1, "trustList": {sys.argv[1]: {"trustSettings": settings}}}, f)
    PY
    }
    run_trust() {
      : >calls.log
      tls-inspection-ca trust --certificate ${secrets}/tls-inspection-ca.pem >out.log 2>err.log ||
        fail "trust exited non-zero: $(cat err.log)"
    }
    added() { grep -q '^security add-trusted-cert' calls.log; }

    admin_plist "$hash" sslServer SMIME
    touch state/verify-ok state/add-ok
    run_trust
    if added; then fail 'trust added trust the admin settings already grant'; fi
    [ ! -s out.log ] && [ ! -s err.log ] || fail 'trust printed output when trust was present'
    for unconstrained in "" any empty; do
      admin_plist "$hash" $unconstrained
      run_trust
      if added; then fail "trust added trust over an unconstrained admin entry ($unconstrained)"; fi
    done
    pass 'trust adds nothing when the admin settings make the CA an SSL root'

    admin_plist 0000000000000000000000000000000000000000 sslServer
    run_trust
    added || fail 'trust did not add trust for a CA without an admin entry'
    grep -qx "security add-trusted-cert -d -r trustRoot -p ssl -k /Library/Keychains/System.keychain ${secrets}/tls-inspection-ca.pem" calls.log ||
      fail "trust did not add SSL-only admin trust: $(cat calls.log)"
    admin_plist "$hash" SMIME
    run_trust
    added || fail 'trust did not add trust for an entry that grants only S/MIME'
    admin_plist "$hash" any deny-ssl
    run_trust
    added || fail 'trust did not add trust for an entry that denies SSL'
    admin_plist "$hash" sslServer
    rm state/verify-ok
    run_trust
    added || fail 'trust did not add trust when SSL verification fails'
    pass 'trust adds SSL-only admin trust when the entry is missing, grants another policy, or fails verification'

    rm state/add-ok
    run_trust
    grep -q 'run security add-trusted-cert' err.log || fail "a failed add does not name the manual command: $(cat err.log)"
    PATH=${tool}/bin:/no-such-dir tls-inspection-ca trust --certificate ${secrets}/tls-inspection-ca.pem 2>err.log ||
      fail 'trust failed without security on PATH'
    grep -q 'security is not on PATH' err.log || fail "a missing security is not explained: $(cat err.log)"
    pass 'trust warns and exits 0 when adding fails or security is missing'

    touch $out
  ''
