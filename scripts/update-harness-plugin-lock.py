import base64
import json
import os
from pathlib import Path
import re
import subprocess
import sys
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


class SkillDriftError(ValueError):
    """Raised after the lock is written when a skill pack kept its previous pin."""


def frontmatter_fields(text):
    lines = text.splitlines()
    if not lines or lines[0] != "---" or "---" not in lines[1:]:
        raise ValueError("expected YAML frontmatter")
    fields = {}
    for line in lines[1:lines.index("---", 1)]:
        # Indented, list, comment, and blank lines continue the previous key.
        if not line.strip() or line[0] in " \t#-":
            continue
        key, separator, value = line.partition(":")
        key = key.strip()
        if not separator or not key:
            raise ValueError(f"unexpected frontmatter line {line!r}")
        if key in fields:
            raise ValueError(f"duplicate frontmatter key {key!r}")
        fields[key] = value.strip()
    return fields


def check_skills(skill_set, pin, fetch):
    repository = skill_set["repository"]
    label = f"{repository} {pin['tag']}"
    listing = fetch(f"repos/{repository}/git/trees/{pin['commit']}?recursive=1")
    if listing.get("truncated") is not False:
        raise ValueError(f"{label}: the repository tree listing is truncated")
    tree = listing["tree"]
    upstream = {}
    for entry in tree:
        match = re.fullmatch(r"skills/([^/]+)/SKILL\.md", entry["path"])
        if match and entry["type"] == "blob":
            upstream[match.group(1)] = entry["sha"]
    declared = skill_set["skills"]
    added = sorted(upstream.keys() - declared.keys())
    removed = sorted(declared.keys() - upstream.keys())
    if added or removed:
        raise ValueError(f"{label}: skill set differs from the declaration; "
                         f"added upstream: {', '.join(added) or 'none'}; removed upstream: {', '.join(removed) or 'none'}")
    # Apply copies each declared skill's whole subtree, so only plain files and directories may ship in it.
    for entry in tree:
        match = re.fullmatch(r"skills/([^/]+)/(.+)", entry["path"])
        if not match or match.group(1) not in declared:
            continue
        if entry.get("mode") not in ("100644", "040000"):
            raise ValueError(f"{label}: {entry['path']} is not a regular file or directory (mode {entry.get('mode')})")
        if match.group(2).endswith("/SKILL.md"):
            raise ValueError(f"{label}: {entry['path']} nests another skill inside {match.group(1)}")
    allowed_keys = set(skill_set["frontmatterKeys"])
    for name, blob in sorted(upstream.items()):
        text = base64.b64decode(fetch(f"repos/{repository}/git/blobs/{blob}")["content"]).decode("utf-8")
        try:
            fields = frontmatter_fields(text)
        except ValueError as error:
            raise ValueError(f"{label}: {name} {error}") from error
        unreviewed = sorted(fields.keys() - allowed_keys)
        if unreviewed:
            raise ValueError(f"{label}: {name} frontmatter adds unreviewed keys: {', '.join(unreviewed)}")
        actual = fields.get("allowed-tools")
        if actual != declared[name]["allowedTools"]:
            raise ValueError(f"{label}: {name} allowed-tools differs; "
                             f"declared {declared[name]['allowedTools']!r}, upstream {actual!r}")


def update_lock(root, fetch=github_json):
    data_dir = root / "home" / ".chezmoidata"
    plugins = json.loads((data_dir / "harness-plugins.json").read_text(encoding="utf-8"))["harnessPlugins"]
    skill_sets = json.loads((data_dir / "harness-skills.json").read_text(encoding="utf-8"))["harnessSkills"]
    lock_path = data_dir / "harness-plugin-lock.json"
    previous = json.loads(lock_path.read_text(encoding="utf-8")) if lock_path.exists() else {}
    previous_skills = previous.get("harnessSkillLocks", {}) if isinstance(previous, dict) else {}
    plugin_pins = {name: resolve_release(plugin, fetch) for name, plugin in plugins.items()}
    skill_pins = {}
    drift = []
    for name, skill_set in skill_sets.items():
        try:
            pin = resolve_release(skill_set, fetch)
            check_skills(skill_set, pin, fetch)
        except (ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
            # A pack that cannot refresh keeps its last reviewed pin so plugin pins still move.
            if name not in previous_skills:
                raise
            drift.append(f"{name}: {error}")
            pin = previous_skills[name]
        skill_pins[name] = pin
    lock = {"harnessPluginLocks": plugin_pins, "harnessSkillLocks": skill_pins}
    if previous == lock:
        print("Harness plugin pins are unchanged")
        if drift:
            raise SkillDriftError("; ".join(drift))
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
    if drift:
        raise SkillDriftError("; ".join(drift))
    return True


# Exit status the refresh workflow reads as "lock written, but a skill pack kept its previous pin".
SKILL_DRIFT_EXIT = 3

if __name__ == "__main__":
    try:
        update_lock(Path(__file__).resolve().parents[1])
    except SkillDriftError as error:
        print(f"Shared skill pins kept at their previous release: {error}", file=sys.stderr)
        raise SystemExit(SKILL_DRIFT_EXIT) from error
    except (ValueError, KeyError, TypeError, AttributeError, subprocess.SubprocessError, OSError) as error:
        raise SystemExit(f"Harness plugin lock refresh failed: {error}") from error
