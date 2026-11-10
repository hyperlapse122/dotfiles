{ pkgs, inputs }:
let
  fixtures =
    pkgs.runCommand "fake-auth-secrets"
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
        # tokscale_token, synthetic_api_key, exa_api_key, and
        # openrouter_api_key carry a space,
        # which publish-cli-auth rejects, so gh and glab publication fails here
        # if the publisher ever starts reading any of them.
        printf 'github_token: FAKE_github\ngitlab_token: FAKE_gitlab\njpi_token: FAKE_jpi\ntokscale_token: FAKE tokscale\nsynthetic_api_key: FAKE pi\nexa_api_key: FAKE exa\nopenrouter_api_key: FAKE openrouter\n' > plain.yaml
        sops --encrypt --age "$recipient" --input-type yaml --output-type yaml plain.yaml > $out/tokens.yaml
      '';
in
pkgs.testers.nixosTest {
  name = "auth-provisioning";
  nodes.missing = { ... }: {
    imports = [
      inputs.sops-nix.nixosModules.sops
      ../modules/nixos/system/secrets.nix
    ];
    system.switch.enable = true;
    boot.loader.grub.enable = pkgs.lib.mkForce false;
    users.users.h82.isNormalUser = true;
    my.cliAuth = {
      enable = true;
      sopsFile = null;
    };
  };
  nodes.machine = { ... }: {
    imports = [
      inputs.sops-nix.nixosModules.sops
      ../modules/nixos/system/secrets.nix
    ];
    system.switch.enable = true;
    boot.loader.grub.enable = pkgs.lib.mkForce false;
    users.users.h82 = {
      isNormalUser = true;
      uid = 1000;
    };
    my.cliAuth = {
      enable = true;
      sopsFile = "${fixtures}/tokens.yaml";
      enableTokscaleToken = true;
      enableSyntheticApiKey = true;
      enableExaApiKey = true;
      enableOpenRouterApiKey = true;
    };
    # Deliberately public fake key. Production never embeds a real key in the store.
    system.activationScripts.fixture = ''
      install -d -m 0700 /var/lib/sops-nix
      if [ ! -e /var/lib/sops-nix/fixture-initialized ]; then
        install -m 0600 ${fixtures}/key.txt /var/lib/sops-nix/key.txt
        touch /var/lib/sops-nix/fixture-initialized
      fi
    '';
    environment.systemPackages = [
      (import ../packages/gpg-tools.nix { inherit pkgs; }).restoreAgeIdentity
      pkgs.age
      pkgs.python3
      pkgs.gh
      pkgs.glab
    ];
    virtualisation.memorySize = 1536;
  };
  testScript = ''
    import json
    missing.start()
    missing.wait_for_unit("multi-user.target")
    missing.succeed("test -x /run/current-system/bin/switch-to-configuration")
    missing.fail("/run/current-system/bin/switch-to-configuration switch")
    missing.succeed("journalctl -u sops-install-secrets --no-pager | grep -q 'prepare secrets/tokens.yaml'")
    missing.fail("test -e /home/h82/.config/gh/hosts.yml")
    machine.start()
    machine.wait_for_unit("multi-user.target")
    gh = "/home/h82/.config/gh/hosts.yml"
    glab = "/home/h82/.config/glab-cli/config.yml"
    switch = "/run/current-system/bin/switch-to-configuration switch"
    def verify():
        config = json.loads(machine.succeed("cat " + gh))
        assert config["github.com"]["oauth_token"] == "FAKE_github"
        hosts = json.loads(machine.succeed("cat " + glab))["hosts"]
        assert hosts["gitlab.com"]["token"] == "FAKE_gitlab"
        assert hosts["git.jpi.app"]["token"] == "FAKE_jpi"
        machine.succeed("test $(stat -c '%a:%U' " + gh + ") = 600:h82")
        machine.succeed("test ! -L " + gh)
        tokscale = "/run/secrets/cli-auth/tokscale_token"
        machine.succeed("runuser -u h82 -- cat " + tokscale + " | grep -qx 'FAKE tokscale'")
        machine.succeed("test $(stat -L -c '%a:%U' " + tokscale + ") = 400:h82")
        pi_key = "/run/secrets/cli-auth/synthetic_api_key"
        machine.succeed("runuser -u h82 -- cat " + pi_key + " | grep -qx 'FAKE pi'")
        machine.succeed("test $(stat -L -c '%a:%U' " + pi_key + ") = 400:h82")
        exa = "/run/secrets/cli-auth/exa_api_key"
        machine.succeed("runuser -u h82 -- cat " + exa + " | grep -qx 'FAKE exa'")
        machine.succeed("test $(stat -L -c '%a:%U' " + exa + ") = 400:h82")
        openrouter = "/run/secrets/cli-auth/openrouter_api_key"
        machine.succeed("runuser -u h82 -- cat " + openrouter + " | grep -qx 'FAKE openrouter'")
        machine.succeed("test $(stat -L -c '%a:%U' " + openrouter + ") = 400:h82")
    verify()
    machine.succeed(switch)
    verify()
    machine.succeed("rm " + gh)
    machine.succeed(switch)
    verify()
    machine.succeed("mv /var/lib/sops-nix/key.txt /var/lib/sops-nix/key.backup")
    machine.fail(switch)
    machine.succeed("restore-age-identity --recipient $(age-keygen -y /var/lib/sops-nix/key.backup) < /var/lib/sops-nix/key.backup")
    machine.succeed("test $(stat -c '%a:%U:%G' /var/lib/sops-nix/key.txt) = 600:root:root")
    machine.succeed(switch)
    verify()
    machine.succeed("printf invalid > /var/lib/sops-nix/key.txt")
    machine.fail(switch)
    machine.succeed("restore-age-identity --recipient $(age-keygen -y /var/lib/sops-nix/key.backup) < /var/lib/sops-nix/key.backup")
    machine.succeed("test $(stat -c '%a:%U:%G' /var/lib/sops-nix/key.txt) = 600:root:root")
    machine.succeed(switch)
    verify()
    machine.succeed("rm -r /home/h82/.config/gh")
    machine.succeed("mkdir /root/protected; ln -s /root/protected /home/h82/.config/gh")
    machine.fail(switch)
    machine.succeed("test -z \"$(ls -A /root/protected)\"")
    machine.succeed("rm /home/h82/.config/gh")
    machine.succeed(switch)
    verify()
    machine.succeed("runuser -u h82 -- gh auth token --hostname github.com | grep -qx FAKE_github")
    machine.succeed("runuser -u h82 -- glab config get token --host gitlab.com | grep -qx FAKE_gitlab")
    machine.succeed("runuser -u h82 -- glab config get token --host git.jpi.app | grep -qx FAKE_jpi")
    journal_output = machine.succeed("journalctl -u sops-install-secrets --no-pager")
    assert "FAKE_github" not in journal_output and "FAKE_gitlab" not in journal_output and "FAKE_jpi" not in journal_output
    assert "FAKE tokscale" not in journal_output
    assert "FAKE pi" not in journal_output
    assert "FAKE exa" not in journal_output
    assert "FAKE openrouter" not in journal_output
  '';
}
