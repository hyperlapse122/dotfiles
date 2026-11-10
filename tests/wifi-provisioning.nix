{ pkgs, inputs }:
let
  fixtures =
    pkgs.runCommand "fake-wifi-secrets"
      {
        nativeBuildInputs = [
          pkgs.age
          pkgs.sops
        ];
      }
      ''
        mkdir -p $out
        age-keygen -o $out/key.txt
        recipient=$(age-keygen -y $out/key.txt)
        cat > plain.yaml <<'EOF'
        wifi:
          home:
            ssid: TestHomeNet
            psk: FAKE_home_psk_1
          office:
            ssid: TestOfficeNet
            psk: FAKE_office_psk_2
        EOF
        sops --encrypt --age "$recipient" --input-type yaml --output-type yaml plain.yaml > $out/wifi.yaml
      '';
in
pkgs.testers.nixosTest {
  name = "wifi-provisioning";
  nodes.missing = { ... }: {
    imports = [
      inputs.sops-nix.nixosModules.sops
      ../modules/nixos/system/secrets.nix
      ../modules/nixos/wifi.nix
    ];
    system.switch.enable = true;
    boot.loader.grub.enable = pkgs.lib.mkForce false;
    networking.networkmanager.enable = true;
    my.wifi = {
      sopsFile = null;
      networks = [
        "home"
        "office"
      ];
    };
  };
  nodes.machine = { ... }: {
    imports = [
      inputs.sops-nix.nixosModules.sops
      ../modules/nixos/system/secrets.nix
      ../modules/nixos/wifi.nix
    ];
    system.switch.enable = true;
    boot.loader.grub.enable = pkgs.lib.mkForce false;
    networking.networkmanager.enable = true;
    my.wifi = {
      sopsFile = "${fixtures}/wifi.yaml";
      networks = [
        "home"
        "office"
      ];
    };
    # Deliberately public fake key. Production never embeds a real key in the store.
    system.activationScripts.fixture = ''
      install -d -m 0700 /var/lib/sops-nix
      if [ ! -e /var/lib/sops-nix/fixture-initialized ]; then
        install -m 0600 ${fixtures}/key.txt /var/lib/sops-nix/key.txt
        touch /var/lib/sops-nix/fixture-initialized
      fi
    '';
  };
  testScript = ''
    missing.start()
    missing.wait_for_unit("multi-user.target")
    missing.succeed("test -x /run/current-system/bin/switch-to-configuration")
    missing.succeed("/run/current-system/bin/switch-to-configuration switch")
    missing.fail("nmcli connection show home")
    missing.fail("nmcli connection show office")
    missing.fail("test -e /run/NetworkManager/system-connections/home.nmconnection")

    machine.start()
    machine.wait_for_unit("multi-user.target")
    switch = "/run/current-system/bin/switch-to-configuration switch"
    home_keyfile = "/run/NetworkManager/system-connections/home.nmconnection"
    office_keyfile = "/run/NetworkManager/system-connections/office.nmconnection"

    def verify():
        home = machine.succeed("cat " + home_keyfile)
        office = machine.succeed("cat " + office_keyfile)
        assert "ssid=TestHomeNet" in home
        assert "psk=FAKE_home_psk_1" in home
        assert "TestOfficeNet" not in home and "FAKE_office_psk_2" not in home
        assert "ssid=TestOfficeNet" in office
        assert "psk=FAKE_office_psk_2" in office
        assert "TestHomeNet" not in office and "FAKE_home_psk_1" not in office
        for f, content in [(home_keyfile, home), (office_keyfile, office)]:
            machine.succeed("test $(stat -c '%a:%U' " + f + ") = 600:root")
            assert "dns=" not in content
            assert "gateway=" not in content
            assert "route" not in content

    verify()
    machine.succeed(switch)
    verify()

    store_grep = machine.execute(
        "nix-store -qR /run/current-system | xargs grep -rl FAKE_home_psk_1 2>/dev/null || true"
    )[1]
    assert store_grep.strip() == "", "fixture PSK leaked into the built system closure: " + store_grep
  '';
}
