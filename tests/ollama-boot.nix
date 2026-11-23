{ pkgs }:
pkgs.testers.nixosTest {
  name = "ollama-boot";
  nodes.machine = { pkgs, ... }: {
    imports = [
      ../modules/shared/host.nix
      ../modules/nixos/services/ollama.nix
      ../modules/nixos/services/minikube.nix
    ];
    services.ollama.package = pkgs.ollama;
    nixpkgs.overlays = [
      (final: prev: {
        ollama = final.writeShellScriptBin "ollama" ''
          exec ${final.python3}/bin/python3 ${final.writeText "slow-ollama.py" ''
            from http.server import BaseHTTPRequestHandler, HTTPServer
            from time import sleep

            class Handler(BaseHTTPRequestHandler):
                def do_GET(self):
                    sleep(60)
                    self.send_response(200)
                    self.end_headers()
                    self.wfile.write(b'{"models": []}')

            HTTPServer(("127.0.0.1", 11434), Handler).serve_forever()
          ''}
        '';
        minikube = final.writeShellScriptBin "minikube" ''
          echo "$1" >> "$HOME/minikube-events"
        '';
      })
    ];
    my.user.name = "owner";
    my.minikube.enable = true;
    systemd.user.targets.test-session = {
      description = "Test desktop session";
      bindsTo = [ "graphical-session.target" ];
    };
    users.users.owner = {
      isNormalUser = true;
      uid = 1000;
    };
    users.users.other = {
      isNormalUser = true;
      uid = 1001;
      linger = true;
    };
  };
  testScript = ''
    def user(command, name="owner", uid="1000"):
        return "runuser -u " + name + " -- env XDG_RUNTIME_DIR=/run/user/" + uid + " DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/" + uid + "/bus " + command

    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("user@1000.service")
    machine.wait_for_unit("user@1001.service")
    machine.wait_until_succeeds(user("systemctl --user is-active ollama.service"))
    machine.wait_until_succeeds(user("systemctl --user show ollama-provision.service -p ActiveState --value") + " | grep -qx activating")
    machine.succeed(user("systemctl --user is-active default.target"))
    machine.succeed("test ! -e /home/owner/minikube-events")
    machine.fail(user("systemctl --user is-active minikube.service"))
    machine.succeed(user("systemctl --user start test-session.target"))
    machine.wait_until_succeeds("grep -qx start /home/owner/minikube-events")
    machine.succeed(user("systemctl --user stop test-session.target"))
    machine.wait_until_succeeds("grep -qx stop /home/owner/minikube-events")
    machine.succeed(user("systemctl --user is-active ollama.service"))
    machine.fail(user("systemctl --user is-active ollama.service", name="other", uid="1001"))
    machine.succeed(user("systemctl --user show ollama.service -p ConditionResult --value", name="other", uid="1001") + " | grep -qx no")
  '';
}
