{
  config,
  pkgs,
  lib,
  harness,
}:
let
  inherit (config.my.agentHooks) trustedProjects stop;
  inherit (config.my.agentHooks.${harness})
    enable
    postEdit
    preShell
    freezeTests
    ;
  policy = pkgs.writeText "${harness}-agent-hook-policy.json" (
    builtins.toJSON {
      inherit
        trustedProjects
        stop
        postEdit
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
  codex = harness == "codex";
  edit = if codex then "apply_patch" else "Edit|Write|MultiEdit";
  shell = if codex then "Bash|exec_command|shell_command" else "Bash";
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
    preserveSlots = codex;
    events = {
      PreToolUse = group (preTools != "") "pre" preTools;
      PostToolUse = group postEdit "post" edit;
      Stop = group stop "stop" "";
    };
  };
  renderExtension =
    source:
    pkgs.writeText "dotfiles-agent-quality.ts" (
      ''
        import { execFile } from "node:child_process";

        const stop = ${builtins.toJSON stop};
        function check(phase, cwd, tool_name, tool_input) {
          return new Promise((resolve) => {
            const child = execFile(
              ${builtins.toJSON executable},
              [...${builtins.toJSON args}, phase],
              (error, stdout) => resolve((phase === "post" ? !error : error?.code === 2) ? stdout.trim() : ""),
            );
            child.stdin.on("error", () => {});
            child.stdin.end(JSON.stringify({ cwd, tool_name, tool_input }));
          });
        }
      ''
      + builtins.readFile source
    );
}
