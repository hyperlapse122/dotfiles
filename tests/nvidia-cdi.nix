{ pkgs }:
let
  driver = pkgs.runCommand "nvidia-cdi-test-driver" { version = "999.1"; } ''
    mkdir -p $out/lib
  '';
  toolkit =
    pkgs.runCommand "nvidia-cdi-test-toolkit"
      {
        outputs = [
          "out"
          "tools"
        ];
      }
      ''
        mkdir -p $out/bin $tools/bin
        cat > $out/bin/nvidia-ctk <<'EOF'
        #!${pkgs.runtimeShell}
        echo invoked >> /run/nvidia-cdi-test/invocations
        if [ -e /run/nvidia-cdi-test/fail ]; then
          echo 'fixture: generator failed' >&2
          exit 1
        fi
        echo '{"devices":[{"name":"fixture-gpu"}],"containerEdits":{"mounts":[]}}'
        EOF
        chmod +x $out/bin/nvidia-ctk
      '';
in
pkgs.testers.nixosTest {
  name = "nvidia-cdi";
  nodes.machine = {
    imports = [ ../modules/nixos/hardware/nvidia.nix ];
    hardware.nvidia.package = driver;
    hardware.nvidia-container-toolkit = {
      enable = true;
      suppressNvidiaDriverAssertion = true;
      package = toolkit;
      mount-nvidia-executables = false;
    };
    systemd.tmpfiles.rules = [
      "d /run/nvidia-cdi-test 0755 root root -"
      "d /run/nvidia-cdi-test/module 0755 root root -"
      "f /run/nvidia-cdi-test/module/version 0644 root root - 999.0"
    ];
    # Give the real service a loaded-driver version without a GPU in the VM.
    systemd.services.nvidia-container-toolkit-cdi-generator.serviceConfig = {
      TemporaryFileSystem = "/sys/module";
      BindReadOnlyPaths = [ "/run/nvidia-cdi-test/module:/sys/module/nvidia" ];
    };
  };
  testScript = ''
    import json

    machine.wait_for_unit("multi-user.target")
    unit = "nvidia-container-toolkit-cdi-generator.service"
    spec = "/run/cdi/nvidia-container-toolkit.json"
    calls = "/run/nvidia-cdi-test/invocations"

    with subtest("a driver upgrade defers CDI without failing activation"):
        machine.succeed("systemctl start " + unit)
        assert machine.succeed("systemctl show -P ActiveState " + unit).strip() == "inactive"
        machine.fail("systemctl is-failed " + unit)
        machine.fail("test -e " + calls)
        machine.fail("test -e " + spec)
        assert "reboot" in machine.succeed("journalctl -b -u " + unit)

    with subtest("a matching loaded driver generates CDI"):
        machine.succeed("echo 999.1 > /run/nvidia-cdi-test/module/version")
        machine.succeed("systemctl start " + unit)
        machine.wait_for_unit(unit)
        assert json.loads(machine.succeed("cat " + spec))["devices"][0]["name"] == "fixture-gpu"
        assert machine.succeed("wc -l < " + calls).strip() == "1"

    with subtest("restarting after an upgrade removes the obsolete CDI spec"):
        machine.succeed("echo 999.2 > /run/nvidia-cdi-test/module/version")
        machine.succeed("systemctl restart " + unit)
        machine.fail("systemctl is-failed " + unit)
        machine.fail("test -e " + spec)
        assert machine.succeed("wc -l < " + calls).strip() == "1"
        machine.succeed("echo 999.1 > /run/nvidia-cdi-test/module/version")

    with subtest("unrelated generator failures still fail the service"):
        machine.succeed("touch /run/nvidia-cdi-test/fail")
        machine.fail("systemctl restart " + unit)
        assert machine.succeed("systemctl show -P Result " + unit).strip() == "exit-code"
        assert machine.succeed("wc -l < " + calls).strip() == "2"

    with subtest("an absent driver still reaches the generator"):
        machine.succeed("rm /run/nvidia-cdi-test/module/version")
        machine.succeed("systemctl reset-failed " + unit)
        machine.fail("systemctl start " + unit)
        assert machine.succeed("systemctl show -P Result " + unit).strip() == "exit-code"
        assert machine.succeed("wc -l < " + calls).strip() == "3"
  '';
}
