my: if my.kind == "nixos" then "/run/secrets/cli-auth" else my.secrets.stateDir
