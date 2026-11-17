{
  pkgs,
  self,
  darwinFixtures,
}:
let
  inherit (pkgs) lib;
  darwin = pkgs.stdenv.hostPlatform.isDarwin;
  configurations = import ./lib/configurations.nix { inherit pkgs self; };
  cudaDefault =
    drivers:
    (import (pkgs.path + "/nixos/lib/eval-config.nix") {
      system = pkgs.stdenv.hostPlatform.system;
      modules = [
        ../modules/shared/host.nix
        ../modules/nixos/hardware/nvidia.nix
        { services.xserver.videoDrivers = lib.mkForce drivers; }
      ];
    }).config.my.cuda.enable;
  withoutNvidia = map (
    entry:
    configurations.entryOf "${entry.name} without NVIDIA" (
      self.nixosConfigurations.${entry.name}.extendModules {
        modules = [ { services.xserver.videoDrivers = lib.mkForce [ ]; } ];
      }
    )
  ) configurations.entries;
  overrides = lib.concatMap (
    entry:
    map
      (
        case:
        configurations.entryOf "${entry.name} CUDA override ${toString case.cuda}" (
          self.nixosConfigurations.${entry.name}.extendModules {
            modules = [
              {
                services.xserver.videoDrivers = lib.mkForce case.drivers;
                my.cuda.enable = lib.mkForce case.cuda;
              }
            ];
          }
        )
      )
      [
        {
          drivers = [ "nvidia" ];
          cuda = false;
        }
        {
          drivers = [ ];
          cuda = true;
        }
      ]
  ) configurations.production;
  linuxEntries = map (entry: {
    inherit (entry) name bootstrap;
    kind = "nixos";
    backend = if entry.config.my.cuda.enable then "cuda" else "openrouter";
    path = "${entry.user.home.path}";
    files = "${entry.user.home-files}";
    key = "/run/secrets/cli-auth/openrouter_api_key";
    ca = "/etc/ssl/certs/ca-certificates.crt";
  }) (configurations.entries ++ withoutNvidia ++ overrides);
  darwinEntries =
    map
      (
        entry:
        let
          system = entry.host.config;
          user = system.home-manager.users.${system.my.user.name};
        in
        {
          inherit (entry) name bootstrap;
          kind = "darwin";
          backend = "mlx";
          generation = "${user.home.activationPackage}";
          key = "${user.my.secrets.stateDir}/openrouter_api_key";
          ca =
            if system.my.tlsInspectionCa.enable && !entry.bootstrap then
              "/etc/ssl/nix-config/ca-certificates.crt"
            else
              "/etc/ssl/certs/ca-certificates.crt";
        }
      )
      (
        darwinFixtures
        ++ lib.mapAttrsToList (name: host: {
          inherit name host;
          bootstrap = host.config.my.bootstrap;
        }) self.darwinConfigurations
      );
  entries = if darwin then darwinEntries else linuxEntries;
  defaults =
    if darwin then
      [ ]
    else
      [
        (cudaDefault [ ])
        (cudaDefault [ "nvidia" ])
      ];
  script = pkgs.writeText "decide-assembly.py" ''
    import ast, configparser, json, os, pathlib, plistlib, re, subprocess, sys, tempfile

    entries = json.loads(pathlib.Path(sys.argv[1]).read_text())
    assert entries and {e['bootstrap'] for e in entries} == {False, True}
    if entries[0]['kind'] == 'nixos':
        assert {e['backend'] for e in entries} == {'cuda', 'openrouter'}
        assert json.loads(pathlib.Path(sys.argv[2]).read_text()) == [False, True]
    for entry in entries:
        try:
            if entry['kind'] == 'darwin':
                generation = pathlib.Path(entry['generation'])
                binary = generation / 'home-path/bin/decide'
                with (generation / 'LaunchAgents/org.nix-community.home.decide.plist').open('rb') as f:
                    service = plistlib.load(f)
                assert service['RunAtLoad'] is True and service['KeepAlive'] is True
                assert service['ThrottleInterval'] == 5
                args = service['ProgramArguments']
                assert args[:2] == ['/bin/sh', '-c'] and len(args) == 3
                prefix = '/bin/wait4path /nix/store && exec '
                assert args[2].startswith(prefix)
                launcher = args[2][len(prefix):]
            else:
                binary = pathlib.Path(entry['path']) / 'bin/decide'
                unit = pathlib.Path(entry['files']) / '.config/systemd/user/decide.service'
                assert (unit.parent / 'default.target.wants/decide.service').exists()
                service = configparser.ConfigParser(interpolation=None)
                service.read(unit)
                assert service['Service']['Restart'] == 'on-failure'
                assert service['Service']['RestartSec'] == '5'
                launcher = service['Service']['ExecStart']
            assert binary.is_file() and os.access(binary, os.X_OK)
            package = binary.resolve().parent.parent
            constants = {}
            for node in ast.parse((package / 'lib/decide/decide/_package.py').read_text()).body:
                constants[node.targets[0].id] = ast.literal_eval(node.value)
            assert constants['BACKEND'] == entry['backend']
            assert constants['KEY_FILE'] == entry['key']
            body = pathlib.Path(launcher).read_text()
            command = f'exec {package}/bin/decide serve'
            assert command in body
            assert 'DECIDE_SOCKET' not in body and 'DECIDE_MODEL' not in body and 'DECIDE_TIMEOUT' not in body
            replacement = "printf '%s\\n' \"$SSL_CERT_FILE\" \"$REQUESTS_CA_BUNDLE\""
            with tempfile.TemporaryDirectory() as temp:
                probe = pathlib.Path(temp) / 'launcher'
                probe.write_text(body.replace(command, replacement))
                for override in ('unset', 'custom', 'empty'):
                    env = dict(os.environ)
                    env.pop('SSL_CERT_FILE', None)
                    env.pop('REQUESTS_CA_BUNDLE', None)
                    if override == 'custom':
                        env.update(SSL_CERT_FILE='/custom/ssl', REQUESTS_CA_BUNDLE='/custom/requests')
                    elif override == 'empty':
                        env.update(SSL_CERT_FILE="", REQUESTS_CA_BUNDLE="")
                    result = subprocess.check_output(['/bin/sh', str(probe)], env=env, text=True).splitlines()
                    expected = {'unset': [entry['ca']] * 2, 'custom': ['/custom/ssl', '/custom/requests'], 'empty': ["", ""]}
                    assert result == expected[override]
        except Exception as error:
            raise AssertionError(f"{entry['name']}: {error}") from error
  '';
in
pkgs.runCommand "decide-assembly" { nativeBuildInputs = [ pkgs.python3 ]; } ''
  ${lib.optionalString (!darwin) configurations.guard}
  python3 ${script} ${pkgs.writeText "decide-entries.json" (builtins.toJSON entries)} ${pkgs.writeText "decide-defaults.json" (builtins.toJSON defaults)}
  touch "$out"
''
