/*
  Check interface:

    import ./tests/intune-os-identity.nix { inherit pkgs; }

  Boots a node with the Intune trait on and asserts what tests/intune.nix
  cannot see from built outputs: what a running, wrapped Intune executable
  reads.

  - The device broker, started by its own unit, reads Ubuntu 24.04 from
    /etc/os-release, while a shell on the same machine reads NixOS.
  - The broker's mount namespace holds every mount point the machine has,
    plus the one bind over the os-release file. intune-agent judges disk
    encryption from its own /proc/mounts, so a wrapper that hid mounts would
    misreport it.
  - A console login leaves /run/intune/<uid>/pwquality, so pam_intune.so still
    loads from the wrapped package.
  - passwd, run by the user, refuses a new password that lacks a character
    class or is too short, and accepts one that meets the policy.
  - The user, who cannot enter a mount namespace without a user namespace,
    can still start the wrapped intune-agent and dsreg.

  /etc/os-release is an absolute symlink, so reading it through
  /proc/<pid>/root would resolve it in the reader's namespace and show NixOS
  under a working wrapper. Every read of the broker's view enters its mount
  namespace with nsenter instead.

  bubblewrap stays behind as the unit's main process, outside the namespace it
  creates, so the broker is found among the unit's processes by executable.
*/
{ pkgs }:
let
  initialPassword = "Initial#Passw0rd-vm";
  weakPassword = "lowercaseonlypassword";
  shortPassword = "Sh0rt#Pw-vm";
  strongPassword = "Str0ng#Passw0rd-vm2";
in
pkgs.testers.nixosTest {
  name = "intune-os-identity";
  nodes.machine =
    { ... }:
    {
      imports = [
        ../modules/nixos/services/intune.nix
        ../modules/shared/host.nix
      ];
      users.users.h82 = {
        isNormalUser = true;
        uid = 1000;
        inherit initialPassword;
      };
      my.intune.enable = true;
    };
  testScript = ''
    def mount_points(mountinfo):
        return {line.split()[4] for line in mountinfo.splitlines() if line.strip()}

    machine.wait_for_unit("multi-user.target")

    unit = "microsoft-identity-device-broker.service"
    machine.succeed("systemctl start " + unit)
    cgroup = machine.succeed("systemctl show -p ControlGroup --value " + unit).strip()
    broker = None
    for pid in machine.succeed("cat /sys/fs/cgroup" + cgroup + "/cgroup.procs").split():
        exe = machine.succeed("readlink /proc/" + pid + "/exe").strip()
        if exe.endswith("/libexec/intune-ubuntu-identity/microsoft-identity-device-broker"):
            broker = pid
    assert broker is not None, "the device broker unit runs no microsoft-identity-device-broker"
    inside = "nsenter --target " + broker + " --mount "

    seen = machine.succeed(inside + "cat /etc/os-release")
    assert "\nID=ubuntu\n" in seen and '\nVERSION_ID="24.04"\n' in seen, seen
    system = machine.succeed("cat /etc/os-release")
    assert "\nID=nixos\n" in "\n" + system, system

    target = machine.succeed("realpath /etc/os-release").strip()
    host = mount_points(machine.succeed("cat /proc/self/mountinfo"))
    namespace = mount_points(machine.succeed(inside + "cat /proc/self/mountinfo"))
    assert namespace - host == {target}, namespace - host
    assert host - namespace == set(), host - namespace

    machine.wait_until_tty_matches("1", "login: ")
    machine.send_chars("h82\n")
    machine.wait_until_tty_matches("1", "Password: ")
    machine.send_chars("${initialPassword}\n")
    machine.wait_for_file("/run/intune/1000/pwquality")

    session = "runuser -u h82 -- env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus "
    machine.succeed(session + "systemctl --user start intune-agent.service")
    machine.wait_until_succeeds("journalctl --no-pager _UID=1000 _SYSTEMD_USER_UNIT=intune-agent.service | grep -q 'version='", timeout=30)
    assert "Device Registration Status" in machine.succeed(session + "dsreg --status")

    change = "printf '%s\\n' {} | runuser -u h82 -- passwd"
    machine.fail(change.format("'${initialPassword}' '${weakPassword}' '${weakPassword}'"))
    machine.fail(change.format("'${initialPassword}' '${shortPassword}' '${shortPassword}'"))
    machine.succeed(change.format("'${initialPassword}' '${strongPassword}' '${strongPassword}'"))
  '';
}
