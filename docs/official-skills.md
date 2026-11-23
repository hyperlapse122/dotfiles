# Official skill references

The shared `service-lenses`, `platform-lenses`, and `toolchain-lenses` entries contain selected publisher guides and their supporting files. The Nix source declarations fix both revision and content hash. Each reference includes the publisher's license; AWS also includes its notice and NVIDIA includes both licenses. These snapshots do not install their associated tools or grant permission to run commands. Check the installed version and the task's authorization before following a guide.

| Work | Disposition |
| --- | --- |
| Redis data modeling, connections, clustering, search and observability | Redis references in `service-lenses`. Verify server and module features against the deployed Redis version. |
| Hono and NestJS services | Hono and NestJS references in `service-lenses`. The NestJS guides target NestJS 12; use the project's versioned documentation for older majors. |
| FastMCP client and server; MCP TypeScript SDK | FastMCP references and MCP TypeScript SDK v2 skills and migration guidance are in `service-lenses`. SDK v1 users should use v1 documentation unless an upgrade is requested. A connected MCP server is a separate capability. |
| A2UI | A2UI protocol guide in `service-lenses`. It discusses v1 and older wire formats; match the package and protocol version in use. |
| AWS S3, Cloudflare Workers, D1 and Wrangler | AWS storage and Cloudflare references in `platform-lenses`. AWS pricing and limits must be checked against current AWS documentation. D1 material is in the Cloudflare reference's `references/d1` directory. |
| Terraform, Flux, Docker and Grafana | Publisher references in `platform-lenses` cover module style and testing, Flux knowledge, auditing and diagnosis, Docker builds and Compose, and Grafana dashboards and telemetry. Flux guidance does not apply to Argo CD; use Argo's documentation for Argo. |
| Gradle | Both Gradle references are in `toolchain-lenses`. The best-practices snapshot describes a 9.9 nightly catalog; check applicability to the project's wrapper. The wrapper upgrade guide covers 7.0–9.x. |
| C#, ASP.NET Core, EF Core and MSBuild | Microsoft references in `toolchain-lenses`. Match APIs and target frameworks to the project. |
| CUDA diagnostics | NVIDIA Compute Sanitizer reference in `toolchain-lenses`; it covers CUDA correctness diagnostics and its own limitations. |
| Playwright CLI | Microsoft's CLI reference is in `toolchain-lenses`; use it when that CLI is available and authorized. Existing Playwright testing guidance remains available for test design. |
| Dart and Flutter | Publisher references supplement the existing Flutter architecture, responsive layout and integration-test guidance. Expo and React Native retain the existing mobile guidance. |
| React performance and composition | Reuse the existing Vercel references in `web-lenses`. |
| TanStack Router, Start, Table, AI and Hotkeys; tRPC | Prefer the guide in the installed package through Intent. When absent or incompatible, use documentation for the installed release. In particular, a Table 9 guide is not evidence for Table 8, and AI guidance must match the installed major. |
| Drizzle Kit | The checked 0.31 releases do not bundle skills. The 1.0 release-candidate guidance applies only to compatible releases; use the project's versioned documentation otherwise. |
| shadcn | Its published skill executes a harness-specific dynamic `npx ...@latest` context command and directs use of the latest CLI. Use the project's configured components and versioned documentation; the snapshot is not installed as a portable reference. |
| Figma | Figma's skills require its MCP integration and an available Figma context; follow Figma's documentation when that connection exists. |
| Turborepo | Its skill routes to documentation bundled in the installed `turbo` package rather than providing a standalone reference. Read that version-matched documentation from the project; use official docs if the package is absent. |
| Storybook | The surveyed setup skill requires Storybook 11 or later and delegates its procedure to the installed CLI. The surveyed 10.6.7 package does not meet that requirement. Use its versioned documentation; do not upgrade it without authorization. |
| Better Auth and OpenRouter | The inspected official skill repositories contain no license grant for redistribution. Use the corresponding versioned publisher documentation. |
| Sentry | The inspected instrument skill declares Apache-2.0 while its repository license is MIT, with no accompanying Apache license in the skill. Use Sentry's version-matched documentation until the applicable license is clarified. |
| GitLab CI and Confluent Kafka | GitLab CI is in `platform-lenses`; Confluent's Java and Python clients, Schema Registry and Kafka Streams guides are in `service-lenses`. Match the client and server versions; do not substitute one client or CI provider for another. |
| General Rust, TypeScript and Java; DCMTK, fo-dicom, dcm4che and Cornerstone | No general maintainer skill was verified for these needs in the survey. Use the official documentation for the project's version and specialist library. |
| Documents | Reuse the existing document, PDF, presentation and spreadsheet skills where available. |

The discovery service and `find-skills` help maintainers find candidates. They do not install or update this collection. Nix owns shared reference installation and removal.
