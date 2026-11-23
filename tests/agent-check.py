"""Exercise the checkout-local agent-check against disposable Git repositories."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


HELPER = Path(sys.argv[1]).resolve()


def run(*args, cwd, expected=0, env=None):
    result = subprocess.run(args, cwd=cwd, text=True, capture_output=True, env=env)
    assert result.returncode == expected, (args, result.returncode, result.stdout, result.stderr)
    return result.stdout + result.stderr


def fixture(root):
    repo = root / "repo with spaces"
    repo.mkdir()
    run("git", "init", "-q", "-b", "main", cwd=repo)
    for key, value in (("user.name", "Agent Check Test"), ("user.email", "test@example.invalid"),
                       ("commit.gpgsign", "false")):
        run("git", "config", key, value, cwd=repo)
    (repo / "tracked file").write_text("committed\n")
    (repo / "mise.toml").write_text("[settings]\n")
    (repo / "scripts").mkdir()
    for name in ("agent-check", "agent-check-inspect.py", "check-changed-files", "lint-staged-markdown"):
        shutil.copy2(HELPER.parent / name, repo / "scripts" / name)
    run("git", "add", ".", cwd=repo)
    run("git", "commit", "-qm", "base", cwd=repo)
    return repo


def exercise(root):
    repo = fixture(root)
    bin_dir = root / "bin"
    bin_dir.mkdir()
    nixfmt = bin_dir / "nixfmt"
    nixfmt.write_text(f"#!{shutil.which('bash')}\n" + """\
set -eu
shift
for file in "$@"; do
    printf '%s=%s\n' "$file" "$(cat -- "$file")"
    if grep -q BAD "$file"; then exit 1; fi
done
""")
    nixfmt.chmod(0o755)
    # Model a shim that requires temporary trust only in the snapshot.
    python = bin_dir / "python3"
    snapshot_record = root / "snapshot-record"
    python.write_text(f"#!{shutil.which('bash')}\n" + f"""\
set -eu
if [[ "$PWD" != '{repo}' ]]; then
    [[ "${{MISE_TRUSTED_CONFIG_PATHS:-}}" == "$(pwd -P)" && "${{MISE_SAFE:-}}" == 1 ]] || exit 91
    printf '%s\n' "$PWD" >> '{snapshot_record}'
fi
exec '{sys.executable}' "$@"
""")
    python.chmod(0o755)
    env = dict(os.environ, PATH=f"{bin_dir}:{os.environ['PATH']}")
    def check(*args, cwd=repo, expected=0):
        return run(cwd / "scripts/agent-check", *args, cwd=cwd, expected=expected, env=env)

    assert check() == ""
    other = root / "unrelated"
    other.mkdir()
    run("git", "init", "-q", cwd=other)
    (other / "unrelated.py").write_text("subprocess.run(task, shell=True)\n")
    output = run(repo / "scripts/agent-check", cwd=other, expected=1, env=env)
    assert "run from this dotfiles checkout" in output and "python_subprocess_shell" not in output, output
    (repo / "sample.nix").write_text("GOOD working\n")
    assert check() == ""  # Successful project output stays quiet.
    (repo / "sample.nix").write_text("BAD staged\n")
    run("git", "add", "sample.nix", cwd=repo)
    (repo / "sample.nix").write_text("GOOD working\n")
    output = check("--staged", expected=1)
    assert "BAD staged" in output and "GOOD working" not in output, output
    assert (repo / "sample.nix").read_text() == "GOOD working\n"
    assert run("git", "show", ":sample.nix", cwd=repo) == "BAD staged\n"
    run("git", "commit", "-qm", "add sample", cwd=repo)
    output = check("--range", "HEAD^", "HEAD", expected=1)
    assert "BAD staged" in output and "GOOD working" not in output, output

    # The selected tree supplies its own project-check implementation.
    project_check = repo / "scripts/check-changed-files"
    project_check.write_text("#!/usr/bin/env bash\nfor ((i=1; i<=150; i++)); do echo diagnostic-$i; done\nexit 17\n")
    (repo / "warning.py").write_text("subprocess.run(task, shell=True)\n")
    run("git", "add", "scripts/check-changed-files", "warning.py", cwd=repo)
    project_check.write_text("#!/usr/bin/env bash\nexit 19\n")
    output = check("--staged", expected=17)
    assert "python_subprocess_shell" in output and "diagnostic-100" in output, output
    assert "diagnostic-101" not in output and len(output.splitlines()) == 101, output
    assert snapshot_record.read_text().splitlines(), "snapshot shim was not called"
    run("git", "commit", "-qm", "change project check", cwd=repo)
    output = check("--range", "HEAD^", "HEAD", expected=17)
    assert "python_subprocess_shell" in output and "diagnostic-100" in output, output
    assert "diagnostic-101" not in output and len(output.splitlines()) == 101, output
    run("git", "restore", "scripts/check-changed-files", cwd=repo)
    # Restore the real project checker for the linked-worktree test.
    shutil.copy2(HELPER.parent / "check-changed-files", project_check)
    run("git", "add", "scripts/check-changed-files", cwd=repo)
    run("git", "commit", "-qm", "restore project check", cwd=repo)

    # A linked checkout's script wins over an executable with the same name on PATH.
    linked = root / "linked worktree"
    run("git", "worktree", "add", "-q", "-b", "linked", str(linked), cwd=repo)
    competitor = bin_dir / "agent-check"
    competitor.write_text(f"#!{shutil.which('bash')}\necho wrong-checker >&2\nexit 98\n")
    competitor.chmod(0o755)
    (linked / "sample.nix").write_text("BAD linked\n")
    output = check(cwd=linked, expected=1)
    assert "BAD linked" in output and "wrong-checker" not in output, output


def exercise_checks(root):
    repo = fixture(root)
    helper = repo / "scripts/agent-check"
    (repo / "package.json").write_text('{"dependencies":{"already-present":"1"}}')
    run("git", "add", ".", cwd=repo)
    run("git", "commit", "-qm", "declare an existing dependency", cwd=repo)

    (repo / "changed file.py").write_text(
        'password = "fixture-plaintext-must-not-print"\n'
        'subprocess.run(task, shell=True)\n'
    )
    (repo / "package.json").write_text(json.dumps({"dependencies": {
        "already-present": "2",
        "alias": "npm:@team/private-pkg@^1",
        "public-pkg": "^1",
        "local-pkg": "file:../local",
        "remote-pkg": "https://user:fixture-password@bad.invalid/pkg.tgz",
    }}))
    (repo / ".npmrc").write_text("@team:registry=https://bad.invalid/\n")
    (repo / "pyproject.toml").write_text(
        '[project]\ndependencies=["Present_Name[extra]>=2; python_version >= \'3.11\'", '
        '"local-python @ file:///tmp/local"]\n'
        '[dependency-groups]\ndev=["another-package", {include-group="other"}]\n'
        'other=["another-package"]\n'
    )
    (repo / "go.mod").write_text(
        "module fixture\n"
        "go 1.26\n"
        "require (\n example.com/Public v1.2.3 // indirect\n example.com/local v1.0.0\n)\n"
        "replace example.com/local => ../local\n"
    )
    policy = {
        "public": {"npm": ["public-pkg"], "python": ["present-name", "another-package"],
                   "go": ["example.com/Public"]},
        "private": {"npm": {"@team/": {"url": "https://trusted.invalid/npm", "tokenEnv": "TEST_TOKEN"}}},
    }
    policy_file = root / "registry policy.json"
    policy_file.write_text(json.dumps(policy))
    calls = root / "calls"
    bin_dir = root / "bin"
    bin_dir.mkdir()
    curl = bin_dir / "curl"
    curl.write_text(f"#!{sys.executable}\n" + """\
import json, os, sys
url = sys.argv[-1]
headers = sys.stdin.read()
assert "TEST_TOKEN" not in os.environ
assert sys.argv[1] == "-q" and "--location" not in sys.argv
with open(os.environ["CALLS"], "a") as log:
    print(url, file=log)
if url.startswith("https://trusted.invalid/npm/@team%2F"):
    assert headers == "Authorization: Bearer fake-test-token\\n"
    if url.endswith("%2Fprivate-pkg"):
        body, status = {"name": "@team/private-pkg", "downloads": 9}, 200
    else:
        assert url.endswith("%2Fmissing-private")
        body, status = {}, 404
else:
    assert headers == ""
    if url == "https://registry.npmjs.org/public-pkg":
        body, status = {"name": "public-pkg", "time": {"created": "2026-01-02T03:04:05Z"}}, 200
    elif url == "https://api.npmjs.org/downloads/point/last-week/public-pkg":
        body, status = {"downloads": 18}, 200
    elif url in ("https://pypi.org/pypi/present-name/json", "https://pypi.org/pypi/another-package/json"):
        body, status = {"info": {"name": url.split("/")[-2]}, "urls": [{"upload_time_iso_8601": "2026-02-03T00:00:00Z"}]}, 200
    elif url == "https://proxy.golang.org/example.com/!public/@v/v1.2.3.info":
        body, status = {"Version": "v1.2.3", "Time": "2026-03-04T00:00:00Z"}, 200
    elif url == "https://registry.npmjs.org/missing-pkg":
        body, status = {"error": "fixture-plaintext-must-not-print"}, 404
    elif url == "https://registry.npmjs.org/unavailable-pkg":
        body, status = {"error": "fixture-plaintext-must-not-print"}, 503
    else:
        raise AssertionError(url)
sys.stdout.write(json.dumps(body) + "\\n" + str(status))
""")
    curl.chmod(0o755)
    env = dict(os.environ, PATH=f"{bin_dir}:{os.environ['PATH']}", CALLS=str(calls),
               TEST_TOKEN="fake-test-token")
    offline = run(helper, cwd=repo, env=env)
    assert "python_subprocess_shell" in offline and "hardcoded_credential" in offline, offline
    assert "fixture-plaintext-must-not-print" not in offline and not calls.exists(), offline
    run("git", "add", ".", cwd=repo)
    assert "python_subprocess_shell" in run(helper, "--staged", cwd=repo, env=env)
    assert not calls.exists()
    run("git", "commit", "-qm", "add dependencies", cwd=repo)
    assert run("git", "status", "--porcelain", cwd=repo) == ""
    # Policy mode must not evaluate task definitions or run a project executable.
    (repo / "Makefile").write_text("agent-check:\n\t@exit 97\n")
    (repo / "mise.toml").write_text('[tasks.agent-check]\nrun = "exit 98"\n')
    run("git", "add", "Makefile", "mise.toml", cwd=repo)
    run("git", "commit", "--amend", "--no-edit", "-q", cwd=repo)
    local_bin = repo / "node_modules/.bin"
    local_bin.mkdir(parents=True)
    for name in ("curl", "mise"):
        shadow = local_bin / name
        shadow.write_text(f"#!{shutil.which('bash')}\ntouch '{root / 'project-tool-ran'}'\nexit 99\n")
        shadow.chmod(0o755)
    (repo / ".git/info/exclude").write_text("/node_modules/\n")
    (repo / "package.json").write_text('{"dependencies":{"dirty-only":"1"}}')
    output = run(helper, "--registry-policy", policy_file, "--range", "HEAD^", "HEAD",
                 cwd=repo, env=env)
    assert "downloads 18 (last week)" in output and "downloads 9" in output, output
    assert all(day in output for day in ("2026-01-02", "2026-02-03", "2026-03-04")), output
    assert "publication date unavailable" in output and "downloads unavailable" in output, output
    assert [line.split(": ", 2)[1] for line in output.splitlines()] == [
        "go example.com/Public", "npm @team/private-pkg", "npm public-pkg",
        "python another-package", "python present-name",
    ], output
    assert set(calls.read_text().splitlines()) == {
        "https://trusted.invalid/npm/@team%2Fprivate-pkg",
        "https://registry.npmjs.org/public-pkg",
        "https://api.npmjs.org/downloads/point/last-week/public-pkg",
        "https://pypi.org/pypi/present-name/json",
        "https://pypi.org/pypi/another-package/json",
        "https://proxy.golang.org/example.com/!public/@v/v1.2.3.info",
    }
    assert "fake-test-token" not in output and "fixture-password" not in output, output
    assert not (root / "project-tool-ran").exists()

    policy["public"]["npm"] += ["missing-pkg", "unavailable-pkg", "@team/missing-private"]
    policy_file.write_text(json.dumps(policy))
    (repo / "package.json").write_text(json.dumps({"dependencies": {
        "missing-pkg": "*", "unavailable-pkg": "*", "@unapproved/private": "*",
        "@team/missing-private": "*",
    }}))
    output = run(helper, "--registry-policy", policy_file, cwd=repo, env=env, expected=1)
    assert "missing-pkg: missing" in output and "unavailable-pkg: lookup incomplete" in output, output
    assert "fixture-plaintext-must-not-print" not in output and "@unapproved/private" not in output
    assert "no approved registry" in output and "@team/missing-private: missing" in output, output
    assert all(x not in calls.read_text() for x in ("bad.invalid", "@unapproved", "registry.npmjs.org/@team"))

    (repo / "policy.json").write_text(json.dumps(policy))
    count = calls.read_bytes()
    output = run(helper, "--registry-policy", repo / "policy.json", cwd=repo, env=env, expected=1)
    assert "outside the checkout" in output and calls.read_bytes() == count, output

    (repo / "Makefile").unlink()
    (repo / "mise.toml").unlink()
    output = run(helper, "--registry-policy", policy_file, cwd=repo, env=env, expected=1)
    assert "missing-pkg: missing" in output, output

    # The index's scope wins over the unstaged config and conflicting public approval.
    policy["public"]["npm"] += ["@sealed/private"]
    policy_file.write_text(json.dumps(policy))
    (repo / "package.json").write_text('{"dependencies":{"alias":"npm:@sealed/private@1"}}')
    (repo / ".npmrc").write_text('@sealed:registry = "${PRIVATE_REGISTRY}"\n')
    run("git", "add", "package.json", ".npmrc", cwd=repo)
    (repo / ".npmrc").write_text("@sealed:registry=https://registry.npmjs.org/\n")
    count = calls.read_bytes()
    output = run(helper, "--registry-policy", policy_file, "--staged", cwd=repo, env=env, expected=1)
    assert "no approved registry" in output and calls.read_bytes() == count, output
    (repo / ".npmrc").write_text('@${FIXTURE_SCOPE}:registry=https://private.example.invalid/\n')
    output = run(helper, "--registry-policy", policy_file, cwd=repo, env=env, expected=1)
    assert "no approved registry" in output and calls.read_bytes() == count, output

    # A default registry change alone can reroute an existing unscoped package.
    (repo / "package.json").write_text('{"dependencies":{"public-pkg":"1"}}')
    (repo / ".npmrc").unlink()
    (repo / ".npmrc").symlink_to("registry.data")
    (repo / "registry.data").write_text("registry=https://registry.npmjs.org/\n")
    run("git", "add", "package.json", ".npmrc", "registry.data", cwd=repo)
    run("git", "commit", "-qm", "establish public npm route", cwd=repo)
    (repo / "registry.data").write_text("registry=https://private.example.invalid/\n")
    run("git", "add", "registry.data", cwd=repo)
    output = run(helper, "--registry-policy", policy_file, "--staged", cwd=repo, env=env, expected=1)
    assert "no approved registry" in output and calls.read_bytes() == count, output

    # A rename keeps the old manifest's dependency set, even with no approvals.
    run("git", "restore", "--source=HEAD", "--staged", "--worktree", "registry.data", cwd=repo)
    (repo / "sub").mkdir()
    run("git", "mv", "package.json", "sub/package.json", cwd=repo)
    run("git", "commit", "-qm", "move manifest", cwd=repo)
    policy_file.write_text("{}")
    assert run(helper, "--registry-policy", policy_file, "--range", "HEAD^", "HEAD",
               cwd=repo, env=env) == ""
    assert calls.read_bytes() == count

    # A tracked manifest link participates when only its target changes.
    run("git", "mv", "sub/package.json", "manifest.data", cwd=repo)
    (repo / "package.json").symlink_to("manifest.data")
    run("git", "add", "package.json", cwd=repo)
    run("git", "commit", "-qm", "link manifest", cwd=repo)
    (repo / "manifest.data").write_text('{"dependencies":{"public-pkg":"1","unapproved":"1"}}')
    run("git", "add", "manifest.data", cwd=repo)
    run("git", "commit", "-qm", "change link target", cwd=repo)
    output = run(helper, "--registry-policy", policy_file, "--range", "HEAD^", "HEAD",
                 cwd=repo, env=env, expected=1)
    assert output.count("no approved registry") == 1, output
    (repo / "package.json").unlink()
    (repo / "package.json").symlink_to("../outside.json")
    (root / "outside.json").write_text('{"dependencies":{"public-pkg":"1"}}')
    output = run(helper, "--registry-policy", policy_file, cwd=repo, env=env, expected=1)
    assert "invalid manifest" in output and calls.read_bytes() == count, output



with tempfile.TemporaryDirectory() as directory:
    exercise(Path(directory))
print("agent-check: checkout, index, linked worktree, and commit range passed")

with tempfile.TemporaryDirectory() as directory:
    exercise_checks(Path(directory))
print("agent-check: local warnings, trusted registry routing, metadata, and failures passed")
