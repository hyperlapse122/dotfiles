import base64
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
from urllib.parse import quote


def github_json(endpoint):
    result = subprocess.run(
        ["gh", "api", "--hostname", "github.com", endpoint],
        check=True, capture_output=True, text=True, encoding="utf-8", timeout=60,
    )
    return json.loads(result.stdout)


def resolve_release(source, fetch):
    repository = source["repository"]
    prefix = source["tagPrefix"]
    if not isinstance(repository, str) or not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        raise ValueError("Expected a GitHub owner/repository")
    if not isinstance(prefix, str) or not prefix:
        raise ValueError(f"{repository}: expected a nonempty tag prefix")
    base = f"repos/{repository}"
    release = fetch(f"{base}/releases/latest")
    if not isinstance(release, dict):
        raise ValueError(f"{repository}: expected a release object")
    tag = release.get("tag_name")
    if (not isinstance(tag, str) or not re.fullmatch(re.escape(prefix) + r"[0-9]+\.[0-9]+\.[0-9]+", tag)
            or release.get("draft") is not False or release.get("prerelease") is not False):
        raise ValueError(f"{repository}: expected a published stable {prefix}MAJOR.MINOR.PATCH release")
    reference = fetch(f"{base}/git/ref/tags/{quote(tag, safe='')}")
    if not isinstance(reference, dict) or reference.get("ref") != f"refs/tags/{tag}":
        raise ValueError(f"{repository} {tag}: expected the exact tag reference")
    target = reference.get("object")
    seen = set()
    while True:
        if not isinstance(target, dict):
            raise ValueError(f"{repository} {tag}: missing Git object")
        sha = target.get("sha")
        kind = target.get("type")
        if not isinstance(sha, str) or not re.fullmatch(r"[0-9a-fA-F]{40}", sha):
            raise ValueError(f"{repository} {tag}: expected a full Git SHA")
        sha = sha.lower()
        if kind == "commit":
            return {"tag": tag, "commit": sha}
        if kind != "tag" or sha in seen:
            raise ValueError(f"{repository} {tag}: expected an acyclic tag chain ending in a commit")
        seen.add(sha)
        annotated = fetch(f"{base}/git/tags/{sha}")
        if not isinstance(annotated, dict) or not isinstance(annotated.get("sha"), str) or annotated["sha"].lower() != sha:
            raise ValueError(f"{repository} {tag}: unexpected annotated tag object")
        target = annotated.get("object")


def allowed_tools(text):
    lines = text.splitlines()
    if not lines or lines[0] != "---" or "---" not in lines[1:]:
        return None
    for line in lines[1:lines.index("---", 1)]:
        key, separator, value = line.partition(":")
        if separator and key == "allowed-tools":
            return value.strip()
    return None


def check_skills(skill_set, pin, fetch):
    repository = skill_set["repository"]
    tree = fetch(f"repos/{repository}/git/trees/{pin['commit']}?recursive=1")["tree"]
    upstream = {}
    for entry in tree:
        match = re.fullmatch(r"skills/([^/]+)/SKILL\.md", entry["path"])
        if match and entry["type"] == "blob":
            upstream[match.group(1)] = entry["sha"]
    declared = skill_set["skills"]
    added = sorted(upstream.keys() - declared.keys())
    removed = sorted(declared.keys() - upstream.keys())
    if added or removed:
        raise ValueError(f"{repository} {pin['tag']}: skill set differs from the declaration; "
                         f"added upstream: {', '.join(added) or 'none'}; removed upstream: {', '.join(removed) or 'none'}")
    for name, blob in sorted(upstream.items()):
        text = base64.b64decode(fetch(f"repos/{repository}/git/blobs/{blob}")["content"]).decode("utf-8")
        actual = allowed_tools(text)
        if actual != declared[name]["allowedTools"]:
            raise ValueError(f"{repository} {pin['tag']}: {name} allowed-tools differs; "
                             f"declared {declared[name]['allowedTools']!r}, upstream {actual!r}")


def update_lock(root, fetch=github_json):
    data_dir = root / "home" / ".chezmoidata"
    plugins = json.loads((data_dir / "harness-plugins.json").read_text(encoding="utf-8"))["harnessPlugins"]
    skill_sets = json.loads((data_dir / "harness-skills.json").read_text(encoding="utf-8"))["harnessSkills"]
    plugin_pins = {name: resolve_release(plugin, fetch) for name, plugin in plugins.items()}
    skill_pins = {name: resolve_release(skill_set, fetch) for name, skill_set in skill_sets.items()}
    for name, skill_set in skill_sets.items():
        check_skills(skill_set, skill_pins[name], fetch)
    lock = {"harnessPluginLocks": plugin_pins, "harnessSkillLocks": skill_pins}
    lock_path = data_dir / "harness-plugin-lock.json"
    if lock_path.exists() and json.loads(lock_path.read_text(encoding="utf-8")) == lock:
        print("Harness plugin pins are unchanged")
        return False

    temporary = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w", encoding="utf-8", newline="\n", dir=data_dir, delete=False,
        ) as stream:
            temporary = Path(stream.name)
            stream.write(json.dumps(lock, indent=2, sort_keys=True) + "\n")
        os.replace(temporary, lock_path)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
    pins = {**plugin_pins, **skill_pins}
    print("Updated harness plugin pins: " + ", ".join(f"{name} {pin['tag']}" for name, pin in pins.items()))
    return True


if __name__ == "__main__":
    try:
        update_lock(Path(__file__).resolve().parents[1])
    except (ValueError, KeyError, TypeError, AttributeError, subprocess.SubprocessError, OSError) as error:
        raise SystemExit(f"Harness plugin lock refresh failed: {error}") from error
