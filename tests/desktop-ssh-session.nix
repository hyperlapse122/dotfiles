{ pkgs, inputs }:
let
  tool = import ../packages/desktop-ssh.nix { inherit pkgs; };
  gate = import ../packages/desktop-ssh-session-active.nix { inherit pkgs; };
  python = pkgs.python3.withPackages (ps: [
    ps.dbus-python
    ps.pygobject3
    ps.cryptography
    ps.bcrypt
  ]);
  fixtures =
    pkgs.runCommand "desktop-ssh-session-fake-secrets"
      {
        nativeBuildInputs = [
          pkgs.age
          pkgs.sops
          pkgs.openssh
        ];
      }
      ''
        mkdir -p "$out"
        age-keygen -o "$out/age.txt"
        ssh-keygen -q -t ed25519 -N "" -f source
        cp source.pub "$out/ssh.pub"
        ${pkgs.python3}/bin/python3 -c 'import json; print(json.dumps({"ssh_private_key":open("source").read()}))' > plain.json
        sops --encrypt --age "$(age-keygen -y "$out/age.txt")" --input-type json --output-type yaml plain.json > "$out/ssh.yaml"
      '';
  wallet = pkgs.writeText "fake-kwallet.py" ''
    import dbus, dbus.service, json
    from pathlib import Path
    from dbus.mainloop.glib import DBusGMainLoop
    from gi.repository import GLib
    DBusGMainLoop(set_as_default=True)
    store = Path("/home/alice/wallet.json")
    class Wallet(dbus.service.Object):
        @dbus.service.method("org.kde.KWallet", in_signature="s", out_signature="b")
        def isOpen(self, wallet):
            return not Path("/home/alice/wallet-locked").exists()
        @dbus.service.method("org.kde.KWallet", in_signature="sxs", out_signature="i")
        def open(self, wallet, window, app):
            return -1 if Path("/home/alice/wallet-locked").exists() else 1
        @dbus.service.method("org.kde.KWallet", in_signature="iss", out_signature="b")
        def hasFolder(self, handle, folder, app): return True
        @dbus.service.method("org.kde.KWallet", in_signature="isss", out_signature="b")
        def hasEntry(self, handle, folder, name, app):
            return store.exists() and str(name) in json.loads(store.read_text())
        @dbus.service.method("org.kde.KWallet", in_signature="isss", out_signature="s")
        def readPassword(self, handle, folder, name, app):
            return json.loads(store.read_text())[str(name)]
        @dbus.service.method("org.kde.KWallet", in_signature="issss", out_signature="i")
        def writePassword(self, handle, folder, name, password, app):
            values = json.loads(store.read_text()) if store.exists() else {}
            values[str(name)] = str(password)
            store.write_text(json.dumps(values)); store.chmod(0o600)
            return 0
        @dbus.service.method("org.kde.KWallet", in_signature="is", out_signature="")
        def sync(self, handle, app): pass
        @dbus.service.method("org.kde.KWallet", in_signature="ibs", out_signature="i")
        def close(self, handle, force, app): return 0
    bus = dbus.SessionBus()
    name = dbus.service.BusName("org.kde.kwalletd6", bus)
    service = Wallet(bus, "/modules/kwalletd6")
    GLib.MainLoop().run()
  '';
  sign = pkgs.writeText "desktop-ssh-session-sign.py" ''
    import base64, socket, struct, sys
    from pathlib import Path
    from cryptography.hazmat.primitives.serialization import load_ssh_public_key
    def string(value): return struct.pack(">I", len(value)) + value
    def read(sock, count):
        result = b""
        while len(result) < count:
            chunk = sock.recv(count - len(result))
            assert chunk, "agent closed without signing response"
            result += chunk
        return result
    public = Path("${fixtures}/ssh.pub").read_bytes()
    blob = base64.b64decode(public.split()[1])
    data = b"session-cache-lifecycle-proof"
    packet = b"\x0d" + string(blob) + string(data) + struct.pack(">I", 0)
    with socket.socket(socket.AF_UNIX) as sock:
        sock.settimeout(100)
        sock.connect("/run/user/1000/desktop-ssh/agent.sock")
        sock.sendall(string(packet))
        response = read(sock, struct.unpack(">I", read(sock, 4))[0])
    if sys.argv[1] == "failure":
        assert response == b"\x05", response
    else:
        assert response[:1] == b"\x0e", response
        size = struct.unpack(">I", response[1:5])[0]
        value = response[5:]
        assert len(value) == size
        algorithm_size = struct.unpack(">I", value[:4])[0]
        assert value[4:4+algorithm_size] == b"ssh-ed25519"
        tail = value[4+algorithm_size:]
        assert struct.unpack(">I", tail[:4])[0] == len(tail[4:])
        load_ssh_public_key(public).verify(tail[4:], data)
  '';
in
pkgs.testers.nixosTest {
  name = "desktop-ssh-session";
  nodes.machine = { config, lib, ... }: {
    imports = [
      inputs.sops-nix.nixosModules.sops
      inputs.home-manager.nixosModules.home-manager
      ../modules/shared/host.nix
      ../modules/nixos/system/desktop-ssh.nix
    ];
    my.hostName = "session-fixture";
    my.user = {
      name = "alice";
      home = "/home/alice";
    };
    my.desktopSSH = {
      sopsFile = "${fixtures}/ssh.yaml";
      publicKey = "${fixtures}/ssh.pub";
    };
    sops.age.keyFile = "/var/lib/sops-nix/key.txt";
    sops.useSystemdActivation = true;
    sops.age.sshKeyPaths = [ ];
    sops.gnupg.sshKeyPaths = [ ];
    users.users.alice = {
      isNormalUser = true;
      uid = 1000;
    };
    users.users.bob = {
      isNormalUser = true;
      uid = 1001;
    };
    services.dbus.enable = true;
    security.polkit.enable = true;
    security.pam.services.graphical-fixture.text = ''
      account required ${pkgs.pam}/lib/security/pam_permit.so
      session required ${pkgs.systemd}/lib/security/pam_systemd.so type=x11 class=user
    '';
    security.pam.services.tty-fixture.text = ''
      account required ${pkgs.pam}/lib/security/pam_permit.so
      session required ${pkgs.systemd}/lib/security/pam_systemd.so type=tty class=user
    '';
    system.activationScripts.fakeIdentity = ''
      install -d -m0700 /var/lib/sops-nix
      install -m0600 ${fixtures}/age.txt /var/lib/sops-nix/key.txt
    '';
    systemd.services.desktop-ssh-provision.serviceConfig.ExecStartPre =
      pkgs.writeShellScript "fixture-credential-metadata" ''
        ${pkgs.coreutils}/bin/stat -Lc 'credential metadata uid=%u mode=%a nlink=%h type=%F' "$CREDENTIALS_DIRECTORY/source"
        for state in /home/alice/.ssh /home/alice/.ssh/.desktop-ssh.lock /home/alice/.ssh/id_ed25519_nix_config; do
          if [ -e "$state" ]; then
            ${pkgs.coreutils}/bin/stat -Lc 'SSH state metadata uid=%u mode=%a nlink=%h type=%F' "$state"
          fi
        done
      '';
    home-manager.useGlobalPkgs = true;
    home-manager.users.alice = {
      imports = [
        ../modules/shared/host.nix
        ../home/h82/security/ssh.nix
      ];
      my = (import ../lib/host-facts.nix { inherit lib; }).of config.my;
      home = {
        username = "alice";
        homeDirectory = "/home/alice";
        stateVersion = "25.11";
      };
    };
    systemd.user.services.fixture-wallet = {
      serviceConfig.ExecStart = "${python}/bin/python3 ${wallet}";
    };
    systemd.user.targets.fixture-graphical = {
      bindsTo = [ "graphical-session.target" ];
      wants = [ "graphical-session.target" ];
      before = [ "graphical-session.target" ];
    };
    systemd.user.targets.graphical-session.partOf = [ "fixture-graphical.target" ];
    environment.systemPackages = [
      tool
      gate
      python
      pkgs.kbd
    ];
    virtualisation.memorySize = 1536;
  };
  testScript = ''
    import datetime
    import json
    machine.start()
    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("sops-install-secrets.service")
    machine.succeed("loginctl enable-linger alice; loginctl enable-linger bob")
    machine.wait_for_unit("user@1000.service")
    def user(command, name="alice"):
        uid = "1000" if name == "alice" else "1001"
        return "runuser -u " + name + " -- env XDG_RUNTIME_DIR=/run/user/" + uid + " DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/" + uid + "/bus " + command
    def wait_graphical():
        try:
            machine.wait_until_succeeds(user("desktop-ssh-session-active alice"), timeout=datetime.timedelta(seconds=30))
        except Exception:
            print(machine.succeed("loginctl list-sessions --no-legend; for session in $(loginctl show-user alice -p Sessions --value); do loginctl show-session \"$session\" -p User -p Name -p Type -p Class -p Seat -p Active -p State -p Remote -p TTY -p VTNr; done; systemctl status fixture-graphical --no-pager || true; systemctl show fixture-graphical -p ActiveState -p SubState -p ExecMainPID -p Result; systemctl list-jobs; journalctl -u fixture-graphical --no-pager; loginctl seat-status seat0 || true"))
            raise
    metadata = json.loads(machine.succeed("cat /home/alice/.config/desktop-ssh/config.json"))
    assert metadata["public_key"] == "${fixtures}/ssh.pub"
    machine.fail(user("cat /run/secrets/desktop-ssh-source"))
    machine.fail(user("desktop-ssh-session-active alice"))
    machine.fail(user("systemctl --no-ask-password start desktop-ssh-provision.service"))
    machine.succeed(user("systemctl --user start fixture-graphical.target"))
    machine.fail(user("systemctl --user is-active desktop-ssh-agent.service"))
    machine.succeed(user("systemctl --user stop fixture-graphical.target"))
    # A genuine logind tty session remains ineligible.
    machine.succeed("systemctl stop getty@tty1.service")
    machine.succeed("systemd-run --unit=fixture-tty --property=Type=exec --property=User=alice --property=PAMName=tty-fixture --property=TTYPath=/dev/tty1 --property=StandardInput=tty-force /run/current-system/sw/bin/sleep infinity")
    machine.fail(user("desktop-ssh-session-active alice"))
    machine.succeed("systemctl stop fixture-tty")
    # PAM creates a real local graphical logind session on the active seat.
    machine.succeed("chvt 1; systemd-run --unit=fixture-graphical --property=Type=exec --property=User=alice --property=PAMName=graphical-fixture --property=TTYPath=/dev/tty1 --property=StandardInput=tty-force /run/current-system/sw/bin/sleep infinity")
    wait_graphical()
    machine.succeed("chvt 2")
    machine.fail(user("desktop-ssh-session-active alice"))
    machine.fail(user("systemctl --no-ask-password start desktop-ssh-provision.service"))
    machine.succeed("chvt 1")
    wait_graphical()
    machine.succeed(user("systemctl --user start fixture-wallet.service fixture-graphical.target"))
    machine.wait_until_succeeds(user("test -S /run/user/1000/desktop-ssh/agent.sock"))
    machine.fail(user("systemctl --no-ask-password start desktop-ssh-provision.service", "bob"))
    machine.fail(user("systemctl --no-ask-password set-property desktop-ssh-provision.service Environment=ATTACK=yes"))
    machine.fail(user("systemd-run --unit=desktop-ssh-provision.service /run/current-system/sw/bin/true"))
    machine.succeed(user("touch /home/alice/wallet-locked"))
    machine.fail(user("systemctl --no-ask-password start desktop-ssh-provision.service"))
    machine.fail("test -e /home/alice/.ssh/id_ed25519_nix_config")
    machine.succeed(user("rm /home/alice/wallet-locked"))
    # This caller has no PAM/logind session of its own; the account's active
    # local graphical session authorizes this fixed service operation.
    machine.succeed(user("sh -c 'test -z \"$XDG_SESSION_ID\"'"))
    try:
        machine.succeed(user("systemctl --no-ask-password start desktop-ssh-provision.service"))
    except Exception:
        print(machine.succeed("journalctl -u desktop-ssh-provision --no-pager; stat -Lc 'SSH directory metadata uid=%u mode=%a nlink=%h type=%F' /home/alice/.ssh; for state in /home/alice/.ssh/.desktop-ssh.lock /home/alice/.ssh/id_ed25519_nix_config; do if test -e \"$state\"; then stat -Lc 'SSH state metadata uid=%u mode=%a nlink=%h type=%F' \"$state\"; fi; done"))
        raise
    machine.succeed("test $(stat -c '%a:%U' /home/alice/.ssh/id_ed25519_nix_config) = 600:alice")
    # Read the native API's fake-wallet state and decrypt the actual encrypted output.
    machine.succeed(user("${python}/bin/python3 -c \"import json; from pathlib import Path; from cryptography.hazmat.primitives.serialization import load_ssh_private_key; p=next(iter(json.loads(Path('/home/alice/wallet.json').read_text()).values())); load_ssh_private_key(Path('/home/alice/.ssh/id_ed25519_nix_config').read_bytes(),p.encode())\""))
    machine.succeed(user("${python}/bin/python3 ${sign} success"))
    machine.succeed(user("touch /home/alice/wallet-locked"))
    # Cached signing survives a newly locked wallet in the same login session.
    machine.succeed(user("${python}/bin/python3 ${sign} success"))
    # Working-state loss invalidates the cached key before another signature.
    machine.succeed(user("rm /home/alice/.ssh/id_ed25519_nix_config"))
    machine.succeed(user("${python}/bin/python3 ${sign} failure"))
    machine.fail("test -e /home/alice/.ssh/id_ed25519_nix_config")
    machine.succeed(user("rm /home/alice/wallet-locked"))
    machine.succeed(user("${python}/bin/python3 ${sign} success"))
    machine.succeed(user("systemctl --user stop fixture-graphical.target"))
    machine.fail(user("test -S /run/user/1000/desktop-ssh/agent.sock"))
    machine.succeed("systemctl stop fixture-graphical")
    machine.fail(user("desktop-ssh-session-active alice"))
    machine.fail(user("systemctl --no-ask-password start desktop-ssh-provision.service"))
    machine.succeed(user("systemctl --user start fixture-graphical.target"))
    machine.fail(user("systemctl --user is-active desktop-ssh-agent.service"))
  '';
}
