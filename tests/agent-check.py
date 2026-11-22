"""Exercise the packaged agent-check against disposable Git repositories."""

from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


HELPER = Path(sys.argv[1]).resolve()


def run(*args, cwd, expected=0):
    result = subprocess.run(args, cwd=cwd, text=True, capture_output=True)
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


with tempfile.TemporaryDirectory() as directory:
    exercise(Path(directory))
print("agent-check: clean, missing task, index, worktree, failure, and commit range passed")
