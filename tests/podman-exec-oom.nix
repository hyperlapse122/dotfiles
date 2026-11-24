/*
  Check interface:

    import ./tests/podman-exec-oom.nix { inherit pkgs; }

  Boots a node with the NixOS Podman module and a lingering user manager for
  h82, starts h82's Podman API socket, and creates a container through the
  Docker-compatible API the way Testcontainers does. That API always stores
  an explicit oom_score_adj (0 when the client sends none), which is below
  the floor of 100 the user manager inherits from user@.service, so an
  unprivileged exec that writes it is refused. Asserts that the container
  starts, that an exec through the API exits 0, and that
  `podman healthcheck run`, the local exec path systemd's health check timer
  uses, reports the container healthy.

  Every Podman and systemctl --user command runs through runuser with the
  user manager's XDG_RUNTIME_DIR, never su -, so the loaded image and the
  service share one run root.
*/
{ pkgs }:
let
  image = pkgs.dockerTools.buildImage {
    name = "exec-oom";
    tag = "latest";
    copyToRoot = pkgs.buildEnv {
      name = "exec-oom-image-root";
      paths = [ pkgs.busybox ];
      pathsToLink = [ "/bin" ];
    };
    config.Cmd = [
      "/bin/sleep"
      "600"
    ];
  };

  createBody = builtins.toJSON {
    Image = "localhost/exec-oom:latest";
    HostConfig.NetworkMode = "none";
    Healthcheck = {
      Test = [
        "CMD"
        "/bin/true"
      ];
      Interval = 3600000000000;
    };
  };
  execBody = builtins.toJSON {
    Cmd = [ "/bin/true" ];
    AttachStdout = true;
    AttachStderr = true;
  };
in
pkgs.testers.nixosTest {
  name = "podman-exec-oom";
  nodes.machine =
    { ... }:
    {
      imports = [
        ../modules/nixos/services/podman.nix
        ../modules/shared/host.nix
      ];
      my.user.name = "h82";
      users.users.h82 = {
        isNormalUser = true;
        uid = 1000;
        linger = true;
      };
      my.podman.enable = true;
      environment.systemPackages = [ pkgs.curl ];
      virtualisation.memorySize = 1536;
    };
  testScript = ''
    import json

    def user(command):
        return "runuser -u h82 -- env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus " + command

    def api(method, path, body=None):
        command = "curl -sS --fail-with-body --unix-socket /run/user/1000/podman/podman.sock -X " + method
        if body is not None:
            command += " -H 'Content-Type: application/json' -d '" + body + "'"
        return machine.succeed(user(command + " http://d/v1.41" + path))

    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("user@1000.service")
    machine.succeed(user("podman load -i ${image}"))
    machine.succeed(user("systemctl --user start podman.socket"))

    # The user manager pins the floor every user service inherits.
    floor = int(machine.succeed(user("systemd-run --user --wait --pipe --quiet cat /proc/self/oom_score_adj")).strip())
    assert floor > 0, f"user services run at oom_score_adj {floor}, so this test cannot see the floor"

    created = json.loads(api("POST", "/containers/create?name=probe", ${builtins.toJSON createBody}))
    api("POST", "/containers/" + created["Id"] + "/start")

    execId = json.loads(api("POST", "/containers/probe/exec", ${builtins.toJSON execBody}))["Id"]
    print(api("POST", "/exec/" + execId + "/start", '{"Detach":false}'))
    exitCode = json.loads(api("GET", "/exec/" + execId + "/json"))["ExitCode"]
    assert exitCode == 0, f"exec through the compat API exited {exitCode}"

    machine.succeed(user("podman healthcheck run probe"))
    assert machine.succeed(user("podman inspect -f '{{.State.Health.Status}}' probe")).strip() == "healthy"
  '';
}
