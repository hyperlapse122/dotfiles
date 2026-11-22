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
        # tokscale_token, synthetic_api_key, exa_api_key,
        # Agent API keys carry a space, which publish-cli-auth rejects if it
        # ever starts reading them while publishing gh and glab credentials.
        printf 'github_token: FAKE_github\ngitlab_token: FAKE_gitlab\njpi_token: FAKE_jpi\ntokscale_token: FAKE tokscale\nsynthetic_api_key: FAKE pi\nexa_api_key: FAKE exa\nopenrouter_api_key: FAKE openrouter\nopencode_go_api_key: FAKE opencode go\nopenai_api_key: FAKE openai\nanthropic_api_key: FAKE anthropic\n' > plain.yaml
        sops --encrypt --age "$recipient" --input-type yaml --output-type yaml plain.yaml > $out/tokens.yaml
        sed 's/^openai_api_key:.*/openai_api_key: FAKE rotated openai/' plain.yaml > rotated.yaml
        sops --encrypt --age "$recipient" --input-type yaml --output-type yaml rotated.yaml > $out/rotated.yaml
      '';
in
pkgs.testers.nixosTest {
  name = "auth-provisioning";
  nodes.missing = { ... }: {
    imports = [
      inputs.sops-nix.nixosModules.sops
      ../modules/shared/host.nix
      ../modules/nixos/system/secrets.nix
    ];
    system.switch.enable = true;
    boot.loader.grub.enable = pkgs.lib.mkForce false;
    my.user = {
      name = "alice";
      home = "/srv/workspace";
    };
    users.users.alice = {
      isNormalUser = true;
      home = "/srv/workspace";
    };
    my.cliAuth = {
      enable = true;
      sopsFile = null;
    };
  };
  nodes.machine = { lib, ... }: {
    imports = [
      inputs.sops-nix.nixosModules.sops
      ../modules/shared/host.nix
      ../modules/nixos/system/secrets.nix
      # The OpenCode release is a dynamically linked binary that the
      # production profile runs through nix-ld.
      ../modules/nixos/system/nix-ld.nix
    ];
    system.switch.enable = true;
    boot.loader.grub.enable = pkgs.lib.mkForce false;
    my.user = {
      name = "alice";
      home = "/srv/workspace";
    };
    users.users.alice = {
      home = "/srv/workspace";
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
      enableOpencodeGoApiKey = true;
      enableOpenaiApiKey = true;
      enableAnthropicApiKey = true;
    };
    specialisation.rotated.configuration.my.cliAuth.sopsFile = lib.mkForce "${fixtures}/rotated.yaml";
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
      (import ../packages/opencode.nix { inherit pkgs; })
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
    missing.fail("test -e /srv/workspace/.config/gh/hosts.yml")
    machine.start()
    machine.wait_for_unit("multi-user.target")
    unit = machine.succeed("systemctl show sops-install-secrets.service -p RequiresMountsFor --value")
    assert "/srv/workspace" in unit.split(), unit
    assert "/var/lib/sops-nix/key.txt" in unit.split(), unit
    gh = "/srv/workspace/.config/gh/hosts.yml"
    glab = "/srv/workspace/.config/glab-cli/config.yml"
    switch = "/run/current-system/bin/switch-to-configuration switch"
    def verify():
        config = json.loads(machine.succeed("cat " + gh))
        assert config["github.com"]["oauth_token"] == "FAKE_github"
        hosts = json.loads(machine.succeed("cat " + glab))["hosts"]
        assert hosts["gitlab.com"]["token"] == "FAKE_gitlab"
        assert hosts["git.jpi.app"]["token"] == "FAKE_jpi"
        machine.succeed("test $(stat -c '%a:%U' " + gh + ") = 600:alice")
        machine.succeed("test ! -L " + gh)
        machine.succeed("test $(stat -c '%a:%U' " + glab + ") = 600:alice")
        machine.succeed("runuser -u alice -- test -w " + gh + " -a -w " + glab)
        tokscale = "/run/secrets/cli-auth/tokscale_token"
        machine.succeed("runuser -u alice -- cat " + tokscale + " | grep -qx 'FAKE tokscale'")
        machine.succeed("test $(stat -L -c '%a:%U' " + tokscale + ") = 400:alice")
        pi_key = "/run/secrets/cli-auth/synthetic_api_key"
        machine.succeed("runuser -u alice -- cat " + pi_key + " | grep -qx 'FAKE pi'")
        machine.succeed("test $(stat -L -c '%a:%U' " + pi_key + ") = 400:alice")
        exa = "/run/secrets/cli-auth/exa_api_key"
        machine.succeed("runuser -u alice -- cat " + exa + " | grep -qx 'FAKE exa'")
        machine.succeed("test $(stat -L -c '%a:%U' " + exa + ") = 400:alice")
        openrouter = "/run/secrets/cli-auth/openrouter_api_key"
        machine.succeed("runuser -u alice -- cat " + openrouter + " | grep -qx 'FAKE openrouter'")
        machine.succeed("test $(stat -L -c '%a:%U' " + openrouter + ") = 400:alice")
        opencode_go = "/run/secrets/cli-auth/opencode_go_api_key"
        machine.succeed("runuser -u alice -- cat " + opencode_go + " | grep -qx 'FAKE opencode go'")
        machine.succeed("test $(stat -L -c '%a:%U' " + opencode_go + ") = 400:alice")
        for provider in ("openai", "anthropic"):
            key = "/run/secrets/cli-auth/" + provider + "_api_key"
            machine.succeed(f"runuser -u alice -- cat {key} | grep -qx 'FAKE {provider}'")
            machine.succeed(f"test $(stat -L -c '%a:%U' {key}) = 400:alice")
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
    machine.succeed("rm -r /srv/workspace/.config/gh")
    machine.succeed("mkdir /root/protected; ln -s /root/protected /srv/workspace/.config/gh")
    machine.fail(switch)
    machine.succeed("test -z \"$(ls -A /root/protected)\"")
    machine.succeed("rm /srv/workspace/.config/gh")
    machine.succeed(switch)
    verify()
    machine.succeed("runuser -u alice -- env HOME=/srv/workspace gh auth token --hostname github.com | grep -qx FAKE_github")
    machine.succeed("runuser -u alice -- env HOME=/srv/workspace glab config get token --host gitlab.com | grep -qx FAKE_gitlab")
    machine.succeed("runuser -u alice -- env HOME=/srv/workspace glab config get token --host git.jpi.app | grep -qx FAKE_jpi")
    journal_output = machine.succeed("journalctl -u sops-install-secrets --no-pager")
    assert "FAKE_github" not in journal_output and "FAKE_gitlab" not in journal_output and "FAKE_jpi" not in journal_output
    assert "FAKE tokscale" not in journal_output
    assert "FAKE pi" not in journal_output
    assert "FAKE exa" not in journal_output
    assert "FAKE openrouter" not in journal_output
    assert "FAKE openai" not in journal_output and "FAKE anthropic" not in journal_output
    def assert_openai_key(expected):
        records = json.loads(machine.succeed("runuser -u alice -- env HOME=/srv/workspace opencode auth export --standalone"))
        keys = [entry["value"]["key"] for entry in records
                if entry["integrationID"] == "openai" and entry["label"] == "nix-config"]
        assert keys == [expected], "SOPS publication did not import the expected fixture"

    assert_openai_key("FAKE openai")
    # A failed switch still repoints /run/current-system at the specialisation,
    # which holds no nested one, so resolve it before the first attempt.
    rotated = machine.succeed("readlink -f /run/current-system/specialisation/rotated").strip()
    rotate = rotated + "/bin/switch-to-configuration switch"
    machine.succeed("mv /var/lib/sops-nix/key.txt /var/lib/sops-nix/key.backup")
    machine.fail(rotate)
    assert_openai_key("FAKE openai")
    machine.succeed("install -m 0600 /var/lib/sops-nix/key.backup /var/lib/sops-nix/key.txt")
    machine.succeed(rotate)
    assert_openai_key("FAKE rotated openai")
  '';
}
