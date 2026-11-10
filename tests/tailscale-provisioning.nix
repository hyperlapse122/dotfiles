{ pkgs, inputs }:
let
  fixtures =
    pkgs.runCommand "fake-tailscale-secrets"
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
        tailscale:
          auth_key: FAKE_test_auth_key
          api_token: FAKE_test_api_token
          routes:
            lan_10: 192.168.10.0/24
            lan_1: 192.168.1.0/24
            site_a: 203.0.113.0/24
            site_b: 198.51.100.0/24
        EOF
        sops --encrypt --age "$recipient" --input-type yaml --output-type yaml plain.yaml > $out/tailscale.yaml
      '';

  dedupScriptSrc = ../scripts/tailscale-dedup-device;

  mkTestHost =
    hostName: advertiseRoutes:
    { ... }:
    {
      imports = [
        inputs.sops-nix.nixosModules.sops
        ../modules/shared/host.nix
        ../modules/nixos/system/secrets.nix
        ../modules/nixos/services/tailscale.nix
      ];
      boot.loader.grub.enable = pkgs.lib.mkForce false;
      fileSystems."/" = {
        device = "/dev/null";
        fsType = "ext4";
      };
      networking.hostName = hostName;
      environment.systemPackages = [
        pkgs.jq
        pkgs.curl
      ];
      my.tailscale = {
        enable = true;
        inherit advertiseRoutes;
        sopsFile = "${fixtures}/tailscale.yaml";
        apiBase = "http://mockapi:8927";
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
in
pkgs.testers.nixosTest {
  name = "tailscale-provisioning";

  nodes.mockapi =
    { ... }:
    {
      boot.loader.grub.enable = pkgs.lib.mkForce false;
      environment.systemPackages = [ pkgs.python3 ];
      systemd.services.tailscale-mock-api = {
        description = "Mock Tailscale API for tests/tailscale-provisioning.nix";
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          ExecStart = "${pkgs.python3}/bin/python3 ${./tailscale-mock-api.py} 8927";
          Restart = "always";
        };
      };
      networking.firewall.allowedTCPPorts = [ 8927 ];
    };

  nodes.client = mkTestHost "test-client" false;
  nodes.router = mkTestHost "test-router" true;

  testScript =
    { nodes, ... }:
    ''
      start_all()
      mockapi.wait_for_unit("tailscale-mock-api.service")
      mockapi.wait_for_open_port(8927)
      client.wait_for_unit("multi-user.target")
      router.wait_for_unit("multi-user.target")

      # --- Structural checks on the *materialized* units, not just the
      # declared config -- a systemd.services.<name>.enable = false sibling
      # would leave the declared After/Wants/WantedBy values unchanged while
      # installing no unit at all (see AGENTS.md's linked solution:
      # nix-check-reads-option-value-not-materialized-output.md). `systemctl
      # cat` fails outright if the unit was never installed, so this is a
      # check on what actually landed on the running system.
      # (U2, U3, U4 test scenarios)

      assert ${builtins.toJSON nodes.client.services.tailscale.useRoutingFeatures} == "none", \
          "client (advertiseRoutes = false) must not enable routing features"
      assert ${builtins.toJSON nodes.router.services.tailscale.useRoutingFeatures} == "server", \
          "router (advertiseRoutes = true) must enable server routing features"

      client_up_flags = set(${builtins.toJSON nodes.client.services.tailscale.extraUpFlags})
      router_up_flags = set(${builtins.toJSON nodes.router.services.tailscale.extraUpFlags})
      assert client_up_flags == {"--ssh", "--accept-routes", "--operator=${nodes.client.my.user.name}", "--reset"}, client_up_flags
      assert router_up_flags == {"--ssh", "--accept-routes", "--operator=${nodes.router.my.user.name}", "--reset"}, router_up_flags

      # --- Runtime: an already-registered node still gets the declared prefs ---
      #
      # Clear RouteAll and RunSSH as on a node registered before the flags
      # were declared (autoconnect skips extraUpFlags then), then confirm
      # tailscaled-set restores them.
      prefs_query = "tailscale debug prefs | jq -r '[.RouteAll, .RunSSH] | @tsv'"
      operator_query = "tailscale debug prefs | jq -r '.OperatorUser // empty'"
      operators = {client: "${nodes.client.my.user.name}", router: "${nodes.router.my.user.name}"}
      for machine in [client, router]:
          machine.wait_for_unit("tailscaled.service")
          # With no control server, tailscaled-autoconnect ends only at its
          # start timeout, and the units ordered after it (tailscaled-set
          # among them) start then. multi-user.target does not wait for
          # them, so wait until systemd has no job left; otherwise a late
          # tailscaled-set can restore the prefs between the two steps below.
          machine.wait_until_succeeds("test -z \"$(systemctl list-jobs --no-legend)\"", timeout=900)
          machine.succeed("tailscale set --accept-routes=false --ssh=false --operator=")
          assert machine.succeed(prefs_query).split() == ["false", "false"]
          assert machine.succeed(operator_query).strip() == ""
          machine.succeed("systemctl start tailscaled-set.service")
          prefs = machine.succeed(prefs_query).split()
          assert prefs == ["true", "true"], f"{machine.name}: [RouteAll, RunSSH] is {prefs} after tailscaled-set"
          operator = machine.succeed(operator_query).strip()
          assert operator == operators[machine], f"{machine.name}: OperatorUser is {operator!r} after tailscaled-set"
          assert "tailscaled.service" in machine.succeed(
              "systemctl show -p WantedBy --value tailscaled-set.service"
          ).split()

      assert 41641 in ${builtins.toJSON nodes.client.networking.firewall.allowedUDPPorts}
      assert 41641 in ${builtins.toJSON nodes.router.networking.firewall.allowedUDPPorts}

      dedup_unit = client.succeed("systemctl cat tailscale-dedup-device.service")
      assert "Before=tailscaled-autoconnect.service" in dedup_unit, dedup_unit
      assert "WantedBy=multi-user.target" in dedup_unit, dedup_unit
      assert client.succeed("systemctl is-enabled tailscale-dedup-device.service").strip() == "enabled"
      assert router.succeed("systemctl is-enabled tailscale-dedup-device.service").strip() == "enabled"

      client.fail("systemctl cat tailscale-advertise-routes.service")
      route_unit = router.succeed("systemctl cat tailscale-advertise-routes.service")
      assert "After=tailscaled-autoconnect.service" in route_unit, route_unit
      assert router.succeed("systemctl is-enabled tailscale-advertise-routes.service").strip() == "enabled"

      # The client (advertiseRoutes = false) must not even render a routes secret
      # template -- not just an empty one.
      assert not ${if nodes.client.sops.templates ? "tailscale-routes.env" then "True" else "False"}, \
          "client must not have a tailscale-routes.env template"
      assert ${if nodes.router.sops.templates ? "tailscale-routes.env" then "True" else "False"}, \
          "router must have a tailscale-routes.env template"

      # Route-advertisement never touches the API, so its materialized unit
      # must not reference the API token's env file.
      assert ${builtins.toJSON nodes.router.sops.templates."tailscale-api.env".path} not in route_unit
      assert ${builtins.toJSON nodes.router.sops.templates."tailscale-routes.env".path} in route_unit

      # --- Runtime: TAILSCALE_ROUTES rendering (U4 test scenario) ---

      router_routes_env = router.succeed("cat ${nodes.router.sops.templates."tailscale-routes.env".path}")
      assert "TAILSCALE_ROUTES=192.168.10.0/24,192.168.1.0/24,203.0.113.0/24,198.51.100.0/24" in router_routes_env, router_routes_env

      # --- Runtime: dedup script against the mock API (U3 test scenario, AE1) ---
      #
      # Invokes the real scripts/tailscale-dedup-device directly -- the same
      # file the systemd unit's ExecStart wraps -- against the real
      # /var/lib/tailscale state-file path and the mock API.

      state_file = "/var/lib/tailscale/tailscaled.state"

      run_dedup = (
          "set -a; . ${nodes.router.sops.templates."tailscale-api.env".path}; set +a; "
          + "SELF_HOSTNAME=${nodes.router.networking.hostName} "
          + "bash ${dedupScriptSrc}"
      )

      # Scenario A: no tailscaled state yet (fresh install) and a device
      # already registered under this hostname -- it must be deleted.
      router.succeed(f"rm -f {state_file}")
      mockapi.succeed(
          "mkdir -p /var/lib/tailscale-mock-api && "
          + "printf '%s' '{\"devices\":["
          + "{\"id\":\"stale-device-id\",\"hostname\":\"test-router\"},"
          + "{\"id\":\"other-host-id\",\"hostname\":\"other-host\"}"
          + "]}' > /var/lib/tailscale-mock-api/devices.json"
      )
      mockapi.succeed("rm -f /var/lib/tailscale-mock-api/deletes.log && touch /var/lib/tailscale-mock-api/deletes.log")
      router.succeed(run_dedup)
      deletes = mockapi.succeed("cat /var/lib/tailscale-mock-api/deletes.log").split()
      assert deletes == ["stale-device-id"], deletes

      # Scenario B: tailscaled state already exists (ordinary reboot, or a
      # key-expiry reauth of this same instance) -- must not query the API
      # or delete anything, even though a same-hostname device is listed.
      router.succeed(f"mkdir -p $(dirname {state_file}) && touch {state_file}")
      mockapi.succeed("rm -f /var/lib/tailscale-mock-api/deletes.log && touch /var/lib/tailscale-mock-api/deletes.log")
      mockapi.succeed("truncate -s 0 /var/lib/tailscale-mock-api/requests.log")
      router.succeed(run_dedup)
      requests = mockapi.succeed("cat /var/lib/tailscale-mock-api/requests.log")
      assert requests == "", "existing state contacted API: " + requests
      deletes = mockapi.succeed("cat /var/lib/tailscale-mock-api/deletes.log").split()
      assert deletes == [], deletes
      router.succeed(f"rm -f {state_file}")

      # --- Store-leak check (U6 test scenario) ---

      for machine in [client, router]:
          leaked = machine.succeed(
              "nix-store -qR /run/current-system | xargs grep -rlE "
              + "'FAKE_test_auth_key|FAKE_test_api_token' 2>/dev/null || true"
          )
          assert leaked.strip() == "", "fixture secret leaked into the built system closure: " + leaked
    '';
}
