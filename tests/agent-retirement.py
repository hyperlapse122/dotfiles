"""Exercise retirement against materialized generations and their real HM cleaner."""
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile


entries = json.loads(Path(sys.argv[1]).read_text())
old_files = Path(sys.argv[2])
assert entries, "no generations cover retirement"
for entry in entries:
    files = Path(entry["files"])
    for executable in ("pi", "pi-acp", "pi-acp-readonly", "opencode"):
        assert not os.path.lexists(Path(entry["path"]) / "bin" / executable), (entry["name"], executable)
    for root in (".pi", ".config/opencode"):
        assert not os.path.lexists(files / root), (entry["name"], "retired delivery", root)
    script = Path(entry["activate"]).read_text()
    cleaner = re.search(r"xargs -0 bash (/nix/store/[^\s]+-cleanup)", script)
    assert cleaner, "generation has no observable Home Manager cleanup helper"
    with tempfile.TemporaryDirectory() as directory:
        home = Path(directory)
        state = {}
        for relative in (".pi/agent/auth.json", ".pi/agent/settings.json",
                         ".pi/agent/sessions/history.jsonl", ".pi/agent/cache/keep",
                         ".config/opencode/auth.json", ".local/share/opencode/history.db",
                         ".omp/agent/sessions/newer.jsonl"):
            target = home / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(b"FAKE preserved user state\n")
            state[target] = target.read_bytes()
        retired = [str(path.relative_to(old_files)) for path in old_files.rglob("*") if path.is_symlink()]
        assert retired, "retirement fixture contains no managed links"
        for relative in retired:
            target = home / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.symlink_to(old_files / relative)
        env = dict(os.environ, HOME=str(home))
        env.pop("DRY_RUN", None)
        result = subprocess.run(["bash", cleaner[1], str(files), *retired],
                                env=env, capture_output=True, text=True)
        assert result.returncode == 0, result.stderr
        for relative in retired:
            assert not os.path.lexists(home / relative), "retired managed link survived"
        for target, content in state.items():
            assert target.read_bytes() == content, (entry["name"], "retirement changed user state", target)
