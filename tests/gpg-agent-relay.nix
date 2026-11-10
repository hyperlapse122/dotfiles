/*
  VM check interface:

    import ./tests/gpg-agent-relay.nix { inherit pkgs inputs; }

  Boots a machine whose user imports home/h82/security/gpg.nix with
  `my.gpgAgentRelay` pointing at a stub agent on 127.0.0.1, standing in for
  the remote host's relay. The stub speaks just enough Assuan to answer
  `GETINFO version` and counts the TCP connections that send it, so a bare
  port probe is never counted.

  Verifies, in the user's systemd session (no graphical session):
  - `gpg-connect-agent 'GETINFO version'` gets the stub's version through the
    socket at gpg's agent-socket path, so gpg reaches the remote agent.
  - two such calls reach the stub as two TCP connections, so a lost stream
    does not outlive the request that used it.
  - with the stub stopped, a gpg signing call fails, and the socket stays in
    place for the next call.
  - with the relay socket stopped, so nothing holds the agent-socket path, a
    gpg signing call starts no gpg-agent for the user: gpg.conf's
    no-autostart keeps a local agent from taking the relay's path.
  - with the stub and socket back, the next call succeeds without restarting
    anything else.
*/
{ pkgs, inputs }:
let
  port = 4321;
  stub = pkgs.writeText "gpg-agent-stub.py" ''
    import pathlib, socketserver, threading
    count = pathlib.Path("/tmp/stub-connections")
    count.write_text("0")
    lock = threading.Lock()
    class Agent(socketserver.StreamRequestHandler):
        def handle(self):
            counted = False
            self.wfile.write(b"OK Pleased to meet you\n")
            for line in self.rfile:
                if line.startswith(b"GETINFO version"):
                    if not counted:
                        counted = True
                        with lock:
                            count.write_text(str(int(count.read_text()) + 1))
                    self.wfile.write(b"D 9.9.9-relay-stub\nOK\n")
                elif line.startswith(b"BYE"):
                    self.wfile.write(b"OK closing connection\n")
                    return
                else:
                    self.wfile.write(b"OK\n")
    socketserver.ThreadingTCPServer.allow_reuse_address = True
    socketserver.ThreadingTCPServer(("127.0.0.1", ${toString port}), Agent).serve_forever()
  '';
in
pkgs.testers.nixosTest {
  name = "gpg-agent-relay";
  nodes.machine =
    { config, lib, ... }:
    {
      imports = [
        inputs.home-manager.nixosModules.home-manager
        ../modules/shared/host.nix
      ];
      my.hostName = "relay-fixture";
      my.gpgAgentRelay = {
        enable = true;
        endpoint = "127.0.0.1:${toString port}";
      };
      users.users.h82 = {
        isNormalUser = true;
        uid = 1000;
      };
      home-manager.useGlobalPkgs = true;
      home-manager.users.h82 = {
        imports = [
          ../modules/shared/host.nix
          ../home/h82/security/gpg.nix
        ];
        my = (import ../lib/host-facts.nix { inherit lib; }).of config.my;
        home = {
          username = "h82";
          homeDirectory = "/home/h82";
          stateVersion = "25.11";
        };
      };
      systemd.services.agent-stub = {
        serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 ${stub}";
      };
      environment.systemPackages = [ pkgs.gnupg ];
    };
  testScript = ''
    machine.start()
    machine.wait_for_unit("multi-user.target")
    machine.succeed("loginctl enable-linger h82")
    machine.wait_for_unit("user@1000.service")
    machine.wait_for_unit("gpg-agent-relay.socket", "h82")

    def user(command):
        return "runuser -u h82 -- env XDG_RUNTIME_DIR=/run/user/1000 " + command

    socket = machine.succeed(user("gpgconf --list-dirs agent-socket")).strip()
    machine.succeed(f"test -S {socket}")

    machine.systemctl("start agent-stub.service")
    machine.wait_for_open_port(${toString port})
    before = int(machine.succeed("cat /tmp/stub-connections"))
    for _ in range(2):
        out = machine.succeed(user("gpg-connect-agent --no-autostart 'GETINFO version' /bye"))
        assert "9.9.9-relay-stub" in out, out
    after = int(machine.succeed("cat /tmp/stub-connections"))
    assert after - before == 2, (before, after)

    sign = user("sh -c 'echo data | gpg --batch --sign --local-user 0x4945855D4F283F05 >/dev/null'")
    machine.systemctl("stop agent-stub.service")
    machine.fail(sign)
    machine.succeed(f"test -S {socket}")

    machine.systemctl("stop gpg-agent-relay.socket", "h82")
    machine.fail(sign)
    machine.fail("pgrep -u h82 -x gpg-agent")
    machine.systemctl("start gpg-agent-relay.socket", "h82")

    machine.systemctl("start agent-stub.service")
    machine.wait_for_open_port(${toString port})
    out = machine.succeed(user("gpg-connect-agent --no-autostart 'GETINFO version' /bye"))
    assert "9.9.9-relay-stub" in out, out
  '';
}
