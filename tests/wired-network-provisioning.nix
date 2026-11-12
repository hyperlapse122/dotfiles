/*
  VM check for the declared wired network profile.

  Every client has two NICs on different VLANs. The VLAN decides the NIC's
  QEMU MAC address (52:54:00:12:<vlan>:<machine>), so the declared adapter,
  eth2 on VLAN 2, has a MAC that eth1 does not share, and NetworkManager
  matches the permanent address, not one set from inside the guest. The wired
  fixtures are therefore generated per node with that MAC. The server node
  runs the DHCP server on VLAN 2; its pool and the fixture's static address
  never overlap, so an address tells which of the two a client got.

  - valid: carries the fixture address, prefix, gateway, and DNS on eth2 only,
    after the first boot and after a reboot, although its render is delayed
    past NetworkManager's start. Switching to a malformed file leaves the
    keyfile untouched and the link up.
  - malformed, undecryptable, noidentity: boot on a DHCP address and accept an
    SSH connection from the server. With the first two, sops-install-secrets
    still installs an unrelated secret.

  The identity and the unrelated secret come from tests/lib/fake-secrets.nix.
*/
{ pkgs, inputs }:
let
  inherit (pkgs) lib;
  fakeSecrets = import ./lib/fake-secrets.nix { inherit pkgs; };

  pad = n: lib.optionalString (n < 16) "0" + lib.toHexString n;
  nicMac = vlan: machine: lib.toLower "52:54:00:12:${pad vlan}:${pad machine}";

  wiredFixtures =
    mac:
    pkgs.runCommand "fake-wired-vm-secrets"
      {
        nativeBuildInputs = [
          pkgs.age
          pkgs.sops
        ];
      }
      ''
        mkdir -p $out
        recipient=$(cat ${fakeSecrets}/recipient.txt)
        other=$(age-keygen -y ${fakeSecrets}/other-key.txt)
        declare() {
          printf 'mac: ${mac}\nipv4_address: %s\nipv4_subnet_mask: 255.255.255.0\nipv4_router: 192.168.2.1\ndns_servers:\n  - 192.168.2.53\n  - 192.168.2.54\n' "$1"
        }
        declare 192.168.2.100 > valid.yaml
        declare not-an-address > malformed.yaml
        sops --encrypt --age "$recipient" --input-type yaml --output-type yaml valid.yaml > $out/valid.yaml
        sops --encrypt --age "$recipient" --input-type yaml --output-type yaml malformed.yaml > $out/malformed.yaml
        sops --encrypt --age "$other" --input-type yaml --output-type yaml valid.yaml > $out/undecryptable.yaml
      '';

  sshKeys = pkgs.runCommand "fake-wired-vm-ssh" { nativeBuildInputs = [ pkgs.openssh ]; } ''
    mkdir -p $out
    ssh-keygen -q -t ed25519 -N "" -C fake-wired-vm -f $out/id
  '';

  client =
    {
      file,
      identity ? true,
      specialisations ? { },
      slowRender ? false,
    }:
    { config, ... }:
    let
      fixtures = wiredFixtures (nicMac 2 config.virtualisation.test.nodeNumber);
    in
    {
      imports = [
        inputs.sops-nix.nixosModules.sops
        ../modules/shared/host.nix
        ../modules/nixos/system/secrets.nix
        ../modules/nixos/wired-network.nix
      ];
      system.switch.enable = true;
      boot.loader.grub.enable = lib.mkForce false;
      networking.networkmanager.enable = true;
      virtualisation.interfaces = {
        eth1.vlan = 1;
        eth2.vlan = 2;
      };
      my.hostName = config.networking.hostName;
      my.wiredNetwork = {
        enable = true;
        file = "${fixtures}/${file}.yaml";
      };
      specialisation = lib.mapAttrs (_: spec: {
        configuration.my.wiredNetwork.file = lib.mkForce "${fixtures}/${spec}.yaml";
      }) specialisations;
      # A render that outlasts NetworkManager's start shows the ordering: only
      # a unit ordered before NetworkManager is finished when it first scans.
      systemd.services.nixos-wired-network.serviceConfig.ExecStartPre =
        lib.mkIf slowRender "${pkgs.coreutils}/bin/sleep 8";
      services.openssh.enable = true;
      users.users.root.openssh.authorizedKeys.keyFiles = [ "${sshKeys}/id.pub" ];
      users.users.h82 = {
        isNormalUser = true;
        uid = 1000;
      };
      my.cliAuth = lib.mkIf identity {
        enable = true;
        sopsFile = "${fakeSecrets}/tokens.yaml";
      };
      # Deliberately public fake key. Production never embeds a real key in the store.
      system.activationScripts.fixture = lib.mkIf identity ''
        install -d -m 0700 /var/lib/sops-nix
        if [ ! -e /var/lib/sops-nix/fixture-initialized ]; then
          install -m 0600 ${fakeSecrets}/key.txt /var/lib/sops-nix/key.txt
          touch /var/lib/sops-nix/fixture-initialized
        fi
      '';
    };
in
pkgs.testers.nixosTest {
  name = "wired-network-provisioning";

  nodes.server =
    { ... }:
    {
      boot.loader.grub.enable = lib.mkForce false;
      virtualisation.interfaces.eth1.vlan = 2;
      networking.interfaces.eth1.ipv4.addresses = [
        {
          address = "192.168.2.1";
          prefixLength = 24;
        }
      ];
      networking.firewall.enable = false;
      services.dnsmasq = {
        enable = true;
        resolveLocalQueries = false;
        settings = {
          port = 0;
          interface = "eth1";
          bind-dynamic = true;
          dhcp-authoritative = true;
          dhcp-range = [ "192.168.2.150,192.168.2.199,12h" ];
        };
      };
    };

  nodes.valid = client {
    file = "valid";
    specialisations.malformed = "malformed";
    slowRender = true;
  };
  nodes.malformed = client { file = "malformed"; };
  nodes.undecryptable = client { file = "undecryptable"; };
  nodes.noidentity = client {
    file = "valid";
    identity = false;
  };

  testScript =
    { nodes, ... }:
    ''
      import re

      keyfile = "/run/NetworkManager/system-connections/wired-static.nmconnection"
      ssh = (
          "ssh -i /root/id -o BatchMode=yes -o StrictHostKeyChecking=no "
          + "-o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 "
      )
      macs = {
          "valid": "${nicMac 2 nodes.valid.virtualisation.test.nodeNumber}",
          "malformed": "${nicMac 2 nodes.malformed.virtualisation.test.nodeNumber}",
          "undecryptable": "${nicMac 2 nodes.undecryptable.virtualisation.test.nodeNumber}",
          "noidentity": "${nicMac 2 nodes.noidentity.virtualisation.test.nodeNumber}",
      }
      clients = [valid, malformed, undecryptable, noidentity]

      def unit_journal(machine):
          return machine.succeed("journalctl -u nixos-wired-network.service --no-pager -o cat")

      def warnings(machine):
          return machine.succeed(
              "journalctl -u nixos-wired-network.service -p warning --no-pager -o cat"
          )

      def ssh_from_server(address):
          server.succeed(ssh + "root@" + address + " true")

      def eth2_address(machine):
          machine.wait_until_succeeds("ip -4 -o addr show dev eth2 | grep -q 'inet '")
          out = machine.succeed("ip -4 -o addr show dev eth2")
          found = re.search(r"inet (\S+)/\d+", out)
          assert found, out
          return found.group(1)

      def verify_static(machine):
          machine.wait_until_succeeds(
              "ip -4 -o addr show dev eth2 | grep -q 'inet 192[.]168[.]2[.]100/24 '", timeout=120
          )
          assert machine.succeed("nmcli -t -f GENERAL.CONNECTION device show eth2").strip() == "GENERAL.CONNECTION:wired-static"
          assert "wired-static" not in machine.succeed("nmcli -t -f GENERAL.CONNECTION device show eth1")
          machine.fail("ip -4 -o addr show dev eth1 | grep -q '192[.]168[.]2[.]100'")
          assert "default via 192.168.2.1 dev eth2" in machine.succeed("ip -4 route show default")
          dns = machine.succeed("nmcli -t -f IP4.DNS device show eth2")
          assert sorted(re.findall(r"IP4.DNS\[\d+\]:(\S+)", dns)) == ["192.168.2.53", "192.168.2.54"], dns
          machine.succeed("test $(sysctl -n net.ipv6.conf.eth2.disable_ipv6) = 1")
          machine.succeed("test $(sysctl -n net.ipv6.conf.eth1.disable_ipv6) = 0")

      def verify_profile_files(machine, mac):
          machine.succeed("test $(stat -c '%a:%U' /run/NetworkManager) = 755:root")
          machine.succeed("test $(stat -c '%a:%U' /run/NetworkManager/system-connections) = 700:root")
          machine.succeed("test $(stat -c '%a:%U' " + keyfile + ") = 600:root")
          text = machine.succeed("cat " + keyfile)
          assert "id=wired-static" in text, text
          assert "mac-address=" + mac.upper() in text, text
          assert "address1=192.168.2.100/24,192.168.2.1" in text, text
          assert "dns=192.168.2.53;192.168.2.54;" in text, text
          assert "method=disabled" in text, text
          before = int(machine.succeed("systemctl show -p ActiveEnterTimestampMonotonic --value nixos-wired-network.service"))
          after = int(machine.succeed("systemctl show -p ActiveEnterTimestampMonotonic --value NetworkManager.service"))
          assert before <= after, "the profile was rendered after NetworkManager started"

      def verify_dhcp(machine):
          machine.wait_until_succeeds(
              "ip -4 -o addr show dev eth2 | grep -Eq 'inet 192[.]168[.]2[.]1[5-9][0-9]/'", timeout=120
          )
          assert "wired-static" not in machine.succeed("nmcli -t -f GENERAL.CONNECTION device show eth2")
          machine.fail("ip -4 -o addr show | grep -q '192[.]168[.]2[.]100'")
          machine.fail("test -e " + keyfile)
          dns = machine.succeed("nmcli -t -f IP4.DNS device show eth2")
          assert "192.168.2.53" not in dns and "192.168.2.54" not in dns, dns
          ssh_from_server(eth2_address(machine))

      def verify_unit_failed_open(machine):
          machine.succeed("systemctl is-active nixos-wired-network.service")
          assert machine.succeed("systemctl show -p SubState --value nixos-wired-network.service").strip() == "exited"
          assert machine.succeed("systemctl show -p Result --value nixos-wired-network.service").strip() == "success"

      def verify_other_secret_installed(machine):
          machine.wait_until_succeeds("test -f /run/secrets/cli-auth/github_token")
          machine.succeed("grep -qx FAKE-CANARY-github /run/secrets/cli-auth/github_token")
          assert machine.succeed("systemctl show -p Result --value sops-install-secrets.service").strip() == "success"

      start_all()
      server.wait_for_unit("dnsmasq.service")
      server.copy_from_host("${sshKeys}/id", "/root/id")
      server.succeed("chmod 600 /root/id")
      for machine in clients:
          machine.wait_for_unit("multi-user.target")

      with subtest("the declared adapter carries the declared address after boot and reboot"):
          verify_static(valid)
          verify_profile_files(valid, macs["valid"])
          ssh_from_server("192.168.2.100")
          verify_unit_failed_open(valid)
          assert warnings(valid) == "", warnings(valid)
          verify_other_secret_installed(valid)
          valid.shutdown()
          valid.start()
          valid.wait_for_unit("multi-user.target")
          verify_static(valid)
          verify_profile_files(valid, macs["valid"])
          ssh_from_server("192.168.2.100")

      with subtest("a malformed declaration leaves the host on DHCP and reachable"):
          verify_dhcp(malformed)
          verify_unit_failed_open(malformed)
          text = warnings(malformed)
          assert "ipv4_address" in text and "no wired profile was written" in text, text
          assert "not-an-address" not in unit_journal(malformed)
          verify_other_secret_installed(malformed)

      with subtest("an undecryptable declaration leaves the host on DHCP and reachable"):
          verify_dhcp(undecryptable)
          verify_unit_failed_open(undecryptable)
          text = warnings(undecryptable)
          assert "cannot decrypt" in text and "no wired profile was written" in text, text
          verify_other_secret_installed(undecryptable)

      with subtest("a host without the age identity boots on DHCP with the unit active"):
          verify_dhcp(noidentity)
          verify_unit_failed_open(noidentity)
          text = warnings(noidentity)
          assert "age identity" in text and "missing" in text, text

      with subtest("a switch to a malformed declaration keeps the running profile"):
          verify_static(valid)
          digest = valid.succeed("sha256sum " + keyfile)
          inode = valid.succeed("stat -c %i " + keyfile)
          invocation = valid.succeed("systemctl show -p InvocationID --value nixos-wired-network.service")
          assert warnings(valid) == "", warnings(valid)
          valid.succeed("/run/current-system/specialisation/malformed/bin/switch-to-configuration test")
          assert valid.succeed("systemctl show -p InvocationID --value nixos-wired-network.service") != invocation, \
              "the switch did not rerun the unit"
          text = warnings(valid)
          assert "ipv4_address" in text and "no wired profile was written" in text, text
          verify_unit_failed_open(valid)
          assert valid.succeed("sha256sum " + keyfile) == digest
          assert valid.succeed("stat -c %i " + keyfile) == inode
          verify_static(valid)
          valid.succeed("ping -c 1 -W 5 192.168.2.1")
          ssh_from_server("192.168.2.100")
    '';
}
