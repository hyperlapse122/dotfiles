"""Run the user-defaults block of a nix-darwin system activate script with
stub commands, and check the Dock writes it makes against the Dock options.

Usage: dock-writes.py <activate> <expected-dock.json> <user>

Running the block, rather than matching its text, fails a write that is
echoed, skipped, or overridden in a form the check cannot read.
"""

import json
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

activate_path, expected_path, user = sys.argv[1:4]
lines = Path(activate_path).read_text().splitlines(keepends=True)
expected = json.loads(Path(expected_path).read_text())


def fail(message):
    print(f"the system activation {message}", file=sys.stderr)
    sys.exit(1)


start = next(
    (i for i, line in enumerate(lines) if line.strip() == 'echo >&2 "user defaults..."'),
    None,
)
end = None
if start is not None:
    end = next(
        (i for i in range(start, len(lines)) if "killall" in lines[i] and "Dock" in lines[i]),
        None,
    )
if start is None or end is None:
    fail("has no user-defaults block that restarts the Dock")
if "com.apple.dock" in "".join(lines[:start] + lines[end + 1 :]):
    fail("touches com.apple.dock outside its user-defaults block")

bash = shutil.which("bash")
stub_sources = {
    "launchctl": f'#!{bash}\n[ "$1" = asuser ] || exit 1\nshift 2\nexec "$@"\n',
    "sudo": (
        f"#!{bash}\nwho=\n"
        'while [ $# -gt 0 ]; do\n'
        '  case "$1" in --user=*) who=${1#--user=} ;; --) shift; break ;; esac\n'
        "  shift\n"
        "done\n"
        'STUB_USER=$who exec "$@"\n'
    ),
    "id": f"#!{bash}\necho 501\n",
}
recorder = (
    f"#!{sys.executable}\n"
    "import json, os, sys\n"
    'with open(os.environ["STUB_LOG"], "a") as log:\n'
    "    log.write(json.dumps({\n"
    '        "command": os.path.basename(sys.argv[0]),\n'
    '        "user": os.environ.get("STUB_USER"),\n'
    '        "args": sys.argv[1:],\n'
    '    }) + "\\n")\n'
)
stub_sources["defaults"] = recorder
stub_sources["killall"] = recorder

with tempfile.TemporaryDirectory() as scratch:
    stubs = Path(scratch, "bin")
    stubs.mkdir()
    for name, source in stub_sources.items():
        stub = stubs / name
        stub.write_text(source)
        stub.chmod(0o755)
    block = Path(scratch, "user-defaults.sh")
    block.write_text("".join(lines[start : end + 1]))
    log = Path(scratch, "calls.jsonl")
    log.touch()
    env = dict(os.environ, PATH=f"{stubs}:{os.environ['PATH']}", STUB_LOG=str(log))
    run = subprocess.run(
        [bash, "-euo", "pipefail", str(block)], env=env, stdout=subprocess.DEVNULL
    )
    if run.returncode != 0:
        fail(f"user-defaults block exits {run.returncode}")
    calls = [json.loads(line) for line in log.read_text().splitlines()]

problems = []
writes = {}
for call in calls:
    args = call["args"]
    if call["command"] != "defaults" or "com.apple.dock" not in args:
        continue
    if call["user"] != user:
        problems.append(f"writes the Dock as {call['user']!r}, not {user!r}")
    if len(args) != 4 or args[:2] != ["write", "com.apple.dock"] or not args[3].startswith("<?xml"):
        problems.append(f"runs a Dock defaults call the check cannot read: {args[:3]}")
        continue
    writes[args[2]] = plistlib.loads(args[3].encode())

if sorted(writes) != sorted(expected):
    problems.append(f"writes Dock keys {sorted(writes)}, not {sorted(expected)}")
for key, value in expected.items():
    if key in writes and writes[key] != value:
        problems.append(f"writes {key} as {writes[key]!r}, not {value!r}")
if not any(
    call["command"] == "killall" and "Dock" in call["args"] and user in call["args"]
    for call in calls
):
    problems.append(f"does not restart {user}'s Dock")

for problem in problems:
    print(f"the system activation {problem}", file=sys.stderr)
sys.exit(1 if problems else 0)
