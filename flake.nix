{
  description = "Declarative NixOS configuration for personal hosts";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    lanzaboote = {
      url = "github:nix-community/lanzaboote/v1.1.0";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Applies the system layer of a macOS host, with Home Manager inside it.
    nix-darwin = {
      url = "github:nix-darwin/nix-darwin/master";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Installs Homebrew itself on a macOS host, so the first apply needs no
    # manual Homebrew install; nix-darwin's homebrew module installs the casks.
    nix-homebrew = {
      url = "github:zhaofengli/nix-homebrew";
      inputs.brew-src.url = "github:Homebrew/brew/main";
    };
    # Supplies the Home Manager module (home/h82/agents/omp.nix), which owns
    # ~/.omp/agent/config.yml; the CLI itself is the release binary pinned in
    # packages/omp-release.json. The URL names that release's tag, so a relock
    # holds still until the update workflow moves the tag, and the omp check
    # fails when the locked revision differs from the pinned one.
    omp = {
      url = "github:can1357/oh-my-pi/v19.2.1";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Pinned to a release tag rather than a branch, and the registry in
    # home/h82/agents/agent-plugin-pins.nix records the revision that tag is expected to
    # name. A tag is mutable and a relock re-resolves the ref, so the tag alone
    # is not a pin -- the agent-plugins check compares this input's locked
    # revision against that recorded value and fails when upstream moves it.
    compound-engineering-plugin = {
      url = "github:EveryInc/compound-engineering-plugin/compound-engineering-v3.38.3";
      flake = false;
    };
    korean-skills = {
      url = "github:DaleSeo/korean-skills/v1.0.0";
      flake = false;
    };
    # Published skills, installed unchanged. Each is pinned to
    # a tag where upstream has one and to a commit otherwise; the registry in
    # home/h82/agents/pinned-skills-pin.nix records the revision each must
    # resolve to, and the pinned-skills check compares it with flake.lock.
    anthropic-skills = {
      url = "github:anthropics/skills/dbd4588f9e1033efb41dad4bef2f7947c8993d44";
      flake = false;
    };
    modern-web-guidance = {
      url = "github:GoogleChrome/modern-web-guidance/v1.0.0";
      flake = false;
    };
    vercel-agent-skills = {
      url = "github:vercel-labs/agent-skills/agent-skills-1a2c79d4e6c4a2283dc2c614b6538cbe1ed5ca62";
      flake = false;
    };
    expo-skills = {
      url = "github:expo/skills/8a0dc4fa57ae345923c357e1451cbcd8b6f2a7db";
      flake = false;
    };
    playwright-best-practices-skill = {
      url = "github:currents-dev/playwright-best-practices-skill/283d5cbc5d11aac1abda058b16ad22c317d54dc0";
      flake = false;
    };
    ux-writing-skill = {
      url = "github:content-designer/ux-writing-skill/v1.5.0";
      flake = false;
    };
    kergoth-dotfiles = {
      url = "github:kergoth/dotfiles/7f61f919d27e3016b64c37ce09b7006199ad7878";
      flake = false;
    };
    caldo-skills = {
      url = "github:caldoai/skills/d5b68dace378219890d821adb3685538e2c69b04";
      flake = false;
    };
    context7 = {
      url = "github:upstash/context7/c36522f3d4446288a272aedd727d665f7b8175f2";
      flake = false;
    };
    impeccable = {
      url = "github:pbakaus/impeccable/skill-v4.8.0";
      flake = false;
    };
  };

  outputs =
    inputs@{ nixpkgs, ... }:
    let
      inherit (nixpkgs) lib;
      linux = "x86_64-linux";
      darwin = "aarch64-darwin";
      linuxPkgs = import nixpkgs {
        system = linux;
        config.allowUnfree = true;
      };
      darwinPkgs = import nixpkgs { system = darwin; };
      hosts = import ./lib/hosts.nix { inherit lib; } ./hosts;
      vmChecks = import ./tests/vm-checks.nix {
        pkgs = linuxPkgs;
        inherit inputs;
      };
      linuxChecks = import ./tests/linux-checks.nix {
        pkgs = linuxPkgs;
        inherit inputs vmChecks;
      };
    in
    {
      nixosConfigurations = hosts.variantsOf (import ./lib/nixos-host.nix {
        inherit inputs;
      }) hosts.nixos;
      darwinConfigurations = hosts.variantsOf (import ./lib/darwin-host.nix {
        inherit inputs;
      }) hosts.darwin;

      packages.${linux} = import ./packages {
        pkgs = linuxPkgs;
        inherit inputs;
      };
      packages.${darwin} = import ./packages {
        pkgs = darwinPkgs;
        inherit inputs;
      };
      checks.${linux} = linuxChecks.checks;
      checks.${darwin} = import ./tests/darwin-checks.nix {
        pkgs = darwinPkgs;
        inherit inputs;
      };

      # Keep KVM tests out of nix flake check while supporting nix build .#vmChecks.<name>.
      legacyPackages.${linux} = {
        vmChecks = vmChecks // {
          all = linuxPkgs.linkFarm "vm-checks" vmChecks;
        };
        checkShards = linuxChecks.shards;
      };

      formatter.${linux} = linuxPkgs.nixfmt-tree;
      devShells.${linux} = {
        agent-check = linuxPkgs.mkShell (import ./packages/agent-check.nix { pkgs = linuxPkgs; });
        default = linuxPkgs.mkShell {
          packages = with linuxPkgs; [
            age
            sops
            gnupg
            git
            nixfmt
            libsecret
            shellcheck
            python3
            yubikey-manager
          ];
        };
      };
      devShells.${darwin}.agent-check = darwinPkgs.mkShell (
        import ./packages/agent-check.nix {
          pkgs = darwinPkgs;
        }
      );
    };
}
