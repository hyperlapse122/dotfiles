{ pkgs, inputs }:
let
  synthetic = builtins.fromJSON (builtins.readFile ../home/h82/agents/synthetic-catalog.json);
  openrouter = builtins.fromJSON (builtins.readFile ../home/h82/agents/openrouter-catalog.json);
  expectedPatterns = builtins.toJSON (
    map (row: "synthetic/${row.id}") synthetic.data
    ++ map (row: "openrouter/${row.id}") (
      builtins.filter (
        row: builtins.match "^openrouter/.*$" row.id != null && row.id != "openrouter/bodybuilder"
      ) openrouter.data
    )
  );
  changed = pkgs.writeText "omp-changed-config.json" (
    builtins.toJSON {
      memory.backend = "off";
      autolearn.enabled = false;
      disabledProviders = [
        "omp-managed"
        "openai-codex"
        "google-antigravity"
      ];
      startup = {
        checkUpdate = false;
        quiet = true;
      };
      marketplace.autoUpdate = "off";
    }
  );
in
pkgs.testers.nixosTest {
  name = "omp-activation";
  nodes.machine = { lib, ... }: {
    imports = [
      inputs.home-manager.nixosModules.home-manager
      ../modules/shared/host.nix
      ../modules/nixos/system/omp.nix
    ];
    my.user = {
      name = "tester";
      home = "/home/tester";
    };
    users.users.tester.isNormalUser = true;
    home-manager = {
      useGlobalPkgs = true;
      useUserPackages = true;
      users.tester = {
        imports = [
          ../modules/shared/host.nix
          ../home/h82/agents/omp.nix
        ];
        home.stateVersion = "26.05";
      };
    };
    system.switch.enable = true;
    boot.loader.grub.enable = lib.mkForce false;
    specialisation.changed.configuration.home-manager.users.tester.my.omp.documents."config.yml" =
      lib.mkForce changed;
    environment.systemPackages = [ pkgs.python3 ];
    virtualisation.memorySize = 2048;
  };
  testScript = ''
    import json
    import shlex

    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("home-manager-tester.service")
    config = "/home/tester/.omp/agent/config.yml"
    state = "/home/tester/.omp/agent/agent.db"
    switch = "/run/current-system/bin/switch-to-configuration switch"

    def seed(path, content):
        machine.succeed("runuser -u tester -- python3 -c " + shlex.quote(
            "from pathlib import Path; Path(" + repr(path) + ").write_text(" + repr(content) + ")"))

    def verify(quiet=False):
        value = json.loads(machine.succeed("cat " + config))
        expected = {"memory": {"backend": "off"}, "startup": {"checkUpdate": False},
                    "marketplace": {"autoUpdate": "off"}, "autolearn": {"enabled": False},
                    "disabledProviders": ["omp-managed", "openai-codex", "google-antigravity"]}
        if quiet:
            expected["startup"]["quiet"] = True
        else:
            expected["enabledModels"] = json.loads(${pkgs.lib.escapeShellArg expectedPatterns})
            expected["github"] = {"enabled": True}
            expected["modelRoles"] = {
                "default": "synthetic/hf:moonshotai/Kimi-K3",
                "smol": "synthetic/hf:deepseek-ai/DeepSeek-V4.1-Flash:low",
                "slow": "synthetic/hf:moonshotai/Kimi-K3:high",
                "plan": "synthetic/hf:moonshotai/Kimi-K3:high",
                "task": "synthetic/hf:zai-org/GLM-5.3:high",
                "commit": "synthetic/hf:deepseek-ai/DeepSeek-V4.1-Flash:low",
                "web": "web/synthetic",
            }
            expected["defaultThinkingLevel"] = "high"
            expected["skills"] = {"customDirectories": []}
            expected["task"] = {
                "structured": True,
                "enableEffort": True,
                "maxEffort": "high",
                "agentModelOverrides": {
                    "sonic": "synthetic/hf:deepseek-ai/DeepSeek-V4.1-Flash:low",
                    "scout": "synthetic/hf:deepseek-ai/DeepSeek-V4.1-Flash:low",
                    "seance": "synthetic/hf:deepseek-ai/DeepSeek-V4.1-Flash:low",
                    "task": "synthetic/hf:zai-org/GLM-5.3:high",
                    "reviewer": "synthetic/hf:zai-org/GLM-5.3:high",
                    "security-reviewer": "synthetic/hf:zai-org/GLM-5.3:high",
                    "architect": "synthetic/hf:moonshotai/Kimi-K3:high",
                },
            }
            expected["symbolPreset"] = "nerd"
            expected["composer"] = {"shape": "band"}
            expected["theme"] = {"dark": "titanium", "light": "light"}
            expected["setupVersion"] = 2
            expected["tui"] = {
                "resizeScrollback": "rebuild",
                "completeScrollback": True,
                "textSizing": True,
                "codexResetFireworks": True,
                "mouse": False,
                "imeSafeCursor": True,
            }
            expected["terminal"] = {"showProgress": True}
            expected["display"] = {
                "subagentLivePreview": True,
                "shimmer": "kitt",
                "showTokenUsage": True,
                "showTurnTime": True,
            }
        assert value == expected, value
        assert machine.succeed("stat -c '%a:%U' " + config).strip() == "600:tester"
        assert machine.succeed("cat " + state) == "FAKE_STATE"

    seed(state, "FAKE_STATE")
    seed(config, '{"memory":{"backend":"local"},"newGlobalKey":true}')
    before = machine.succeed("systemctl show -P ExecMainStartTimestampMonotonic home-manager-tester")
    machine.succeed(switch)
    verify()
    after = machine.succeed("systemctl show -P ExecMainStartTimestampMonotonic home-manager-tester")
    assert before == after, "unchanged Home Manager generation unexpectedly restarted"

    changed_switch = "/run/current-system/specialisation/changed/bin/switch-to-configuration switch"
    seed(config, '{"memory":{"backend":"local"},"newGlobalKey":true}')
    machine.succeed(changed_switch)
    verify(quiet=True)
    seed(config, '{"memory":{"backend":"local"},"anotherNewKey":false}')
    machine.succeed(switch)
    verify(quiet=True)

    seed(config, "invalid: [FAKE_SECRET")
    machine.fail(switch)
    assert machine.succeed("cat " + config) == "invalid: [FAKE_SECRET"
    assert machine.succeed("cat " + state) == "FAKE_STATE"
  '';
}
