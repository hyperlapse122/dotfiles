import json, os, re, stat, subprocess, sys, tempfile
from pathlib import Path
body = Path(sys.argv[1]).read_text()
artifact = re.sub(r"/nix/store/[a-z0-9]{32}-[^\s\"\'\x60;]+", "<store-path>", body)
assert not re.search(r"auths|token|password", artifact, re.IGNORECASE), "containersAuth activation embeds credential material"
with tempfile.TemporaryDirectory() as work:
    home = Path(work) / "home"
    home.mkdir()
    redirected = body.replace('$HOME', str(home))
    assert redirected != body and '$HOME' not in redirected, "containersAuth destination was not redirected"
    env = dict(os.environ, HOME=str(home))
    env.pop("DRY_RUN", None)
    def run(dry=False):
        current = dict(env)
        if dry:
            current["DRY_RUN"] = "1"
        result = subprocess.run(["bash", "-euo", "pipefail", "-c",
            'run() { if [[ ! -v DRY_RUN ]]; then "$@"; fi; };\n' + redirected], env=current, capture_output=True, text=True)
        assert result.returncode == 0, result.stderr
    target = home / ".config/containers/auth.json"
    run(True)
    assert list(home.iterdir()) == [], "containersAuth dry-run changed fresh home"
    run()
    assert target.is_file(), "containersAuth did not create auth.json"
    assert json.loads(target.read_text()) == {"credHelpers": {key: "sops" for key in
        ["docker.io", "ghcr.io", "registry.gitlab.com", "registry.jpi.app"]}}, "containersAuth wrote incorrect JSON"
    assert stat.S_IMODE(target.stat().st_mode) == 0o600, "auth.json mode is not 0600"
    assert stat.S_IMODE(target.parent.stat().st_mode) == 0o700, "containers directory mode is not 0700"
    custom = b'{ "custom": "preserve exact bytes" }\n'
    target.write_bytes(custom)
    target.chmod(0o640)
    target.parent.chmod(0o750)
    for dry in (False, True):
        run(dry)
        assert target.read_bytes() == custom, "containersAuth overwrote existing bytes"
        assert stat.S_IMODE(target.stat().st_mode) == 0o640, "containersAuth changed existing file mode"
        assert stat.S_IMODE(target.parent.stat().st_mode) == 0o750, "containersAuth changed existing directory mode"
