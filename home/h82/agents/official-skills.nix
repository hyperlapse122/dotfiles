{ pkgs, lib, ... }:
let
  sources = import ./official-skills/sources.nix { inherit pkgs; };
  # Each path is copied with its sibling assets, then its entry is renamed so
  # harnesses advertise only the domain directory, not every reference.
  groups = {
    service-lenses = {
      description = "Develop services, integrations, protocols, and application data stores.";
      entries = [
        {
          source = "redis";
          paths = map (n: "skills/${n}") [
            "redis-core"
            "redis-connections"
            "redis-clustering"
            "redis-observability"
            "redis-search"
          ];
        }
        {
          source = "confluent";
          paths = map (n: "skills/${n}") [
            "developing-kafka-java-client"
            "developing-kafka-python-client"
            "kafka-schema-registry"
            "kafka-streams-programming"
          ];
        }
        {
          source = "hono";
          paths = [ "skills/hono" ];
        }
        {
          source = "nestjs";
          paths = map (n: "skills/${n}") [
            "nestjs"
            "nestjs-auth"
            "nestjs-data"
            "nestjs-feature"
            "nestjs-production"
            "nestjs-testing"
          ];
        }
        {
          source = "fastmcp";
          paths = [
            "skills/fastmcp-client-cli"
            "skills/fastmcp-server"
          ];
        }
        {
          source = "mcp";
          paths = [
            "skills/mcp-typescript-sdk-skills"
            "skills/mcp-typescript-sdk-upgrade-to-v2"
          ];
        }
        {
          source = "a2ui";
          paths = [ "skills/a2ui" ];
        }
      ];
    };
    platform-lenses = {
      description = "Develop and operate cloud, container, infrastructure, and GitOps systems.";
      entries = [
        {
          source = "aws";
          paths = [ "skills/core-skills/aws-storage" ];
        }
        {
          source = "cloudflare";
          paths = map (n: "skills/${n}") [
            "cloudflare"
            "cloudflare-one"
            "gateway-workers"
            "nextjs-on-cloudflare"
            "workers-profiling"
            "workers-best-practices"
            "wrangler"
          ];
        }
        {
          source = "gitlab";
          paths = [ "." ];
        }
        {
          source = "flux";
          paths = map (n: "skills/${n}") [
            "gitops-knowledge"
            "gitops-repo-audit"
            "gitops-cluster-debug"
          ];
        }
        {
          source = "docker";
          paths = map (n: "skills/${n}") [
            "docker-build-strategies"
            "docker-compose-patterns"
            "docker-project-foundations"
          ];
        }
        {
          source = "terraform";
          paths = map (n: "plugins/terraform/skills/${n}") [
            "terraform-style-guide"
            "terraform-test"
          ];
        }
        {
          source = "grafana";
          paths = map (n: "skills/grafana-core/${n}") [
            "dashboarding"
            "grafana-oss"
            "opentelemetry"
          ];
        }
      ];
    };
    toolchain-lenses = {
      description = "Build and test Java, .NET, Dart, Flutter, CUDA, and browser projects.";
      entries = [
        {
          source = "gradle";
          paths = [
            "skills/gradle-best-practices"
            "skills/gradle-wrapper-upgrade"
          ];
        }
        {
          source = "dotnet";
          paths = [
            "plugins/dotnet/skills/csharp-expert"
            "plugins/dotnet/skills/msbuild"
            "plugins/dotnet-data/skills/optimizing-ef-core-queries"
            "plugins/dotnet-aspnetcore/skills/dotnet-webapi"
          ];
        }
        {
          source = "nvidia";
          paths = [ "skills/compute-sanitizer-diagnose-cuda-bugs" ];
        }
        {
          source = "playwright";
          paths = [ "skills/playwright-cli" ];
        }
        {
          source = "dart";
          paths = map (n: "skills/${n}") [
            "dart-add-unit-test"
            "dart-build-cli-app"
            "dart-collect-coverage"
            "dart-fix-runtime-errors"
            "dart-generate-test-mocks"
            "dart-resolve-package-conflicts"
            "dart-run-static-analysis"
            "dart-use-doc-examples"
            "dart-use-pattern-matching"
            "dart-write-documentation"
          ];
        }
        {
          source = "flutter";
          paths = map (n: "skills/${n}") [
            "flutter-add-widget-test"
            "flutter-fix-layout-issues"
            "flutter-implement-json-serialization"
            "flutter-setup-declarative-routing"
            "flutter-setup-localization"
            "flutter-use-http-package"
          ];
        }
      ];
    };
  };
  esc = lib.escapeShellArg;
  buildGroup =
    name: group:
    let
      refs = lib.concatMap (
        entry:
        map (path: {
          inherit (entry) source;
          inherit path;
          name = if entry.source == "gitlab" then "gitlab-ci-skill" else baseNameOf path;
        }) entry.paths
      ) group.entries;
      names = map (r: r.name) refs;
      duplicates = lib.unique (lib.filter (n: lib.count (x: x == n) names > 1) names);
      index = pkgs.writeText "${name}-entry" (
        ''
          ---
          name: ${name}
          description: ${group.description}
          ---

          # ${name}

          Match the reference to the task and the installed product version. Project instructions, user authorization, and existing dependency versions take precedence. These are fixed snapshots; verify release-specific APIs against the project's documentation. Read the relevant guide and its linked local assets only when needed.

        ''
        + lib.concatMapStringsSep "\n" (
          r: "- [${r.name}](references/${r.name}/guide.md) — ${sources.${r.source}.publisher}"
        ) refs
        + "\n"
      );
    in
    lib.throwIf (duplicates != [ ])
      "official-skills: duplicate reference names in ${name}: ${lib.concatStringsSep ", " duplicates}"
      (
        pkgs.runCommand name { } (
          ''
            mkdir -p "$out/references"
            cp ${index} "$out/SKILL.md"
          ''
          + lib.concatMapStringsSep "\n" (
            r:
            let
              src = sources.${r.source};
              dest = "$out/references/${r.name}";
            in
            ''
              mkdir -p "${dest}"
              cp -r --no-preserve=mode ${esc "${src.src}/${r.path}"}/. "${dest}/"
              mv "${dest}/SKILL.md" "${dest}/guide.md"
              ${lib.optionalString (r.source == "cloudflare") ''
                sed -i "s@/SKILL\.md@/guide.md@g" "${dest}/guide.md"
              ''}
              ${lib.optionalString (r.name == "grafana-oss") ''
                cp --no-preserve=mode ${esc "${src.src}/skills/grafana-cloud/admin/references/sso.md"} "${dest}/references/sso.md"
                sed -i 's@../../../grafana-cloud/admin/references/sso.md@sso.md@g' "${dest}/references/config.md"
              ''}
              ${lib.concatMapStringsSep "\n" (
                license: ''cp --no-preserve=mode ${esc "${src.src}/${license}"} "${dest}/"''
              ) src.licenses}
            ''
          ) refs
        )
      );
in
{
  my.agentSkills = lib.mapAttrs buildGroup groups;
}
