{
  config,
  pkgs,
  lib,
  harness,
}:
let
  inherit (config.my.agentHooks.${harness})
    enable
    preShell
    freezeTests
    ;
  policy = pkgs.writeText "${harness}-agent-hook-policy.json" (
    builtins.toJSON {
      inherit
        preShell
        freezeTests
        ;
    }
  );
  executable = "${
    import ../../../packages/agent-quality-hook.nix { inherit pkgs; }
  }/bin/agent-quality-hook";
  args = [
    (toString policy)
    harness
  ];
  edit = "Edit|Write|MultiEdit";
  shell = "Bash";
  preTools = lib.concatStringsSep "|" (lib.optional freezeTests edit ++ lib.optional preShell shell);
  identity = {
    statusMessage = "Dotfiles agent quality";
    commandPrefix = "/nix/store/";
    commandSuffix = "-agent-quality-hook/bin/agent-quality-hook";
    disabledMatcher = "^dotfiles-agent-quality-disabled$";
  };
  group =
    enabled: phase: matcher:
    lib.optionalAttrs (enable && enabled) {
      hooks = [
        {
          type = "command";
          command = lib.escapeShellArgs ([ executable ] ++ args ++ [ phase ]);
          inherit (identity) statusMessage;
        }
      ];
    }
    // lib.optionalAttrs (enable && enabled && matcher != "") {
      matcher = "^(${matcher})$";
    };
in
{
  inherit enable;
  hookGroups = {
    inherit identity;
    preserveSlots = false;
    events = {
      PreToolUse = group (preTools != "") "pre" preTools;
      PostToolUse = { };
      Stop = { };
    };
  };
  renderExtension =
    source:
    pkgs.writeText "dotfiles-agent-quality.ts" (
      ''
        import { execFile } from "node:child_process";

        function check(phase, cwd, tool_name, tool_input) {
          return new Promise((resolve) => {
            const child = execFile(
              ${builtins.toJSON executable},
              [...${builtins.toJSON args}, phase],
              (error, stdout) => resolve(error?.code === 2 ? stdout.trim() : ""),
            );
            child.stdin.on("error", () => {});
            child.stdin.end(JSON.stringify({ cwd, tool_name, tool_input }));
          });
        }
      ''
      + builtins.readFile source
    );
}
