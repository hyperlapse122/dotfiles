"""Exercise the packaged agent-check against disposable Git repositories."""

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
    (repo / "check").write_text(f"#!{shutil.which('bash')}\n" + '''\
set -eu
while IFS= read -r -d '' file; do
    printf '%s=%s\\n' "$file" "$(cat -- "$file")" >&2
done < "$AGENT_CHECK_FILES"
agent-check-fixture-tool >&2
for ((i = 0; i < 150; i++)); do printf 'diagnostic %d\\n' "$i" >&2; done
exit 17
''')
    (repo / "check").chmod(0o755)
    run("git", "add", ".", cwd=repo)
    run("git", "commit", "-qm", "base", cwd=repo)
    return repo


def exercise(root):
    repo = fixture(root)
    def check(*args, expected=0):
        return run(HELPER, *args, cwd=repo, expected=expected)
    assert check() == ""
    (repo / "untracked file").write_text("untracked\n")
    (repo / "Makefile").write_text("all: agent-check\n")
    assert check() == ""
    (repo / "Makefile").unlink()

    # The task uses a local tool even if the launcher appends its own tools.
    (repo / ".git/info/exclude").write_text("/node_modules/\n")
    local_bin = repo / "node_modules/.bin"
    local_bin.mkdir(parents=True)
    tool = local_bin / "agent-check-fixture-tool"
    tool.write_text(f"#!{shutil.which('bash')}\nprintf 'project tool\\n'\n")
    tool.chmod(0o755)
    (repo / "tracked file").write_text("staged\n")
    (repo / "mise.toml").write_text('[tasks.agent-check]\nrun = "./check"\n')
    run("git", "add", "tracked file", "mise.toml", cwd=repo)
    (repo / "tracked file").write_text("working copy\n")
    (repo / "mise.toml").write_text('[tasks.agent-check]\nrun = "exit 19"\n')

    output = check("--staged", expected=17)
    assert "tracked file=staged" in output and "untracked file=" not in output, output
    assert "project tool" in output and len(output.splitlines()) <= 101, output
    assert (repo / "tracked file").read_text() == "working copy\n"
    assert run("git", "show", ":tracked file", cwd=repo) == "staged\n"

    (repo / "mise.toml").unlink()
    run("git", "reset", "-q", "HEAD", "mise.toml", cwd=repo)
    (repo / "Makefile").write_text(".PHONY: agent-check\nagent-check:\n\t@./check\n")
    # GNU Make represents a failing recipe with exit code 2.
    output = check(expected=2)
    assert "tracked file=working copy" in output and "untracked file=untracked" in output, output
    (repo / "justfile").write_text("agent-check:\n    @./check\n")
    (repo / "Makefile").unlink()
    output = check(expected=17)
    assert "tracked file=working copy" in output, output
    (repo / "justfile").unlink()

    (repo / "mise.toml").write_text('[tasks.agent-check]\nrun = "./check"\n')
    (repo / "package.json").write_text('{"name":"fixture"}\n')
    run("git", "add", "mise.toml", "package.json", "tracked file", "untracked file", cwd=repo)
    run("git", "commit", "-qm", "add manifest", cwd=repo)
    assert run("git", "status", "--porcelain", cwd=repo) == ""
    assert check() == ""
    assert 'package.json={"name":"fixture"}' in check("--range", "HEAD^", "HEAD", expected=17)

    (repo / "package.json").write_text("dirty manifest\n")
    (repo / "mise.toml").unlink()
    output = check("--range", "HEAD^", "HEAD", expected=17)
    assert 'package.json={"name":"fixture"}' in output, output


def exercise_checks(root):
    repo = fixture(root)
    (repo / "Makefile").write_text(".PHONY: agent-check\nagent-check:\n\t@true\n")
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
    policy_file = root / "registries.json"
    policy_file.write_text(json.dumps(policy))
    calls = root / "calls"
    bin_dir = root / "bin"
    bin_dir.mkdir()
    curl = bin_dir / "curl"
    curl.write_text(f"#!{sys.executable}\n" + """\
import json, os, sys
url = sys.argv[-1]
headers = sys.stdin.read()
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
    offline = run(HELPER, cwd=repo, env=env)
    assert "python_subprocess_shell" in offline and "hardcoded_credential" in offline, offline
    assert "fixture-plaintext-must-not-print" not in offline and not calls.exists(), offline
    run("git", "add", ".", cwd=repo)
    assert "python_subprocess_shell" in run(HELPER, "--staged", cwd=repo, env=env)
    assert not calls.exists()
    run("git", "commit", "-qm", "add dependencies", cwd=repo)
    assert run("git", "status", "--porcelain", cwd=repo) == ""
    (repo / "package.json").write_text('{"dependencies":{"dirty-only":"1"}}')
    output = run(HELPER, "--registry-policy", policy_file, "--range", "HEAD^", "HEAD",
                 cwd=repo, env=env)
    assert "downloads 18 (last week)" in output and "downloads 9" in output, output
    assert all(day in output for day in ("2026-01-02", "2026-02-03", "2026-03-04")), output
    assert "publication date unavailable" in output and "downloads unavailable" in output, output
    assert set(calls.read_text().splitlines()) == {
        "https://trusted.invalid/npm/@team%2Fprivate-pkg",
        "https://registry.npmjs.org/public-pkg",
        "https://api.npmjs.org/downloads/point/last-week/public-pkg",
        "https://pypi.org/pypi/present-name/json",
        "https://pypi.org/pypi/another-package/json",
        "https://proxy.golang.org/example.com/!public/@v/v1.2.3.info",
    }
    assert "fake-test-token" not in output and "fixture-password" not in output, output

    policy["public"]["npm"] += ["missing-pkg", "unavailable-pkg", "@team/missing-private"]
    policy_file.write_text(json.dumps(policy))
    (repo / "package.json").write_text(json.dumps({"dependencies": {
        "missing-pkg": "*", "unavailable-pkg": "*", "@unapproved/private": "*",
        "@team/missing-private": "*",
    }}))
    output = run(HELPER, "--registry-policy", policy_file, cwd=repo, env=env, expected=1)
    assert "missing-pkg: missing" in output and "unavailable-pkg: lookup incomplete" in output, output
    assert "fixture-plaintext-must-not-print" not in output and "@unapproved/private" not in output
    assert "no approved registry" in output and "@team/missing-private: missing" in output, output
    assert all(x not in calls.read_text() for x in ("bad.invalid", "@unapproved", "registry.npmjs.org/@team"))

    (repo / "policy.json").write_text(json.dumps(policy))
    count = calls.read_bytes()
    output = run(HELPER, "--registry-policy", repo / "policy.json", cwd=repo, env=env, expected=1)
    assert "outside the checkout" in output and calls.read_bytes() == count, output



with tempfile.TemporaryDirectory() as directory:
    exercise(Path(directory))
print("agent-check: clean, missing task, index, worktree, failure, and commit range passed")

with tempfile.TemporaryDirectory() as directory:
    exercise_checks(Path(directory))
print("agent-check: local warnings, trusted registry routing, metadata, and failures passed")
