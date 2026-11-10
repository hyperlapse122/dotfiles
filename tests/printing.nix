/*
  Check interface:

    import ./tests/printing.nix { inherit pkgs self; }

  Asserts what modules/nixos/services/printing.nix produces on every
  configuration `tests/lib/configurations.nix` yields. Every assertion reads
  something activation produces -- the materialised systemd unit tree, the
  materialised nsswitch.conf and resolved.conf, the firewall start script, and
  the driver tree cupsd serves filters from -- never the options the module
  sets. Expectations come from the `my.printing.enable` trait and from
  `my.printing.queues`.

  On a configuration that enables the trait:
  - cups.socket keeps a listener after its drop-ins, so a masked unit or an
    empty ListenStream= reset fails, and sockets.target wants it.
  - avahi-daemon.service runs avahi-daemon and multi-user.target wants it.
  - no unit runs cups-browsed.
  - the hosts line of nsswitch.conf carries mdns4_minimal, before resolve
    when resolve is present.
  - on a configuration that runs systemd-resolved, resolved.conf turns its
    mDNS responder off. When no enabled configuration runs resolved, each
    production configuration is also checked re-evaluated with printing and
    resolved on, so this branch never covers zero configurations.
  - the firewall start script accepts UDP 5353.
  - the cupsd driver tree carries the gutenprint and hplip filters.

  On a configuration that leaves the trait off: no cups.socket listens, no
  avahi-daemon.service runs, nsswitch.conf carries no mdns4_minimal, and
  resolved.conf keeps its mDNS default.

  On a production configuration that declares printer queues:
  - ensure-printers.service is wanted by multi-user.target and reads the
    rendered sops template, whose keys carry each declared label's
    <LABEL>_URI and <LABEL>_INFO.
  - its script assigns each label's uri and info only from those variables,
    creates the queue from "$uri" with `-m everywhere`, sets its description
    from "$info" on every run, and passes lpadmin no other -v or -D value.
  - the unit, its script, and the template carry no literal URI of any
    scheme and no IPv4 address, so a device URI or address rendered into the
    Nix store fails.
  On every other configuration, including bootstrap outputs, no
  ensure-printers.service exists. When no production configuration declares a
  queue, each is re-evaluated with printing on and one queue, and when every
  production configuration declares one, each is re-evaluated with no queues,
  so both the queue and the absence assertions cover a production
  configuration.

  The builder collects every failure instead of exiting at the first, so one
  red build names every affected configuration.
*/
{ pkgs, self }:
let
  inherit (pkgs) lib;

  configurations = import ./lib/configurations.nix { inherit pkgs self; };
  printing = configurations.withTrait "my.printing.enable" (config: config.my.printing.enable);

  declaresQueues = entry: !entry.bootstrap && entry.config.my.printing.queues != [ ];
  # A production configuration re-evaluated with printing on and one printer
  # queue, for a fleet in which no production configuration declares one. The
  # label must exist in secrets/printers.yaml: sops-nix validates every
  # secret it reads against the file's keys at build time.
  withQueue =
    entry:
    configurations.entryOf "${entry.name} with a printer queue" (
      self.nixosConfigurations.${entry.name}.extendModules {
        modules = [
          {
            my.printing.enable = lib.mkForce true;
            my.printing.queues = lib.mkForce [ "office" ];
          }
        ];
      }
    );

  queued =
    let
      declared = lib.filter declaresQueues configurations.entries;
    in
    if declared != [ ] then declared else map withQueue configurations.production;
  # A production configuration re-evaluated with no printer queues, for a
  # fleet in which every production configuration declares one.
  withoutQueues =
    entry:
    configurations.entryOf "${entry.name} with no printer queues" (
      self.nixosConfigurations.${entry.name}.extendModules {
        modules = [ { my.printing.queues = lib.mkForce [ ]; } ];
      }
    );

  unqueued =
    lib.filter (entry: !declaresQueues entry) configurations.entries
    ++ lib.optionals (lib.all declaresQueues configurations.production) (
      map withoutQueues configurations.production
    );

  esc = value: lib.escapeShellArg (toString value);

  fail = message: ''
    echo ${esc message} >&2
    failed=1
  '';

  etcFile = import ./lib/etc-file.nix { inherit lib; };
  units = config: etcFile config "systemd/system";

  # cupsd serves filters from the tree its ServerBin names; CUPS_DATADIR points
  # at share/cups inside the same tree.
  driverTree =
    config:
    let
      dataDir = config.environment.sessionVariables.CUPS_DATADIR or null;
    in
    if dataDir == null then null else dirOf (dirOf dataDir);

  # The Proton VPN module, not the module under test, decides this.
  runsResolved = config: config.services.resolved.enable;

  # A production configuration re-evaluated with printing and resolved on, for
  # a fleet in which no configuration enabling printing runs resolved.
  withResolved =
    entry:
    configurations.entryOf "${entry.name} with printing and resolved on" (
      self.nixosConfigurations.${entry.name}.extendModules {
        modules = [
          {
            my.printing.enable = lib.mkForce true;
            services.resolved.enable = lib.mkForce true;
          }
        ];
      }
    );

  enabled =
    printing.enabled
    ++ lib.optionals (!lib.any (entry: runsResolved entry.config) printing.enabled) (
      map withResolved configurations.production
    );

  withTree =
    entry: body:
    let
      tree = units entry.config;
    in
    if tree == null then
      fail "${entry.name}: the built system declares no /etc/systemd/system tree"
    else
      body tree;

  assertEnabled =
    entry:
    let
      inherit (entry) config name;
      nsswitch = etcFile config "nsswitch.conf";
      resolvedConf = etcFile config "systemd/resolved.conf";
      drivers = driverTree config;
    in
    lib.concatStringsSep "\n" [
      (withTree entry (tree: ''
        if ! socketListens ${esc "${tree}/cups.socket"}; then
          ${fail "${name}: the materialised cups.socket is missing, masked, or listens nowhere"}
        fi
        if [ ! -e ${esc "${tree}/sockets.target.wants/cups.socket"} ]; then
          ${fail "${name}: sockets.target does not want cups.socket"}
        fi
        if ! grep -q '^ExecStart=.*/avahi-daemon ' ${esc "${tree}/avahi-daemon.service"}; then
          ${fail "${name}: the materialised avahi-daemon.service is missing, masked, or does not run avahi-daemon"}
        fi
        if [ ! -e ${esc "${tree}/multi-user.target.wants/avahi-daemon.service"} ]; then
          ${fail "${name}: multi-user.target does not want avahi-daemon.service"}
        fi
        if grep -qs '^ExecStart=.*cups-browsed' ${esc tree}/*.service; then
          ${fail "${name}: a unit runs cups-browsed"}
        fi
        firewall=$(sed -n 's/^ExecStart=@\([^ ]*\) .*/\1/p' ${esc "${tree}/firewall.service"})
        if [ -z "$firewall" ] || ! grep -q -- '-p udp --dport 5353 -j nixos-fw-accept' "$firewall"; then
          ${fail "${name}: the firewall start script does not accept UDP 5353 for mDNS"}
        fi
      ''))
      (
        if nsswitch == null then
          fail "${name}: the built system declares no /etc/nsswitch.conf"
        else
          ''
            hosts=$(grep '^hosts:' ${esc nsswitch})
            case "$hosts" in
              *mdns4_minimal*) ;;
              *) ${fail "${name}: the nsswitch.conf hosts line carries no mdns4_minimal"} ;;
            esac
            case "$hosts" in
              *resolve*mdns4_minimal*) ${fail "${name}: the nsswitch.conf hosts line puts resolve before mdns4_minimal"} ;;
            esac
          ''
      )
      (lib.optionalString (runsResolved config) (
        if resolvedConf == null then
          fail "${name}: resolved runs but the built system declares no /etc/systemd/resolved.conf"
        else
          ''
            if ! grep -qx 'MulticastDNS=false' ${esc resolvedConf}; then
              ${fail "${name}: resolved.conf leaves resolved's mDNS responder on beside Avahi"}
            fi
          ''
      ))
      (
        if drivers == null then
          fail "${name}: the built system sets no CUPS_DATADIR, so the cupsd driver tree is unknown"
        else
          ''
            # stdenv sets nullglob, so `ls` on an unmatched glob lists the
            # build directory and succeeds; test each match instead.
            gutenprint=
            for filter in ${esc drivers}/lib/cups/filter/rastertogutenprint.*; do
              if [ -e "$filter" ]; then gutenprint=1; fi
            done
            if [ -z "$gutenprint" ]; then
              ${fail "${name}: the cupsd driver tree carries no gutenprint filter"}
            fi
            if [ ! -x ${esc "${drivers}/lib/cups/filter/hpcups"} ]; then
              ${fail "${name}: the cupsd driver tree carries no hplip hpcups filter"}
            fi
          ''
      )
    ];

  assertDisabled =
    entry:
    let
      inherit (entry) config name;
      nsswitch = etcFile config "nsswitch.conf";
      resolvedConf = etcFile config "systemd/resolved.conf";
    in
    lib.concatStringsSep "\n" [
      (withTree entry (tree: ''
        if socketListens ${esc "${tree}/cups.socket"}; then
          ${fail "${name}: my.printing.enable is off but cups.socket listens"}
        fi
        if grep -qs '^ExecStart=.*/avahi-daemon ' ${esc "${tree}/avahi-daemon.service"}; then
          ${fail "${name}: my.printing.enable is off but avahi-daemon.service runs avahi-daemon"}
        fi
      ''))
      (lib.optionalString (nsswitch != null) ''
        if grep '^hosts:' ${esc nsswitch} | grep -q mdns4_minimal; then
          ${fail "${name}: my.printing.enable is off but the nsswitch.conf hosts line carries mdns4_minimal"}
        fi
      '')
      (lib.optionalString (resolvedConf != null) ''
        if grep -q '^MulticastDNS=false$' ${esc resolvedConf}; then
          ${fail "${name}: my.printing.enable is off but resolved.conf turns resolved's mDNS responder off"}
        fi
      '')
    ];

  # Any URI scheme, or a dotted-quad IPv4 address not embedded in a longer
  # dotted version string.
  leakPattern = "[A-Za-z][A-Za-z0-9+.-]*://|(^|[^0-9.])([0-9]{1,3}[.]){3}[0-9]{1,3}([^0-9.]|$)";

  queueRuntime = pkgs.writeText "printing-runtime.py" ''
    import json, os, pathlib, subprocess, sys, tempfile
    script, labels_json, bash = sys.argv[1:]
    labels = json.loads(labels_json)
    with tempfile.TemporaryDirectory() as directory:
        root = pathlib.Path(directory)
        body = pathlib.Path(script).read_text()
        import re
        for command in ["lpstat", "lpadmin"]:
            body = re.sub(r"(?<![A-Za-z0-9_/.-])" + command + r"(?= )", str(root / command), body)
            assert not re.search(r"(?<![A-Za-z0-9_.-])(?:/[^\s;]*)?/" + command + r"(?= |$)|(?<![A-Za-z0-9_/.-])" + command + r"(?= |$)", body.replace(str(root / command), "")), "unredirected printer command: " + command
        body = re.sub(r"^#!.*\n", "", body)
        (root / "run").write_text(body)
        stub = "#!" + sys.executable + "\n" + r"""
    import json, os, pathlib, sys
    root = pathlib.Path(os.environ['QUEUE_SCRATCH'])
    args = sys.argv[1:]
    if pathlib.Path(sys.argv[0]).name == 'lpstat':
        label = args[1]
        if os.environ['QUEUE_CASE'] == 'fresh': sys.exit(1)
        uri = 'ipp://old.invalid/queue' if os.environ['QUEUE_CASE'] == 'changed' else os.environ[label.upper() + '_URI']
        print('device for ' + label + ': ' + uri)
    else:
        with (root / 'calls').open('a') as log: log.write(json.dumps(args) + '\n')
        if os.environ['QUEUE_CASE'] == 'refuse' or ('-v' in args and os.environ['QUEUE_CASE'] == 'correct'): sys.exit(42)
    """
        for name in ['lpstat', 'lpadmin']:
            (root / name).write_text(stub)
            (root / name).chmod(0o700)
        for case in ['fresh', 'changed', 'correct', 'refuse']:
            (root / 'calls').write_text("")
            env = dict(os.environ, QUEUE_SCRATCH=str(root), QUEUE_CASE=case, PATH=str(root) + ':' + os.environ['PATH'])
            for label in labels:
                env[label.upper() + '_URI'] = 'ipp://fake.invalid/' + label
                env[label.upper() + '_INFO'] = 'Fake printer ' + label
            result = subprocess.run([bash, '-eu', str(root / 'run')], env=env)
            calls = [json.loads(line) for line in (root / 'calls').read_text().splitlines()]
            if case == 'refuse':
                assert result.returncode != 0, 'printer reconciliation swallowed lpadmin refusal'
                continue
            expected = []
            for label in labels:
                if case != 'correct': expected.append(['-p', label, '-E', '-v', env[label.upper() + '_URI'], '-m', 'everywhere'])
                expected.append(['-p', label, '-D', env[label.upper() + '_INFO']])
            assert result.returncode == 0 and calls == expected, ('printer queue lifecycle', case, calls, expected)
  '';

  assertQueued =
    entry:
    let
      inherit (entry) config name;
      template = config.sops.templates."printers.env".file or null;

      assertLabel =
        label:
        let
          env = lib.toUpper label;
        in
        ''
          if ! grep -qxF ${esc ("uri=$" + env + "_URI")} "$script" || ! grep -qxF ${esc ("info=$" + env + "_INFO")} "$script"; then
            ${fail "${name}: the ensure-printers script does not read the ${label} queue's uri and info from ${env}_URI and ${env}_INFO"}
          fi
          if ! grep -qE ${esc "^[[:space:]]*lpadmin -p ${label} -E -v \"\\$uri\" -m everywhere$"} "$script"; then
            ${fail "${name}: the ensure-printers script does not create the ${label} queue from \"$uri\" with -m everywhere"}
          fi
          if ! grep -qxF ${esc "lpadmin -p ${label} -D \"$info\""} "$script"; then
            ${fail "${name}: the ensure-printers script does not set the ${label} queue's description from \"$info\" on every run"}
          fi
          ${lib.optionalString (template != null) ''
            if ! grep -q ${esc "^${env}_URI="} ${esc template} || ! grep -q ${esc "^${env}_INFO="} ${esc template}; then
              ${fail "${name}: the printers.env template defines no ${env}_URI or ${env}_INFO for the ${label} queue"}
            fi
          ''}
        '';
    in
    withTree entry (tree: ''
      unit=${esc "${tree}/ensure-printers.service"}
      if [ ! -e ${esc "${tree}/multi-user.target.wants/ensure-printers.service"} ]; then
        ${fail "${name}: queues are declared but multi-user.target does not want ensure-printers.service"}
      fi
      if ! grep -qx 'EnvironmentFile=/run/secrets/rendered/printers.env' "$unit"; then
        ${fail "${name}: ensure-printers.service is missing, masked, or does not read the rendered printers.env"}
      fi
      ${lib.optionalString (template == null) (
        fail "${name}: queues are declared but no printers.env template is rendered"
      )}
      script=$(sed -n 's/^ExecStart=\([^ ]*\).*/\1/p' "$unit")
      if [ -z "$script" ]; then
        ${fail "${name}: ensure-printers.service runs no script"}
        script=/dev/null
      fi
      ${lib.concatMapStrings assertLabel config.my.printing.queues}
      if ! python3 ${queueRuntime} "$script" ${esc (builtins.toJSON config.my.printing.queues)} ${pkgs.bash}/bin/bash; then
        ${fail "${name}: printer queue lifecycle failed"}
      fi
      # The pipeline tails read all their input rather than use -q, so an
      # early exit cannot SIGPIPE the producer and fail the pipe under pipefail.
      if grep -E '^[[:space:]]*(uri|info)=' "$script" | grep -vxE '[[:space:]]*(uri=[$][A-Z0-9_]+_URI|info=[$][A-Z0-9_]+_INFO)' >/dev/null; then
        ${fail "${name}: the ensure-printers script assigns uri or info from something other than the rendered environment"}
      fi
      if grep -E '(^|[[:space:]])lpadmin ' "$script" | grep -oE -- ' -[vD] [^ ]+' | grep -vxE -- ' -v "[$]uri"| -D "[$]info"' >/dev/null; then
        ${fail "${name}: the ensure-printers script passes lpadmin a device URI or description other than \"$uri\" or \"$info\""}
      fi
      if grep -qE ${esc leakPattern} "$script" "$unit" ${
        lib.optionalString (template != null) (esc template)
      }; then
        ${fail "${name}: ensure-printers.service, its script, or the printers.env template carries a literal URI or IPv4 address in the Nix store"}
      fi
    '');

  assertUnqueued =
    entry:
    withTree entry (tree: ''
      if [ -e ${esc "${tree}/ensure-printers.service"} ]; then
        ${fail "${entry.name}: no queue is declared for this configuration but ensure-printers.service exists"}
      fi
    '');

  resolvedGuard = lib.optionalString (!lib.any (entry: runsResolved entry.config) enabled) ''
    echo 'tests/printing.nix: no configuration enabling my.printing.enable runs resolved, even one re-evaluated with resolved on, so the mDNS conflict branch would cover none' >&2
    exit 1
  '';

  queueGuard = lib.optionalString (!lib.any declaresQueues queued) ''
    echo 'tests/printing.nix: no production configuration declares my.printing.queues, even one re-evaluated with a queue, so the queue branch would cover none' >&2
    exit 1
  '';

  unqueuedGuard =
    lib.optionalString (!lib.any (entry: !entry.bootstrap && !declaresQueues entry) unqueued)
      ''
        echo 'tests/printing.nix: every production configuration declares my.printing.queues, even the one re-evaluated with none, so the absence branch would cover no production configuration' >&2
        exit 1
      '';
in
pkgs.runCommand "printing-tests"
  {
    nativeBuildInputs = [
      pkgs.gnugrep
      pkgs.python3
    ];
  }
  ''
    set -x
    # Succeeds when the socket unit keeps a listener after its drop-ins, which
    # systemd applies in name order; an empty ListenStream= resets every earlier
    # one. A missing or masked unit has none.
    socketListens() {
      [ -s "$1" ] || return 1
      {
        cat "$1"
        for dropIn in "$1".d/*.conf; do
          if [ -e "$dropIn" ]; then cat "$dropIn"; fi
        done
      } | awk '/^ListenStream=$/ { n = 0; next } /^ListenStream=/ { n++ } END { exit n == 0 }'
    }
    ${configurations.guard}
    ${printing.guard}
    ${resolvedGuard}
    ${queueGuard}
    ${unqueuedGuard}
    failed=0

    ${lib.concatMapStringsSep "\n" assertEnabled enabled}
    ${lib.concatMapStringsSep "\n" assertDisabled printing.disabled}
    ${lib.concatMapStringsSep "\n" assertQueued queued}
    ${lib.concatMapStringsSep "\n" assertUnqueued unqueued}

    if [ "$failed" != 0 ]; then
      exit 1
    fi
    touch $out
  ''
