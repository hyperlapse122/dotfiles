{ pkgs }:
let
  desktopSSH = import ../packages/desktop-ssh.nix { inherit pkgs; };
  python = pkgs.python3.withPackages (ps: [
    ps.cryptography
    ps.bcrypt
    ps.dbus-python
  ]);
  library = pkgs.writeText "desktop-ssh-test-library.py" (builtins.readFile ./test_desktop_ssh.py);
  runner = pkgs.writeText "desktop-ssh-openssh-integration.py" ''
    import importlib.util
    import json
    import os
    from pathlib import Path
    import subprocess
    import time
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

    os.environ["DESKTOP_SSH_SCRIPT"] = "${desktopSSH}/bin/desktop-ssh"
    spec = importlib.util.spec_from_file_location("library", "${library}")
    lib = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(lib)
    helper = lib.desktop_ssh
    runtime = Path("/run/user/0")
    runtime.mkdir(mode=0o700, parents=True, exist_ok=True)
    runtime.chmod(0o700)
    (runtime / "desktop-ssh").mkdir(mode=0o700, exist_ok=True)
    config_dir = Path.home() / ".config/desktop-ssh"
    config_dir.mkdir(parents=True, mode=0o700, exist_ok=True)
    primary_key, fallback_key, other_fallback = [Ed25519PrivateKey.generate() for _ in range(3)]
    public = runtime / "primary.pub"
    public.write_bytes(helper.public_bytes(primary_key.public_key()))
    primary_path = runtime / "desktop-ssh/agent.sock"
    fallback_path = runtime / "fallback.sock"
    config_dir.joinpath("config.json").write_text(json.dumps({
        "public_key": str(public), "key_file": str(runtime / "protected"),
        "fallback_socket": str(fallback_path)}))
    primary = lib.FakeAgent(primary_path, [primary_key])
    fallback = None
    authorized = Path("/tmp/desktop-ssh-authorized")
    def allow(key):
        authorized.write_bytes(helper.public_bytes(key.public_key()) + b"\n")
    # Mirror the declared IdentityFile so a default fallback .pub cannot skip
    # primary signing in the failure cases; the config case removes this override.
    common = ["-F", "/dev/null", "-oStrictHostKeyChecking=no",
              "-oUserKnownHostsFile=/dev/null", "-oBatchMode=yes",
              "-oIdentityFile=" + str(public),
              "-oPreferredAuthentications=publickey"]
    ssh = "${desktopSSH}/bin/ssh"
    def run(arguments, **kwargs):
        result = subprocess.run(arguments, text=True, capture_output=True, timeout=15, **kwargs)
        assert result.returncode == 0, (arguments, result.returncode, result.stderr)
        return result.stdout
    def remote(command, **kwargs):
        return run([ssh] + common + ["root@localhost", command], **kwargs)
    def wait_children():
        for _ in range(100):
            if not list(runtime.glob("desktop-ssh-invocation-*")):
                return
            time.sleep(.03)
        raise AssertionError("invocation sockets survived SSH parents")
    try:
        # All packaged transports authenticate with 1Password absent.
        allow(primary_key)
        assert remote("printf primary") == "primary"
        Path("/tmp/source-file").write_text("scp-proof")
        run(["${desktopSSH}/bin/scp"] + common +
            ["/tmp/source-file", "root@localhost:/tmp/scp-proof"])
        assert Path("/tmp/scp-proof").read_text() == "scp-proof"
        batch = Path("/tmp/sftp-batch")
        batch.write_text("put /tmp/source-file /tmp/sftp-proof\n")
        run(["${desktopSSH}/bin/sftp"] + common + ["-b", str(batch), "root@localhost"])
        assert Path("/tmp/sftp-proof").read_text() == "scp-proof"
        run(["${pkgs.git}/bin/git", "init", "--bare", "/tmp/remote.git"])
        env = dict(os.environ, GIT_SSH=ssh, GIT_SSH_VARIANT="ssh")
        run(["${pkgs.git}/bin/git", "-c", "core.sshCommand=" + ssh + " " + " ".join(common),
             "clone", "root@localhost:/tmp/remote.git", "/tmp/clone"], env=env)
        assert Path("/tmp/clone/.git").is_dir()
        wait_children()

        fallback = lib.FakeAgent(fallback_path, [fallback_key], stall=True)
        started = time.monotonic()
        assert remote("printf independent") == "independent"
        assert time.monotonic() - started < 4, "stalled fallback blocked primary"
        fallback.close()
        fallback = lib.FakeAgent(fallback_path, [other_fallback, fallback_key])
        # Materialized config includes primary metadata. Existing default public
        # files cannot lift a fallback identity ahead of that configured primary.
        ssh_dir = Path.home() / ".ssh"
        ssh_dir.mkdir(mode=0o700, exist_ok=True)
        ssh_dir.joinpath("id_ed25519.pub").write_bytes(helper.public_bytes(fallback_key.public_key()))
        ssh_dir.joinpath("config").write_text("Host *\n  IdentityFile " + str(public) + "\n")
        authorized.write_bytes(helper.public_bytes(primary_key.public_key()) + b"\n" +
                               helper.public_bytes(fallback_key.public_key()) + b"\n")
        old_signs = sum(request[:1] == b"\x0d" for request in fallback.requests)
        configured = [option for option in common[2:] if not option.startswith("-oIdentityFile=")]
        assert run([ssh] + configured + ["root@localhost", "printf configured-primary"]) == "configured-primary"
        assert sum(request[:1] == b"\x0d" for request in fallback.requests) == old_signs
        # The server rejects primary, then accepts fallback in the same invocation.
        # With MaxAuthTries=3, the accepted key is last after both rejected keys.
        allow(fallback_key)
        assert remote("printf fallback") == "fallback"
        assert any(request[:1] == b"\x0d" for request in fallback.requests)
        primary.deny = True
        # Server permits both: primary signing denial must still reach fallback.
        authorized.write_bytes(helper.public_bytes(primary_key.public_key()) + b"\n" +
                               helper.public_bytes(fallback_key.public_key()) + b"\n")
        primary_signs = sum(request[:1] == b"\x0d" for request in primary.requests)
        assert remote("printf wallet-unavailable") == "wallet-unavailable"
        assert sum(request[:1] == b"\x0d" for request in primary.requests) == primary_signs + 1
        primary.close()
        primary = lib.FakeAgent(primary_path, [primary_key], stall=True)
        started = time.monotonic()
        assert remote("printf stalled-primary-fallback") == "stalled-primary-fallback"
        assert any(request[:1] == b"\x0d" for request in primary.requests), "primary was not attempted"
        assert time.monotonic() - started < 14, "primary starved fallback authentication"
        primary.close()
        assert remote("printf agent-unavailable") == "agent-unavailable"
        # Failed remote operations execute once, with no post-login fallback retry.
        result = subprocess.run([ssh] + common + ["root@localhost",
            "printf once >> /tmp/executions; exit 23"], capture_output=True, timeout=15)
        assert result.returncode == 23
        assert Path("/tmp/executions").read_text() == "once"

        # Separate invocation peers retain actual SSH parents and their ancestry.
        old_count = len(fallback.peer_pids)
        children = [subprocess.Popen([ssh] + common + ["root@localhost", "sleep 8"],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) for _ in range(2)]
        for _ in range(100):
            peers = fallback.peer_pids[old_count:]
            if len(peers) >= 2:
                break
            time.sleep(.03)
        assert len(set(peers)) == 2, peers
        parent_pids = []
        for peer in peers:
            status = Path(f"/proc/{peer}/status").read_text()
            parent_pids.append(int(next(line.split()[1] for line in status.splitlines()
                                       if line.startswith("PPid:"))))
        assert set(parent_pids) == {child.pid for child in children}
        for child in children:
            child.terminate()
            child.wait(timeout=10)
        wait_children()
        fallback.deny = True
        result = subprocess.run([ssh] + common + ["root@localhost", "touch /tmp/never"],
                                capture_output=True, timeout=15)
        assert result.returncode != 0 and not Path("/tmp/never").exists()
        wait_children()
        print("OpenSSH primary/fallback, Git/scp/sftp, exactly-once and ancestry checks passed")
    finally:
        primary.close()
        if fallback is not None:
            fallback.close()
  '';
in
pkgs.testers.nixosTest {
  name = "desktop-ssh-integration";
  nodes.machine = { ... }: {
    services.openssh = {
      enable = true;
      settings = {
        LoginGraceTime = 15;
        PermitRootLogin = "prohibit-password";
        PasswordAuthentication = false;
        AuthorizedKeysFile = "/tmp/desktop-ssh-authorized";
        StrictModes = false;
        MaxAuthTries = 3;
      };
    };
    environment.systemPackages = [
      desktopSSH
      pkgs.git
    ];
    virtualisation.memorySize = 1024;
  };
  testScript = ''
    machine.start()
    machine.wait_for_unit("sshd.service")
    # Keep this fake client session's runtime alive across root SSH server logouts.
    machine.succeed("loginctl enable-linger root; systemctl start user@0.service")
    machine.succeed("${python}/bin/python3 ${runner}")
  '';
}
