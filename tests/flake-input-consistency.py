"""Compare the flake input registry with flake.lock and the existing pins.

The registry, the lock, and the pin files are maintained independently; this
script reports every disagreement with its own message so a check failure names
which source drifted.
"""

import json
import re
import sys

COMMIT = re.compile(r"^[0-9a-f]{40}$")


def load(path):
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle)


def parse_repo(repo, errors, where):
    if ":" not in repo:
        errors.append(f"{where}: repository {repo!r} has no type prefix")
        return None
    kind, rest = repo.split(":", 1)
    parts = rest.split("/")
    if len(parts) != 2 or not all(parts):
        errors.append(f"{where}: repository {repo!r} must be <type>:<owner>/<name>")
        return None
    return kind, parts[0], parts[1]


def normalize_edge(edge):
    if isinstance(edge, list):
        return edge
    if isinstance(edge, str):
        return [edge]
    return None


def check_entry(inputs, lock, where, entry, node_name, top, errors):
    nodes = lock.get("nodes", {})
    node = nodes.get(node_name)
    if node is None:
        errors.append(f"{where}: flake.lock has no node {node_name!r}")
        return
    parsed = parse_repo(entry["repo"], errors, where)
    if parsed is None:
        return
    kind, owner, name = parsed
    original = node.get("original", {})
    if original.get("type") != kind:
        errors.append(f"{where}: flake.lock records type {original.get('type')!r}, registry says {kind!r}")
    recorded = f"{original.get('owner')}/{original.get('repo')}"
    if recorded != f"{owner}/{name}":
        errors.append(f"{where}: flake.lock records repository {recorded!r}, registry says '{owner}/{name}'")
    if "ref" in entry:
        if original.get("ref") != entry["ref"]:
            errors.append(f"{where}: flake.lock records ref {original.get('ref')!r}, registry expects {entry['ref']!r}")
    elif "rev" in entry:
        if original.get("rev") != entry["rev"]:
            errors.append(f"{where}: flake.lock records rev {original.get('rev')!r}, registry expects {entry['rev']!r}")
    elif "ref" in original or "rev" in original:
        errors.append(f"{where}: registry tracks the default branch, but flake.lock records a ref or rev")
    locked_rev = node.get("locked", {}).get("rev", "")
    if not COMMIT.match(locked_rev):
        errors.append(f"{where}: flake.lock records no usable revision")
    if top or "flake" in entry:
        expected_flag = entry.get("flake", True)
        locked_flag = node.get("flake", True)
        if expected_flag != locked_flag:
            errors.append(f"{where}: flake.lock records flake={locked_flag}, registry says {expected_flag}")
    for child_name, child in entry.get("inputs", {}).items():
        edge = node.get("inputs", {}).get(child_name)
        if edge is None:
            errors.append(f"{where}: flake.lock has no edge for input {child_name!r}")
            continue
        if "follows" in child:
            if normalize_edge(edge) != child["follows"].split("/"):
                errors.append(
                    f"{where}: flake.lock follows {edge!r} for {child_name!r}, registry expects {child['follows']!r}"
                )
        else:
            if not isinstance(edge, str):
                errors.append(f"{where}: flake.lock resolves {child_name!r} by follows, registry declares a repository")
                continue
            check_entry(inputs, lock, f"{where}.inputs.{child_name}", child, edge, False, errors)


def main(argv):
    if len(argv) != 3:
        print("usage: flake-input-consistency.py REGISTRY LOCK EXPECTATIONS", file=sys.stderr)
        return 2
    registry_path, lock_path, expectations_path = argv
    registry = load(registry_path)
    lock = load(lock_path)
    expectations = load(expectations_path)
    errors = []

    inputs = registry.get("inputs", {})
    root = lock.get("nodes", {}).get("root", {}).get("inputs", {})
    if not inputs:
        errors.append("registry declares no inputs")
    if not root:
        errors.append("flake.lock records no root inputs")

    classes = {
        "ref-pinned": [n for n, e in inputs.items() if "ref" in e],
        "rev-pinned": [n for n, e in inputs.items() if "rev" in e],
        "non-flake": [n for n, e in inputs.items() if e.get("flake") is False],
        "follows": [
            f"{n}.{c}"
            for n, e in inputs.items()
            for c, child in e.get("inputs", {}).items()
            if "follows" in child
        ],
        "nested repository": [
            f"{n}.{c}"
            for n, e in inputs.items()
            for c, child in e.get("inputs", {}).items()
            if "repo" in child
        ],
    }
    for label, members in classes.items():
        if not members:
            errors.append(f"no {label} input is declared; the comparison would pass vacuously")

    if sorted(inputs) != sorted(root):
        missing = sorted(set(inputs) - set(root))
        extra = sorted(set(root) - set(inputs))
        if missing:
            errors.append(f"flake.lock has no root input for: {', '.join(missing)}")
        if extra:
            errors.append(f"registry does not declare root inputs: {', '.join(extra)}")

    for name, entry in inputs.items():
        if "follows" in entry:
            edge = root.get(name)
            if normalize_edge(edge) != entry["follows"].split("/"):
                errors.append(f"{name}: flake.lock follows {edge!r}, registry expects {entry['follows']!r}")
            continue
        node_name = root.get(name)
        if not isinstance(node_name, str):
            continue
        check_entry(inputs, lock, name, entry, node_name, True, errors)

    nodes = lock.get("nodes", {})
    brew_node = nodes.get("nix-homebrew", {}).get("inputs", {}).get("brew-src")
    if brew_node is None:
        errors.append("nix-homebrew has no brew-src input edge")
    else:
        ref = nodes.get(brew_node, {}).get("original", {}).get("ref")
        if ref != "main":
            errors.append(f"brew-src tracks {ref!r} instead of 'main'")

    for name, want in expectations.get("pins", {}).items():
        entry = inputs.get(name)
        if entry is None:
            errors.append(f"pin for {name} has no registry entry")
            continue
        recorded = entry.get("ref", entry.get("rev"))
        if want.get("ref") is not None and recorded != want["ref"]:
            errors.append(f"{name}: registry points at {recorded!r}, the pin expects {want['ref']!r}")
        if "rev" in entry and want.get("rev") is not None and entry["rev"] != want["rev"]:
            errors.append(f"{name}: registry records rev {entry['rev']!r}, the pin expects {want['rev']!r}")

    if errors:
        for error in errors:
            print(f"flake-input-consistency: {error}", file=sys.stderr)
        return 1
    print("flake-input-consistency: registry, flake.lock, and pins agree")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
