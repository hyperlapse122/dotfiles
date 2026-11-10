{ ... }:
let
  toolSessionVariables = {
    TURBO_ENV_MODE = "loose";
    DOTNET_CLI_TELEMETRY_OPTOUT = "1";
    DOTNET_TELEMETRY_OPTOUT = "1";
    TURBO_TELEMETRY_DISABLED = "1";
    POWERSHELL_TELEMETRY_OPTOUT = "1";
  };
in
{
  home.sessionVariables = toolSessionVariables;

  systemd.user.sessionVariables = toolSessionVariables;
}
