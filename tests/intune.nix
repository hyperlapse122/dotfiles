/*
  Check interface:

    import ./tests/intune.nix { inherit pkgs self; }

  Asserts what the `my.intune.enable` trait produces: the Intune app, the
  identity broker, their units, the Ubuntu OS identity for the executables
  that read one, the password policy, and Microsoft Edge. Every assertion
  reads the built system or user environment, never the options the modules
  set.

  Verifies, per configuration that enables the trait:
  - intune-daemon.service, intune-daemon.socket, and
    microsoft-identity-device-broker.service are regular system units,
    sockets.target.wants holds the socket, and the socket still listens on
    the packaged path.
  - intune-agent.service and intune-agent.timer are regular user units,
    graphical-session.target.wants holds the timer, and the timer still
    carries the packaged schedule.
  - the device broker unit, the agent unit, the session D-Bus service of the
    identity broker, the Intune desktop entry, and bin/dsreg each start an
    executable wrapper that hands over to a real executable, and all five
    wrappers are the same text apart from the executable they name.
  - that wrapper binds, read-only, a file whose ID is ubuntu and whose
    VERSION_ID is 24.04, while the system's own os-release names nixos. That
    the bind changes what a running process reads is the VM test's subject,
    tests/intune-os-identity.nix.
  - the login PAM file loads an existing pam_intune.so, and the display
    manager's PAM file reaches that login stack.
  - the passwd PAM file runs an existing pam_pwquality.so before pam_unix.so,
    pam_unix.so takes the checked password with use_authtok, and
    /etc/pam.d/common-password declares the same arguments.
  - home.path carries bin/microsoft-edge and its desktop entry.

  Every configuration with the trait off, or forced off when none leaves it
  off, must carry none of the above, and every bootstrap configuration must
  have it off: an installation console cannot enroll.

  The builder collects every failure before it exits, so one red build names
  every affected configuration.
*/
{ pkgs, self }:
let
  inherit (pkgs) lib;

  configurations = import ./lib/configurations.nix { inherit pkgs self; };
  intune = configurations.withTrait "my.intune.enable" (config: config.my.intune.enable);

  esc = value: lib.escapeShellArg (toString value);

  fail = message: ''
    echo ${esc message} >&2
    failed=1
  '';

  etcFile = import ./lib/etc-file.nix { inherit lib; };

  # Every materialised /etc/pam.d file, as "name=store path" words.
  pamFiles =
    config:
    lib.concatMap (
      name:
      let
        source = etcFile config name;
      in
      lib.optional (lib.hasPrefix "pam.d/" name && source != null) "${name}=${source}"
    ) (lib.attrNames config.environment.etc);

  systemUnits = [
    "intune-daemon.service"
    "intune-daemon.socket"
    "microsoft-identity-device-broker.service"
  ];
  userUnits = [
    "intune-agent.service"
    "intune-agent.timer"
  ];

  # Fails unless `unit` in the unit tree `tree` is a regular, unmasked unit.
  assertUnit = name: tree: unit: ''
    if [ ! -f ${esc "${tree}/${unit}"} ] || [ "$(readlink -f ${esc "${tree}/${unit}"})" = /dev/null ]; then
      ${fail "${name}: ${unit} is missing or masked"}
    fi
  '';

  # Records the wrapper behind an entry point as "<executable name> <path>".
  # Microsoft's unit files end their lines with a carriage return.
  recordEntry = name: label: file: key: ''
    if [ ! -f ${esc file} ]; then
      ${fail "${name}: ${label} is missing"}
    else
      command=$(sed -n ${esc "s/^${key}=//p"} ${esc file} | tr -d '\r')
      wrapper=''${command##* }
      if [ -z "$wrapper" ] || [ ! -x "$wrapper" ]; then
        ${fail "${name}: ${label} starts no executable"}
      else
        echo "$(basename "$wrapper") $wrapper" >> "$entries"
      fi
    fi
  '';

  checkEnabled =
    entry:
    let
      inherit (entry) name config;
      homePath = entry.user.home.path or "";
      tree = etcFile config "systemd/system";
      userTree = etcFile config "systemd/user";
      osRelease = etcFile config "os-release";
      login = etcFile config "pam.d/login";
      displayManager = etcFile config "pam.d/sddm";
      passwd = etcFile config "pam.d/passwd";
      commonPassword = etcFile config "pam.d/common-password";
      systemPath = config.system.path;
    in
    ''
      entries=$(mktemp)
      ${
        if tree == null then
          fail "${name}: the built system declares no /etc/systemd/system tree"
        else
          ''
            ${lib.concatMapStrings (assertUnit name tree) systemUnits}
            if [ ! -e ${esc "${tree}/sockets.target.wants/intune-daemon.socket"} ]; then
              ${fail "${name}: sockets.target.wants does not hold intune-daemon.socket"}
            fi
            # An override that replaced the packaged unit instead of adding
            # a drop-in would leave a unit with no socket to listen on.
            if ! grep -qx 'ListenStream=/run/intune/daemon.socket' ${esc "${tree}/intune-daemon.socket"}; then
              ${fail "${name}: intune-daemon.socket no longer listens on /run/intune/daemon.socket"}
            fi
            ${recordEntry name "microsoft-identity-device-broker.service"
              "${tree}/microsoft-identity-device-broker.service"
              "ExecStart"
            }
          ''
      }
      ${
        if userTree == null then
          fail "${name}: the built system declares no /etc/systemd/user tree"
        else
          ''
            ${lib.concatMapStrings (assertUnit name userTree) userUnits}
            if [ ! -e ${esc "${userTree}/graphical-session.target.wants/intune-agent.timer"} ]; then
              ${fail "${name}: graphical-session.target.wants does not hold intune-agent.timer"}
            fi
            if ! grep -q '^OnUnitActiveSec=' ${esc "${userTree}/intune-agent.timer"}; then
              ${fail "${name}: intune-agent.timer no longer carries the packaged check-in schedule"}
            fi
            ${recordEntry name "intune-agent.service" "${userTree}/intune-agent.service" "ExecStart"}
          ''
      }
      ${recordEntry name "the identity broker's session D-Bus service"
        "${systemPath}/share/dbus-1/services/com.microsoft.identity.broker1.service"
        "Exec"
      }
      ${recordEntry name "the Intune desktop entry"
        "${systemPath}/share/applications/intune-portal.desktop"
        "Exec"
      }
      if [ ! -x ${esc "${systemPath}/bin/dsreg"} ]; then
        ${fail "${name}: the system path carries no executable bin/dsreg"}
      else
        echo "dsreg $(readlink -f ${esc "${systemPath}/bin/dsreg"})" >> "$entries"
      fi

      # Each wrapper must hand over to a real executable, and all of them must
      # be one text once the executable's name is taken out, so the VM test's
      # proof of one wrapper holds for the rest.
      shapes=$(mktemp)
      while read -r executable wrapper; do
        target=$(sed -n 's/.* -- "\([^"]*\)" "\$@"$/\1/p' "$wrapper")
        if [ "$(head -c 2 "$wrapper")" != '#!' ] || [ -z "$target" ]; then
          echo ${esc "${name}: "}"$executable is not started through the OS identity wrapper" >&2
          failed=1
          continue
        fi
        if [ ! -x "$target" ] || [ "$(basename "$target")" != "$executable" ] || [ "$(head -c 4 "$target")" != $'\x7fELF' ]; then
          echo ${esc "${name}: "}"the wrapper of $executable hands over to no real $executable" >&2
          failed=1
        fi
        sed "s#$(dirname "$(dirname "$wrapper")")#PACKAGE#g; s#$executable#NAME#g" "$wrapper" | sha256sum >> "$shapes"
        bound=$(sed -n 's/.* --ro-bind \([^ ]*\) .*/\1/p' "$wrapper")
        if [ -z "$bound" ] || [ ! -f "$bound" ]; then
          echo ${esc "${name}: "}"the wrapper of $executable binds no os-release file" >&2
          failed=1
        elif ! grep -qx 'ID=ubuntu' "$bound" || ! grep -qx 'VERSION_ID="24.04"' "$bound"; then
          echo ${esc "${name}: "}"the wrapper of $executable binds an os-release that is not Ubuntu 24.04" >&2
          failed=1
        fi
      done < "$entries"
      if [ "$(wc -l < "$entries")" != 5 ]; then
        ${fail "${name}: fewer than five Intune entry points start an executable"}
      fi
      if [ "$(sort -u "$shapes" | wc -l)" != 1 ]; then
        ${fail "${name}: the OS identity wrappers differ beyond the executable they name"}
      fi

      ${
        if osRelease == null then
          fail "${name}: the built system declares no /etc/os-release"
        else
          ''
            if ! grep -qx 'ID=nixos' ${esc osRelease}; then
              ${fail "${name}: the system's own os-release no longer names nixos"}
            fi
          ''
      }

      ${
        if login == null || displayManager == null then
          fail "${name}: the built system declares no login or display manager PAM file"
        else
          ''
            module=$(sed -n 's/^auth optional \([^ ]*pam_intune\.so\)\( .*\)\?$/\1/p' ${esc login})
            if [ -z "$module" ] || [ ! -f "$module" ]; then
              ${fail "${name}: the login PAM file loads no existing pam_intune.so"}
            fi
            if ! grep -Eq '^auth (substack|include) login( |$)' ${esc displayManager}; then
              ${fail "${name}: the display manager's PAM file does not reach the login stack"}
            fi
          ''
      }

      ${
        if passwd == null || commonPassword == null then
          fail "${name}: the built system declares no passwd or common-password PAM file"
        else
          ''
            quality=$(grep -n '^password requisite [^ ]*pam_pwquality\.so ' ${esc passwd} || true)
            unix=$(grep -n '^password [^ ]* [^ ]*pam_unix\.so ' ${esc passwd} || true)
            if [ -z "$quality" ] || [ -z "$unix" ] || [ "''${quality%%:*}" -ge "''${unix%%:*}" ]; then
              ${fail "${name}: the passwd PAM file does not run pam_pwquality.so before pam_unix.so"}
            else
              read -r _ _ module enforced <<< "''${quality#*:}"
              enforced=''${enforced%% #*}
              if [ ! -f "$module" ]; then
                ${fail "${name}: the passwd PAM file names a pam_pwquality.so that does not exist"}
              fi
              if ! grep -q ' use_authtok\( \|$\)' <<< "$unix"; then
                ${fail "${name}: pam_unix.so does not take the checked password with use_authtok"}
              fi
              declared=$(sed -n 's/^password requisite pam_pwquality\.so //p' ${esc commonPassword})
              if [ -z "$declared" ] || [ "$(tr ' ' '\n' <<< "$declared" | sort)" != "$(tr ' ' '\n' <<< "$enforced" | sort)" ]; then
                ${fail "${name}: /etc/pam.d/common-password does not declare the password policy that passwd enforces"}
              fi
            fi
          ''
      }

      homePath=${esc homePath}
      if [ -z "$homePath" ] || [ ! -x "$homePath/bin/microsoft-edge" ]; then
        ${fail "${name}: home.path carries no executable bin/microsoft-edge"}
      fi
      if [ -z "$homePath" ] || [ ! -f "$homePath/share/applications/microsoft-edge.desktop" ]; then
        ${fail "${name}: home.path carries no share/applications/microsoft-edge.desktop"}
      fi
    '';

  checkDisabled =
    entry:
    let
      inherit (entry) name config;
      homePath = entry.user.home.path or "";
      tree = etcFile config "systemd/system";
      userTree = etcFile config "systemd/user";
    in
    ''
      for program in intune-portal intune-agent intune-daemon microsoft-identity-broker dsreg; do
        if [ -e ${esc "${config.system.path}/bin"}/"$program" ]; then
          echo ${esc "${name}: "}"the system path carries bin/$program with my.intune.enable off" >&2
          failed=1
        fi
      done
      ${lib.concatMapStrings
        (
          unitTree:
          lib.optionalString (unitTree != null) ''
            # A loop, not `ls | grep -q`: under the builder's pipefail an early
            # grep match kills ls, and the pipeline then reads as no match.
            for unit in ${esc unitTree}/intune* ${esc unitTree}/microsoft-identity*; do
              if [ -e "$unit" ]; then
                ${fail "${name}: an Intune or identity broker unit exists with my.intune.enable off"}
              fi
            done
          ''
        )
        [
          tree
          userTree
        ]
      }
      for file in ${lib.concatMapStringsSep " " esc (pamFiles config)}; do
        if [ "''${file%%=*}" = pam.d/common-password ]; then
          ${fail "${name}: /etc/pam.d/common-password exists with my.intune.enable off"}
        fi
        if grep -Eq 'pam_(intune|pwquality)\.so' "''${file#*=}"; then
          echo ${esc "${name}: "}"/etc/''${file%%=*} loads an Intune password module with my.intune.enable off" >&2
          failed=1
        fi
      done
      homePath=${esc homePath}
      if [ -z "$homePath" ]; then
        ${fail "${name}: the configuration builds no h82 user environment to check for Edge"}
      elif [ -e "$homePath/bin/microsoft-edge" ]; then
        ${fail "${name}: home.path carries bin/microsoft-edge with my.intune.enable off"}
      fi
    '';

  checkBootstrap =
    entry:
    lib.optionalString entry.config.my.intune.enable (
      fail "${entry.name}: a bootstrap output enables my.intune.enable, but an installation console cannot enroll"
    );
in
pkgs.runCommand "intune-tests"
  {
    nativeBuildInputs = [
      pkgs.gnugrep
      pkgs.gnused
    ];
  }
  ''
    ${configurations.guard}
    ${intune.guard}
    failed=0

    ${lib.concatMapStringsSep "\n" checkBootstrap configurations.bootstraps}
    ${lib.concatMapStringsSep "\n" checkEnabled intune.enabled}
    ${lib.concatMapStringsSep "\n" checkDisabled intune.disabled}

    if [ "$failed" != 0 ]; then
      exit 1
    fi
    touch $out
  ''
