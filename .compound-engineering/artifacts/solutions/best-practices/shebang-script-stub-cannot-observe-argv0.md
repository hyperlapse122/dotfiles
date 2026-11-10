---
title: "A shebang script stub cannot report the argv[0] a wrapper passed it"
date: "2026-10-19"
category: best-practices
module: "Nix flake checks (wrapper run against a stub target)"
problem_type: best_practice
component: testing_framework
severity: medium
applies_when:
  - "A check runs a wrapper against a stub that stands in for the program the wrapper execs"
  - "The check asserts the argv[0] the wrapper hands its target, because the real target reads argv[0], for example a self-extracting archive or a multi-call binary"
  - "Mutation-testing such a check with a mutation that changes argv[0], such as exec -a"
root_cause: logic_error
resolution_type: workflow_improvement
related_components:
  - tooling
tags:
  - mutation-testing
  - flake-checks
  - nix
  - stub-design
  - argv0
  - shebang
  - wrapper
---

# A shebang script stub cannot report the argv[0] a wrapper passed it

## Context

The since-removed `packages/antigravity-acp-path.nix` put `agy_acp_server.par` on PATH as a wrapper that ran `exec <store>/agy_acp_server.par "$@"`. The real `.par` loaded its embedded archive through argv[0], so the wrapper had to hand it the absolute store path. A symlink or `exec -a "$0"` would hand it something else. The former `tests/antigravity-acp-path.nix` check built the package against a stub runtime and ran the wrapper. Its first stub was a `writeShellScript` that printed `argv0=$0`.

The mutation `exec -a "$0" ${dir}/${executable.name} "$@"` survived. The assertion `[ "$(field argv0)" = "$runtimePar" ]` passed with the mutation in place.

## Why the script stub could not see it

Starting a `#!` script never passes the caller's argv[0] to the script. The kernel's script handler rebuilds the argument vector as the interpreter, its optional argument, the script path, and then the caller's remaining arguments. The caller's argv[0] is dropped. bash then sets `$0` to the script path it opened. A shell stub therefore reports its own path whatever argv[0] the wrapper chose. The assertion compared that path with the stub's path, so it was true whether or not the wrapper passed `-a`.

The same holds for any interpreter stub, Python's `sys.argv[0]` included. Reading the script's own `/proc/$$/cmdline` does not help either, because by then the vector already starts with the interpreter.

## The fix: a compiled stub

The stub became a C program, its source a `pkgs.writeText`, compiled by the `pkgs.runCommandCC` that built the stub runtime. It printed `argv[0]`, its PID, `SSL_CERT_FILE`, each argument, and every stdin line (historical `tests/antigravity-acp-path.nix:19-36`). A binary receives the argv[0] its caller passed. With that stub, the `exec -a "$0"` mutation failed with the check's own message, "argv[0] is ..., not ...". The other six wrapper mutations still failed too: CA default removed, preset overwritten, `"$@"` dropped, `exec` dropped, wrong target, helper link dropped.

The stub's PID also proved the wrapper execed instead of forking. The check started `bash -c 'echo "outer=$$"; exec "$@"'`, which execed `env -i`, which execed the wrapper. The stub's PID matched only when every step in that chain execed.

## How to apply

- When a check asserts argv[0], make the stub a compiled binary. A shell or Python stub tests nothing about argv[0].
- Before trusting the check, run the argv[0] mutation (`exec -a`) and confirm the check fails with its own message. That is the one round a script stub silently passes.
- Assertions about arguments, environment, stdin, and PID work with either kind of stub. Only argv[0] needs the binary.

Related: [mutation testing for check assertions](mutation-testing-reveals-decorative-nix-check-assertions.md) and [fixture state that cannot distinguish a bug from its fix](converged-fixture-state-defeats-nix-check-mutation-testing.md).
