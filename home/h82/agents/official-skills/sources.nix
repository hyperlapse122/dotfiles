{ pkgs }:
{
  gradle = {
    publisher = "Gradle";
    licenses = [ "LICENSE" ];
    src = pkgs.fetchFromGitHub {
      owner = "gradle";
      repo = "gradle-skills";
      rev = "6d30a9c0dcf863a421f4a0895e34c6a40c844fb1";
      sha256 = "19nmh3xx1b0273dqm63s4cikgs1a436pxh1wnkqshvcak79c04rh";
    };
  };
  mcp = {
    publisher = "Model Context Protocol";
    licenses = [ "LICENSE" ];
    src = pkgs.fetchFromGitHub {
      owner = "modelcontextprotocol";
      repo = "typescript-sdk";
      rev = "5ee54ee30ddc00a914a3d981880f87fdce0e6246";
      sha256 = "1bpm7jb2dfygyxr6l7jfla28j39f5qk8mmihy5x4dsrjns7xz0w5";
    };
  };
  dotnet = {
    publisher = "Microsoft .NET";
    licenses = [ "LICENSE" ];
    src = pkgs.fetchFromGitHub {
      owner = "dotnet";
      repo = "skills";
      rev = "c227688ed14de4467e3e45f95dc69a94e905e219";
      sha256 = "15sl3gdc919p1b82yqs3fs05k045f8v9xmrfj1jp9vv2bq3ij546";
    };
  };
  redis = {
    publisher = "Redis";
    licenses = [ "LICENSE" ];
    src = pkgs.fetchFromGitHub {
      owner = "redis";
      repo = "agent-skills";
      rev = "74708dab4b3f81a9845803c3f642a4f7d443af69";
      sha256 = "00phf5a72irhcc40bdbg3zx9ilg20rq1rfd1h3ph1lpd9r6pyyjy";
    };
  };
  flux = {
    publisher = "Flux";
    licenses = [ "LICENSE" ];
    src = pkgs.fetchFromGitHub {
      owner = "fluxcd";
      repo = "agent-skills";
      rev = "25da0ed5bfdd1d8f779ef79c2c7e336781978d87";
      sha256 = "1gpa5f43ad9vxsaymzg8dnmkkg6ahb2cg2qs9m1c1132g9ndgrwl";
    };
  };
  nvidia = {
    publisher = "NVIDIA";
    licenses = [
      "LICENSE-APACHE"
      "LICENSE-CC-BY-4.0"
    ];
    src = pkgs.fetchFromGitHub {
      owner = "NVIDIA";
      repo = "skills";
      rev = "f41ce9991ce9b45b19cf4b4fda1d1a066b45dd14";
      sha256 = "0vvahhdbbf0vsv88wp9dhl8fx3dnvn3gl0x6wimfa03jmwa41jx2";
    };
  };
  aws = {
    publisher = "AWS";
    licenses = [
      "LICENSE"
      "NOTICE"
    ];
    src = pkgs.fetchFromGitHub {
      owner = "aws";
      repo = "agent-toolkit-for-aws";
      rev = "429c89be26571692979c3f60ec0394ecdd38fca3";
      sha256 = "127kk2085zm0axn3r0zv0k7hxmaq8n9c40bj3hy0h47cn98yw5ia";
    };
  };
  a2ui = {
    publisher = "A2UI";
    licenses = [ "LICENSE" ];
    src = pkgs.fetchFromGitHub {
      owner = "google";
      repo = "A2UI";
      rev = "5ff1b05f02d39f969b52a942e78e864ef3ac01fa";
      sha256 = "0qr19f0lyp2xg63whakasx8qcvgfci7nm9znscaqk31r4jap37cr";
    };
  };
  cloudflare = {
    publisher = "Cloudflare";
    licenses = [ "LICENSE" ];
    src = pkgs.fetchFromGitHub {
      owner = "cloudflare";
      repo = "skills";
      rev = "5108325ecceabc899c761e07aa617b09c02445ee";
      sha256 = "0a2q9ahrffac9fsk2lzah2dhvb4wgzipfx0kw4rs8p951qk76yq3";
    };
  };
  flutter = {
    publisher = "Flutter";
    licenses = [ "LICENSE" ];
    src = pkgs.fetchFromGitHub {
      owner = "flutter";
      repo = "agent-plugins";
      rev = "ff6d472ee66dbed566c4500edee460c94fde0a02";
      sha256 = "18x1lm8y5fy6gh3yzjdr36z2j4nash0fsp6cjr20mi60w0644bw9";
    };
  };
  dart = {
    publisher = "Dart";
    licenses = [ "LICENSE" ];
    src = pkgs.fetchFromGitHub {
      owner = "dart-lang";
      repo = "skills";
      rev = "f84b16872b5d186f4e877511b49b93c204a1c4ef";
      sha256 = "0a1w74i2d71lr1fi0dryh8vyf2rp222zvfj8vimn4yfvgfligq2m";
    };
  };
  fastmcp = {
    publisher = "FastMCP";
    licenses = [ "LICENSE" ];
    src = pkgs.fetchFromGitHub {
      owner = "PrefectHQ";
      repo = "fastmcp";
      rev = "33c7401f7e4fa716b1d5731e9f6105d711c3ac43";
      sha256 = "00lsf9vdwwv72iz89sq6gklcxfx2y2kcpfyi6a11plyi4xrcpcjr";
    };
  };
  docker = {
    publisher = "Docker";
    licenses = [ "LICENSE" ];
    src = pkgs.fetchFromGitHub {
      owner = "docker";
      repo = "skills";
      rev = "8839ca12564ee5429927083ad638744007d539e9";
      sha256 = "0dagn60c1a97aa05px9blidk8s53b5m8xwxrdg37d9fizfqvk47b";
    };
  };
  grafana = {
    publisher = "Grafana";
    licenses = [ "LICENSE" ];
    src = pkgs.fetchFromGitHub {
      owner = "grafana";
      repo = "skills";
      rev = "8fb72a527961f05e708f53d2a0500709e12d7970";
      sha256 = "1mchmmwivwhxmzapnnhzp5hx6gdh2gyxmc1zlfgfwn29wrbrh1rw";
    };
  };
  terraform = {
    publisher = "HashiCorp";
    licenses = [ "LICENSE" ];
    src = pkgs.fetchFromGitHub {
      owner = "hashicorp";
      repo = "agent-skills";
      rev = "5e30fa5c867ba6777c37e4206babfd08049c396f";
      sha256 = "1ygvscn0x8djgr7a4ckcjv8grfnvhdyfqcj7l4fh9ik15ia6han7";
    };
  };
  hono = {
    publisher = "Hono";
    licenses = [ "LICENSE" ];
    src = pkgs.fetchFromGitHub {
      owner = "honojs";
      repo = "skills";
      rev = "e54ce51f6effaeb574ebd2629e89e086e14a2db3";
      sha256 = "0v8j3pmkfihjkcd7nw5263bcxq1ph908pw65vy5l3vc3sy8akyyy";
    };
  };
  nestjs = {
    publisher = "NestJS";
    licenses = [ "LICENSE" ];
    src = pkgs.fetchFromGitHub {
      owner = "nestjs";
      repo = "agent-skills";
      rev = "7f05f492c42b30bb03b721caa07b2642cdf29deb";
      sha256 = "0j52id6dii6hnrwwfg37n2264n4p93917szg1hw60w479lzqxnv5";
    };
  };
  playwright = {
    publisher = "Microsoft Playwright";
    licenses = [ "LICENSE" ];
    src = pkgs.fetchFromGitHub {
      owner = "microsoft";
      repo = "playwright-cli";
      rev = "c872a33cec77fa03c28fa7c6d1ad99d15d04ce42";
      sha256 = "1d7nh9qxwmx5lzzigq719cgrslmjw2v84vwwbixsjn7mmx6l0asq";
    };
  };
  confluent = {
    publisher = "Confluent";
    licenses = [ "LICENSE" ];
    src = pkgs.fetchFromGitHub {
      owner = "confluentinc";
      repo = "agent-skills";
      rev = "e127e024075414d3dcf06a33f5dfd9306d99ca98";
      sha256 = "1qzwmnnh1w12wmvw9935mmjvngdaj2fnq84lkpks9qlp21drp925";
    };
  };
  gitlab = {
    publisher = "GitLab";
    licenses = [ "LICENSE" ];
    src = pkgs.fetchzip {
      url = "https://gitlab.com/gitlab-org/ci-cd/gitlab-ci-skill/-/archive/c3fb60fa982cf5db3510b8b65300a0f23a3c6e34/gitlab-ci-skill-c3fb60fa982cf5db3510b8b65300a0f23a3c6e34.tar.gz";
      sha256 = "01wxz9q9irm3i7g3sq0vbk7slhf1j2akbq9fxming2mb3yscnxll";
    };
  };
}
