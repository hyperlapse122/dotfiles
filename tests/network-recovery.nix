/*
  Check interface:

    import ./tests/network-recovery.nix { inherit pkgs; }

  Runs the packaged scripts/network-recovery against PATH stubs for the macOS
  tools and curl. Answer files under the case directory choose command
  output. Each scenario is one run of the recovery flowchart.
*/
{ pkgs }:
let
  tool = import ../packages/network-recovery.nix { inherit pkgs; };
in
pkgs.runCommand "network-recovery-tests"
  {
    nativeBuildInputs = [
      tool
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.gnused
    ];
  }
  ''
    set -euo pipefail
    fail() {
      echo "network-recovery: FAIL: $*" >&2
      if [ -n "''${CASE:-}" ]; then
        echo "--- out ---" >&2
        cat "$CASE/out.log" >&2 || true
        echo "--- err ---" >&2
        cat "$CASE/err.log" >&2 || true
        echo "--- calls ---" >&2
        cat "$CALLS" >&2 || true
      fi
      exit 1
    }
    pass() { echo "network-recovery: ok - $*"; }

    BIN=${tool}/bin/network-recovery
    SUCCESS='<HTML><HEAD><TITLE>Success</TITLE></HEAD><BODY>Success</BODY></HTML>'
    CASE=
    CALLS=
    ANSWERS=
    VAR=

    write_stub() {
      name=$1
      sed \
        -e "s|@CALLS@|$CALLS|g" \
        -e "s|@ANSWERS@|$ANSWERS|g" \
        -e "s|@VAR@|$VAR|g" \
        -e "s|@STUBDIR@|$CASE/stubs|g" \
        > "$CASE/stubs/$name"
      chmod +x "$CASE/stubs/$name"
    }

    install_stubs() {
      write_stub _log <<'SH'
    log_call() {
      printf '%s' "$1" >> "@CALLS@"
      shift
      for a in "$@"; do
        printf ' [%s]' "$a" >> "@CALLS@"
      done
      printf '\n' >> "@CALLS@"
    }
    SH
      write_stub route <<'SH'
    #!/bin/sh
    . "@STUBDIR@/_log"
    log_call route "$@"
    if [ -f "@ANSWERS@/route" ]; then
      cat "@ANSWERS@/route"
    fi
    if [ -f "@ANSWERS@/route-status" ]; then
      exit "$(cat "@ANSWERS@/route-status")"
    fi
    exit 0
    SH
      write_stub arp <<'SH'
    #!/bin/sh
    . "@STUBDIR@/_log"
    log_call arp "$@"
    cat "@ANSWERS@/arp"
    exit 0
    SH
      write_stub ifconfig <<'SH'
    #!/bin/sh
    . "@STUBDIR@/_log"
    log_call ifconfig "$@"
    cat "@ANSWERS@/ifconfig"
    exit 0
    SH
      write_stub scutil <<'SH'
    #!/bin/sh
    . "@STUBDIR@/_log"
    log_call scutil "$@"
    cat "@ANSWERS@/scutil"
    exit 0
    SH
      write_stub curl <<'SH'
    #!/bin/sh
    . "@STUBDIR@/_log"
    log_call curl "$@"
    if [ -f "@ANSWERS@/slow-repair" ]; then sleep 5; fi
    phase=0
    if [ -f "@VAR@/phase" ]; then
      phase=$(cat "@VAR@/phase")
    fi
    ans="@ANSWERS@/http-$phase"
    if [ ! -f "$ans" ]; then
      ans="@ANSWERS@/http-0"
    fi
    if [ "$(cat "$ans")" = "FAIL" ]; then
      printf 'RAW_MARKER CafeSSID\n'
      exit 1
    fi
    cat "$ans"
    exit 0
    SH
      write_stub dscacheutil <<'SH'
    #!/bin/sh
    . "@STUBDIR@/_log"
    log_call dscacheutil "$@"
    if [ "$1" = "-flushcache" ]; then
      if [ -f "@ANSWERS@/slow-repair" ]; then sleep 60; fi
      printf 'flushed\n' > "@VAR@/phase"
      exit 0
    fi
    phase=0
    if [ -f "@VAR@/phase" ]; then
      phase=$(cat "@VAR@/phase")
    fi
    ans="@ANSWERS@/dns-$phase"
    if [ ! -f "$ans" ]; then
      ans="@ANSWERS@/dns-0"
    fi
    if [ "$(cat "$ans")" = "FAIL" ]; then
      printf 'RAW_MARKER 198.51.100.20\n'
      exit 1
    fi
    cat "$ans"
    exit 0
    SH
      write_stub nc <<'SH'
    #!/bin/sh
    . "@STUBDIR@/_log"
    log_call nc "$@"
    phase=0
    if [ -f "@VAR@/phase" ]; then
      phase=$(cat "@VAR@/phase")
    fi
    ans="@ANSWERS@/ip-$phase"
    if [ ! -f "$ans" ]; then
      ans="@ANSWERS@/ip-0"
    fi
    mode=$(cat "$ans")
    if [ "$mode" = "fail" ]; then
      exit 1
    fi
    if [ "$mode" = "second" ]; then
      case " $* " in
        *" 1.1.1.1 "*) exit 1 ;;
      esac
    fi
    exit 0
    SH
      write_stub killall <<'SH'
    #!/bin/sh
    . "@STUBDIR@/_log"
    log_call killall "$@"
    if [ -f "@ANSWERS@/slow-repair" ]; then sleep 60; fi
    exit 0
    SH
      write_stub networksetup <<'SH'
    #!/bin/sh
    . "@STUBDIR@/_log"
    log_call networksetup "$@"
    case $1 in
      -listnetworkserviceorder)
        if [ -f "@ANSWERS@/slow-discovery" ]; then sleep 60; fi
        cat "@ANSWERS@/services"
        ;;
      -listallhardwareports)
        cat "@ANSWERS@/ports"
        ;;
      -setairportpower|-setnetworkserviceenabled)
        action=$3
        if [ ! -s "@VAR@/pending-service" ]; then
          printf 'MISSING_PENDING %s\n' "$action" >> "@VAR@/pending-trace"
        else
          printf 'HAD_PENDING %s\n' "$action" >> "@VAR@/pending-trace"
        fi
        if [ "$action" = "on" ]; then
          if [ -f "@ANSWERS@/on-fail" ]; then exit 1; fi
          printf 'cycled\n' > "@VAR@/phase"
        fi
        ;;
    esac
    exit 0
    SH
      write_stub launchctl <<'SH'
    #!/bin/sh
    . "@STUBDIR@/_log"
    log_call launchctl "$@"
    if [ "$1" = "asuser" ]; then
      shift 2
      "$@"
      exit $?
    fi
    exit 0
    SH
      write_stub sudo <<'SH'
    #!/bin/sh
    . "@STUBDIR@/_log"
    log_call sudo "$@"
    if [ "$1" = "-u" ]; then
      shift 2
      "$@"
      exit $?
    fi
    exit 0
    SH
      write_stub tailscale <<'SH'
    #!/bin/sh
    . "@STUBDIR@/_log"
    log_call tailscale "$@"
    case $1 in
      status)
        cat "@ANSWERS@/tailscale-status"
        exit 0
        ;;
      down)
        if [ "$(cat "@VAR@/pending-tailscale" 2>/dev/null)" = "$(printf 'testuser\n501')" ]; then
          printf 'HAD_PENDING down\n' >> "@VAR@/pending-tailscale-trace"
        else
          printf 'MISSING_PENDING down\n' >> "@VAR@/pending-tailscale-trace"
        fi
        exit 0
        ;;
      up)
        if [ -f "@ANSWERS@/up-fail" ]; then
          exit 1
        fi
        if [ -f "@ANSWERS@/up-needs-cycle" ]; then
          [ "$(cat "@VAR@/phase" 2>/dev/null)" = cycled ] || exit 1
        else
          printf 'tailscale\n' > "@VAR@/phase"
        fi
        exit 0
        ;;
    esac
    exit 0
    SH
    }

    setup_case() {
      CASE=$TMPDIR/case-$1
      rm -rf "$CASE"
      mkdir -p "$CASE/stubs" "$CASE/answers" "$CASE/var"
      CALLS=$CASE/calls.log
      ANSWERS=$CASE/answers
      VAR=$CASE/var
      : > "$CALLS"
      install_stubs
      cat > "$ANSWERS/route" <<'EOF'
    route to: default
    destination: default
           mask: default
        gateway: 203.0.113.1
      interface: en0
          flags: <UP,GATEWAY,DONE,STATIC,PRCLONING>
    ssid CafeSSID
    RAW_MARKER
    EOF
      cat > "$ANSWERS/arp" <<'EOF'
    ? (203.0.113.1) at 02:00:5e:00:53:01 on en0 ifscope [ethernet]
    RAW_MARKER
    EOF
      cat > "$ANSWERS/ifconfig" <<'EOF'
    en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
      inet 203.0.113.50 netmask 0xffffff00 broadcast 203.0.113.255
      ether 0a:1b:2c:3d:4e:5f
    ssid CafeSSID
    RAW_MARKER
    EOF
      cat > "$ANSWERS/scutil" <<'EOF'
    <dictionary> {
      GID : 20
      Name : testuser
      UID : 501
    }
    EOF
      cat > "$ANSWERS/services" <<'EOF'
    An asterisk (*) denotes that a network service is disabled.
    (1) Wi-Fi
    (Hardware Port: Wi-Fi, Device: en0)

    EOF
      cat > "$ANSWERS/ports" <<'EOF'
    Hardware Port: Wi-Fi
    Device: en0
    Ethernet Address: 0a:1b:2c:3d:4e:5f

    EOF
      cat > "$ANSWERS/tailscale-status" <<'EOF'
    {"BackendState":"Running","TailscaleIPs":["100.64.0.7"],"Self":{"DNSName":"host.tailnet.ts.net"}}
    EOF
      printf '%s\n' "$SUCCESS" > "$ANSWERS/http-0"
      cat > "$ANSWERS/dns-0" <<'EOF'
    name: example.com
    ip_address: 198.51.100.20
    EOF
      printf 'second\n' > "$ANSWERS/ip-0"
    }

    set_http() { printf '%s\n' "$2" > "$ANSWERS/http-$1"; }
    set_dns_ok() {
      cat > "$ANSWERS/dns-$1" <<'EOF'
    name: example.com
    ip_address: 198.51.100.20
    EOF
    }
    set_dns_fail() { printf 'FAIL\n' > "$ANSWERS/dns-$1"; }
    set_ip() { printf '%s\n' "$2" > "$ANSWERS/ip-$1"; }
    set_all_fail() {
      printf 'FAIL\n' > "$ANSWERS/http-0"
      printf 'FAIL\n' > "$ANSWERS/dns-0"
      printf 'fail\n' > "$ANSWERS/ip-0"
    }
    pass_from() {
      set_http "$1" "$SUCCESS"
      set_dns_ok "$1"
      set_ip "$1" second
    }
    set_stopped() {
      printf '%s\n' '{"BackendState":"Stopped","TailscaleIPs":["100.64.0.7"]}' > "$ANSWERS/tailscale-status"
    }
    set_loginwindow() {
      cat > "$ANSWERS/scutil" <<'EOF'
    <dictionary> {
      Name : loginwindow
      UID : 0
    }
    EOF
    }

    assert_clean_log() {
      marker=$1
      if grep -qF "$marker" "$CASE/out.log" "$CASE/err.log"; then
        fail "log contains $marker"
      fi
    }
    assert_logs_clean() {
      assert_clean_log CafeSSID
      assert_clean_log 203.0.113.1
      assert_clean_log 203.0.113.50
      assert_clean_log 203.0.113.9
      assert_clean_log 198.51.100.20
      assert_clean_log 02:00:5e:00:53:01
      assert_clean_log 0a:1b:2c:3d:4e:5f
      assert_clean_log 0a:1b:2c:3d:4e:60
      assert_clean_log 100.64.0.7
      assert_clean_log 1.1.1.1
      assert_clean_log 8.8.8.8
      assert_clean_log host.tailnet.ts.net
      assert_clean_log RAW_MARKER
      assert_clean_log PORTAL_BODY_MARKER
      while IFS= read -r line; do
        case $line in
          [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z\ *) ;;
          *) fail "log line has no UTC timestamp: $line" ;;
        esac
      done < "$CASE/out.log"
    }
    assert_no_repair() {
      label=$1
      if grep -qF '[-flushcache]' "$CALLS"; then fail "$label: flushed dns"; fi
      if grep -qF 'killall' "$CALLS"; then fail "$label: signaled a process"; fi
      if grep -qF 'tailscale [down]' "$CALLS"; then fail "$label: tailscale down"; fi
      if grep -qF 'tailscale [up]' "$CALLS"; then fail "$label: tailscale up"; fi
      if grep -qF '[-setairportpower]' "$CALLS"; then fail "$label: airport"; fi
      if grep -qF '[-setnetworkserviceenabled]' "$CALLS"; then fail "$label: service"; fi
    }
    assert_tailscale_toggle() {
      grep -qx 'HAD_PENDING down' "$CASE/var/pending-tailscale-trace" || fail "no restore record before Tailscale down"
      down="launchctl [asuser] [501] [sudo] [-u] [testuser] [$CASE/stubs/tailscale] [down]"
      up="launchctl [asuser] [501] [sudo] [-u] [testuser] [$CASE/stubs/tailscale] [up]"
      grep -qF "$down" "$CALLS" || fail "tailscale down was not run as the console user: $(cat "$CALLS")"
      grep -qF "$up" "$CALLS" || fail "tailscale up was not run as the console user: $(cat "$CALLS")"
      if grep -qF 'tailscale [down] [' "$CALLS"; then fail "tailscale down had flags"; fi
      if grep -qF 'tailscale [up] [' "$CALLS"; then fail "tailscale up had flags"; fi
      grep -Fqx 'tailscale [down]' "$CALLS" || fail "tailscale down arguments were not exactly down"
      grep -Fqx 'tailscale [up]' "$CALLS" || fail "tailscale up arguments were not exactly up"
    }

    run_case() {
      : > "$CALLS"
      PATH="$CASE/stubs:$PATH" "$BIN" --state-dir "$CASE/var" --tailscale "$CASE/stubs/tailscale" > "$CASE/out.log" 2> "$CASE/err.log" || fail "exit status $?"
      if [ -s "$CASE/err.log" ]; then
        fail "stderr was not empty"
      fi
      assert_logs_clean
    }

    # A failing check waits out the 10-second grace on the run that opens the
    # episode; the next run, with the episode aged past it, repairs.
    run_in_grace() {
      run_case
      grep -qF 'repair wait grace' "$CASE/out.log" || fail "the run that opened the episode did not wait out the grace"
      assert_no_repair "grace"
    }
    age_episode() {
      started=$(sed -n 's/^started_at=//p' "$CASE/var/episode")
      sed "s/^started_at=.*/started_at=$((started - 20))/" "$CASE/var/episode" > "$CASE/var/episode.new"
      mv "$CASE/var/episode.new" "$CASE/var/episode"
    }
    run_past_grace() {
      run_in_grace
      age_episode
      run_case
    }

    # --- AE1 -------------------------------------------------------------------
    setup_case ae1
    run_case
    grep -qF 'check pass' "$CASE/out.log" || fail "AE1: log did not record a passing check"
    grep -qF 'http://captive.apple.com/hotspot-detect.html' "$CALLS" || fail "AE1: HTTP check did not request the captive URL"
    grep -qF '[--noproxy]' "$CALLS" || fail "AE1: HTTP check did not ignore proxies"
    grep -qF '[-q] [host] [-a] [name] [example.com]' "$CALLS" || fail "AE1: DNS check did not resolve example.com"
    grep -qF '[1.1.1.1]' "$CALLS" || fail "AE1: did not try the first resolver"
    grep -qF '[8.8.8.8]' "$CALLS" || fail "AE1: did not try the second resolver after the first failed"
    assert_no_repair AE1
    pass "AE1 new signature and Success body runs no repair"

    # --- AE2 -------------------------------------------------------------------
    setup_case ae2
    set_dns_fail 0
    pass_from flushed
    run_past_grace
    grep -qF 'check fail dns' "$CASE/out.log" || fail "AE2: log did not name the DNS failure"
    grep -qF 'dns-flush' "$CASE/out.log" || fail "AE2: log did not name the DNS flush"
    grep -qF '[-flushcache]' "$CALLS" || fail "AE2: dscacheutil -flushcache did not run"
    grep -qF 'killall [-HUP] [mDNSResponder]' "$CALLS" || fail "AE2: mDNSResponder was not signaled"
    if grep -qF 'tailscale [down]' "$CALLS"; then fail "AE2: tailscale was reconnected"; fi
    if grep -qF 'tailscale [up]' "$CALLS"; then fail "AE2: tailscale was reconnected"; fi
    if grep -qF 'networksetup' "$CALLS"; then fail "AE2: networksetup was called"; fi
    pass "AE2 DNS failure stops at the flush"

    # --- both fail, Tailscale restores ----------------------------------------
    setup_case tailscale-restores
    set_all_fail
    pass_from tailscale
    run_past_grace
    assert_tailscale_toggle
    if grep -qF '[-setairportpower]' "$CALLS"; then fail "tailscale restore cycled a service"; fi
    if grep -qF '[-setnetworkserviceenabled]' "$CALLS"; then fail "tailscale restore cycled a service"; fi
    grep -qF 'repair restored tailscale' "$CASE/out.log" || fail "log did not name the tailscale repair"
    pass "both checks fail and Tailscale reconnect restores them"

    # --- DNS stays down after the flush ---------------------------------------
    setup_case dns-continues
    set_dns_fail 0
    set_dns_fail flushed
    pass_from tailscale
    run_past_grace
    grep -qF '[-flushcache]' "$CALLS" || fail "DNS continuation: flush did not run"
    assert_tailscale_toggle
    pass "DNS failure that survives the flush continues to Tailscale"

    # --- AE3 -------------------------------------------------------------------
    setup_case ae3
    set_all_fail
    pass_from cycled
    run_past_grace
    grep -qF '[-setairportpower] [en0] [off]' "$CALLS" || fail "AE3: airport was not turned off"
    grep -qF '[-setairportpower] [en0] [on]' "$CALLS" || fail "AE3: airport was not turned on"
    grep -qx 'HAD_PENDING off' "$CASE/var/pending-trace" || fail "AE3: no pending record before off"
    grep -qx 'HAD_PENDING on' "$CASE/var/pending-trace" || fail "AE3: no pending record before on"
    if [ -e "$CASE/var/pending-service" ]; then fail "AE3: pending record remained"; fi
    if grep -qF '[-setnetworkserviceenabled]' "$CALLS"; then fail "AE3: cycled a named service"; fi
    pass "AE3 Wi-Fi cycle keeps a pending record between off and on"

    # --- AE4 -------------------------------------------------------------------
    setup_case ae4
    set_all_fail
    run_past_grace
    grep -qx 'status=exhausted' "$CASE/var/episode" || fail "AE4: episode was not exhausted: $(cat "$CASE/var/episode" 2>/dev/null || true)"
    grep -qF 'episode exhausted' "$CASE/out.log" || fail "AE4: log did not mark the episode exhausted"
    grep -qF 'repair restored none' "$CASE/out.log" || fail "AE4: log did not say no repair worked"
    run_case
    assert_no_repair "AE4 same signature"
    grep -qx 'status=exhausted' "$CASE/var/episode" || fail "AE4: same signature did not stay exhausted"
    sed 's/interface: en0/interface: en1/' "$ANSWERS/route" > "$ANSWERS/route.new"
    mv "$ANSWERS/route.new" "$ANSWERS/route"
    rm -f "$CASE/var/phase"
    run_case
    grep -qF 'episode open' "$CASE/out.log" || fail "AE4: a new signature did not open a new episode"
    grep -qx 'status=open' "$CASE/var/episode" || fail "AE4: the new episode is not open"
    pass "AE4 exhaustion holds for the signature and clears on a new one"

    # --- iPhone USB ------------------------------------------------------------
    setup_case iphone
    set_all_fail
    pass_from cycled
    cat > "$ANSWERS/route" <<'EOF'
    route to: default
    destination: default
           mask: default
        gateway: 203.0.113.1
      interface: en6
          flags: <UP,GATEWAY,DONE,STATIC,PRCLONING>
    ssid CafeSSID
    RAW_MARKER
    EOF
    cat > "$ANSWERS/services" <<'EOF'
    An asterisk (*) denotes that a network service is disabled.
    (1) Wi-Fi
    (Hardware Port: Wi-Fi, Device: en0)

    (2) iPhone USB
    (Hardware Port: iPhone USB, Device: en6)

    (3) *Bluetooth PAN
    (Hardware Port: Bluetooth PAN, Device: en6)

    EOF
    cat > "$ANSWERS/ports" <<'EOF'
    Hardware Port: Wi-Fi
    Device: en0
    Ethernet Address: 0a:1b:2c:3d:4e:5f

    Hardware Port: iPhone USB
    Device: en6
    Ethernet Address: 0a:1b:2c:3d:4e:60

    EOF
    run_past_grace
    grep -qF '[-setnetworkserviceenabled] [iPhone USB] [off]' "$CALLS" || fail "iPhone USB was not disabled"
    grep -qF '[-setnetworkserviceenabled] [iPhone USB] [on]' "$CALLS" || fail "iPhone USB was not enabled"
    if grep -qF '[-setairportpower]' "$CALLS"; then fail "iPhone USB cycle used airport power"; fi
    pass "iPhone USB service is cycled by name"

    # --- two enabled services --------------------------------------------------
    setup_case two-services
    set_all_fail
    cat > "$ANSWERS/services" <<'EOF'
    (1) Wi-Fi
    (Hardware Port: Wi-Fi, Device: en0)

    (2) Wi-Fi 2
    (Hardware Port: Wi-Fi, Device: en0)

    EOF
    run_past_grace
    grep -qF 'skip cycle no-single-match' "$CASE/out.log" || fail "two services: cycle was not skipped"
    if grep -qF '[-setairportpower]' "$CALLS"; then fail "two services: airport was cycled"; fi
    if grep -qF '[-setnetworkserviceenabled]' "$CALLS"; then fail "two services: a service was cycled"; fi
    pass "two enabled services for the default device skip the cycle"

    # --- utun and no default route --------------------------------------------
    setup_case utun
    set_all_fail
    set_stopped
    sed 's/interface: en0/interface: utun4/' "$ANSWERS/route" > "$ANSWERS/route.new"
    mv "$ANSWERS/route.new" "$ANSWERS/route"
    run_past_grace
    grep -qF 'skip cycle utun' "$CASE/out.log" || fail "utun: cycle was not skipped"
    if grep -qF '[-setairportpower]' "$CALLS"; then fail "utun: airport was cycled"; fi
    if grep -qF '[-setnetworkserviceenabled]' "$CALLS"; then fail "utun: a service was cycled"; fi
    pass "utun default interface skips the cycle"

    setup_case no-route
    set_all_fail
    set_stopped
    printf '1\n' > "$ANSWERS/route-status"
    printf 'route: not in table\nRAW_MARKER\n' > "$ANSWERS/route"
    run_case
    grep -qF 'no default route' "$CASE/out.log" || fail "no route: the missing route was not logged"
    assert_no_repair "no route"
    if grep -qF 'curl' "$CALLS"; then fail "no route: checks ran"; fi
    if [ -e "$CASE/var/episode" ]; then fail "no route: an episode opened"; fi
    run_case
    if [ -s "$CASE/out.log" ]; then fail "no route: an unchanged missing route was logged again"; fi
    pass "no default route opens no episode and repairs nothing"

    # --- Tailscale stopped -----------------------------------------------------
    setup_case stopped
    set_all_fail
    set_stopped
    pass_from cycled
    run_past_grace
    grep -qF 'skip tailscale' "$CASE/out.log" || fail "stopped: tailscale step was not skipped"
    if grep -qF 'tailscale [down]' "$CALLS"; then fail "stopped: tailscale down ran"; fi
    if grep -qF 'tailscale [up]' "$CALLS"; then fail "stopped: tailscale up ran"; fi
    grep -qF '[-setairportpower] [en0] [off]' "$CALLS" || fail "stopped: cycle did not run"
    pass "Tailscale Stopped skips reconnect and still cycles"

    # --- no console user -------------------------------------------------------
    setup_case no-user
    set_all_fail
    set_loginwindow
    pass_from cycled
    run_past_grace
    grep -qF 'skip tailscale' "$CASE/out.log" || fail "no user: tailscale step was not skipped"
    if grep -qF 'launchctl' "$CALLS"; then fail "no user: launchctl ran"; fi
    grep -qF '[-setairportpower] [en0] [off]' "$CALLS" || fail "no user: cycle did not run"
    pass "no console user skips Tailscale and still cycles"

    # --- captive portal --------------------------------------------------------
    setup_case captive
    printf '%s\n' '<HTML><HEAD><TITLE>Login</TITLE></HEAD><BODY>PORTAL_BODY_MARKER</BODY></HTML>' > "$ANSWERS/http-0"
    run_case
    grep -qE 'captive|policy' "$CASE/out.log" || fail "captive: log did not record a captive or policy result"
    assert_no_repair captive
    age_episode
    run_case
    assert_no_repair "captive after grace"
    pass "a portal page runs no repair"

    setup_case deadline-progress
    set_all_fail
    run_in_grace
    age_episode
    touch "$ANSWERS/slow-repair"
    run_case
    grep -qF 'deadline reached' "$CASE/out.log" || fail "slow repair did not exhaust the run budget"
    rm "$ANSWERS/slow-repair"
    pass_from cycled
    run_case
    if grep -qF '[-flushcache]' "$CALLS"; then fail "deadline restarted the ladder at DNS"
    fi
    assert_tailscale_toggle
    grep -qF '[-setairportpower] [en0] [off]' "$CALLS" || fail "deadline prevented the physical repair"
    grep -qF 'repair restored cycle' "$CASE/out.log" || fail "resumed ladder did not restore connectivity"
    pass "a deadline resumes the ladder without repeating DNS"

    # --- interrupted physical restore ----------------------------------------
    setup_case pending-service
    set_all_fail
    pass_from cycled
    touch "$ANSWERS/on-fail"
    run_past_grace
    grep -qx 'HAD_PENDING off' "$CASE/var/pending-trace" || fail "no service restore record before off"
    [ -f "$CASE/var/pending-service" ] || fail "failed on lost the restore record"
    run_case
    [ -f "$CASE/var/pending-service" ] || fail "failed retry lost the restore record"
    if grep -qF '[-setairportpower] [en0] [off]' "$CALLS"; then fail "failed restore repeated off"; fi
    if grep -qF 'tailscale [down]' "$CALLS"; then fail "failed physical restore allowed another repair"; fi
    rm "$ANSWERS/on-fail"
    run_case
    grep -qF '[-setairportpower] [en0] [on]' "$CALLS" || fail "pending service was not turned on"
    if grep -qF '[-setairportpower] [en0] [off]' "$CALLS"; then fail "pending restore turned the service off"; fi
    if [ -e "$CASE/var/pending-service" ]; then fail "pending service record was not cleared"; fi
    pass "failed service on persists and retries without another off"

    # --- pending tailscale restore fails --------------------------------------
    setup_case pending-tailscale
    set_all_fail
    : > "$ANSWERS/up-fail"
    run_past_grace
    assert_tailscale_toggle
    [ -f "$CASE/var/pending-tailscale" ] || fail "failed up lost the produced record"
    set_loginwindow
    run_case
    up="launchctl [asuser] [501] [sudo] [-u] [testuser] [$CASE/stubs/tailscale] [up]"
    grep -qF "$up" "$CALLS" || fail "pending tailscale up did not use the stored user"
    if grep -qF 'tailscale [down]' "$CALLS"; then fail "pending tailscale restore ran down"; fi
    if grep -qF 'tailscale [up] [' "$CALLS"; then fail "pending tailscale up had flags"; fi
    if [ ! -f "$CASE/var/pending-tailscale" ]; then fail "failed tailscale restore cleared the record"; fi
    rm "$ANSWERS/up-fail"
    pass_from tailscale
    run_case
    grep -qF "$up" "$CALLS" || fail "successful retry did not use the stored user"
    if grep -qF 'tailscale [down]' "$CALLS"; then fail "successful retry repeated down"; fi
    [ ! -e "$CASE/var/pending-tailscale" ] || fail "successful retry retained the record"
    pass "failed Tailscale up persists and retries with the original console user"

    setup_case pending-tailscale-needs-physical
    set_all_fail
    pass_from cycled
    touch "$ANSWERS/up-needs-cycle" "$ANSWERS/slow-discovery"
    run_past_grace
    assert_tailscale_toggle
    [ -f "$CASE/var/pending-tailscale" ] || fail "offline tunnel lost its restore record"
    [ ! -e "$CASE/var/pending-service" ] || fail "discovery timeout wrote an off record"
    rm "$ANSWERS/slow-discovery"
    run_case
    if grep -qF 'tailscale [down]' "$CALLS"; then fail "pending tunnel was taken down again"; fi
    grep -qF '[-setairportpower] [en0] [off]' "$CALLS" || fail "pending tunnel blocked physical repair"
    [ ! -e "$CASE/var/pending-tailscale" ] || fail "tunnel did not recover after the physical cycle"
    grep -qF 'repair restored cycle' "$CASE/out.log" || fail "physical repair did not recover connectivity"
    pass "discovery resumes across runs and repairs the link before retrying the tunnel"

    for change in gateway mac address; do
      setup_case "same-interface-$change"
      set_all_fail
      run_past_grace
      run_case
      assert_no_repair "unchanged exhausted network"
      case $change in
        gateway) file=route; before=203.0.113.1; after=203.0.113.2 ;;
        mac) file=arp; before=02:00:5e:00:53:01; after=02:00:5e:00:53:02 ;;
        address) file=ifconfig; before=203.0.113.50; after=203.0.113.51 ;;
      esac
      sed "s/$before/$after/" "$ANSWERS/$file" > "$ANSWERS/$file.new"
      mv "$ANSWERS/$file.new" "$ANSWERS/$file"
      run_case
      grep -qF 'episode open' "$CASE/out.log" || fail "$change did not open a new episode on en0"
      pass "same-interface $change change starts a new recovery episode"
    done

    # --- exhausted episode then passes ----------------------------------------
    setup_case exhausted-pass
    run_case
    now=$(date +%s)
    cat > "$CASE/var/episode" <<EOF
    status=exhausted
    started_at=$((now - 90))
    tailscale=Running
    signature=placeholder
    EOF
    run_case
    assert_no_repair "exhausted pass"
    if [ -e "$CASE/var/episode" ]; then fail "passing exhausted episode stayed open"; fi
    duration=$(sed -n 's/.*duration=\([0-9][0-9]*\).*/\1/p' "$CASE/out.log" | sed -n '1p')
    if [ -z "$duration" ]; then fail "exhausted pass did not log a duration"; fi
    if [ "$duration" -lt 85 ] || [ "$duration" -gt 120 ]; then
      fail "exhausted pass duration was $duration"
    fi
    pass "a passing exhausted episode closes and records the duration"

    # --- 40 second gap ---------------------------------------------------------
    setup_case gap
    run_case
    now=$(date +%s)
    printf '%s\n' "$((now - 40))" > "$CASE/var/last-run"
    run_case
    grep -qF 'reason=gap' "$CASE/out.log" || fail "a 40s gap did not open an episode"
    grep -qF 'episode open' "$CASE/out.log" || fail "a 40s gap did not log the episode"
    pass "a 40 second gap opens a new episode"

    # --- log redaction on a full ladder ---------------------------------------
    setup_case redaction
    set_all_fail
    run_in_grace
    grep -qF 'tailscale [status] [--json]' "$CALLS" || fail "redaction: tailscale status was never read"
    age_episode
    run_case
    grep -qF 'route [-n] [get] [default]' "$CALLS" || fail "redaction: route output was never read"
    grep -qF 'arp [-n]' "$CALLS" || fail "redaction: arp output was never read"
    grep -qF 'ifconfig' "$CALLS" || fail "redaction: ifconfig output was never read"
    grep -qF '[-listnetworkserviceorder]' "$CALLS" || fail "redaction: service list was never read"
    grep -qF '[-listallhardwareports]' "$CALLS" || fail "redaction: hardware ports were never read"
    pass "log lines contain no SSID, address, or raw command output"

    touch "$out"
  ''
