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


def check_follows(edge, target, where, child, errors):
    if normalize_edge(edge) != target.split("/"):
        errors.append(f"{where}: flake.lock follows {edge!r} for {child!r}, registry expects {target!r}")


def node_edge(edge, where, child, errors):
    """Return the lock node a repository edge points at, recording anything else."""
    if isinstance(edge, str):
        return edge
    if edge is None:
        errors.append(f"{where}: flake.lock has no edge for input {child!r}")
    else:
        errors.append(f"{where}: flake.lock resolves {child!r} by follows, registry declares a repository")
    return None


def check_entry(lock, where, entry, node_name, top, errors):
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
        if "follows" in child:
            check_follows(edge, child["follows"], where, child_name, errors)
            continue
        child_node = node_edge(edge, where, child_name, errors)
        if child_node is not None:
            check_entry(lock, f"{where}.inputs.{child_name}", child, child_node, False, errors)
    if top:
        declared = entry.get("inputs", {})
        for child_name, edge in node.get("inputs", {}).items():
            if isinstance(edge, list) and child_name not in declared:
                errors.append(
                    f"{where}: flake.lock follows {'/'.join(edge)} for {child_name!r}, "
                    "which the registry does not declare"
                )


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
        "follows": [n for n, e in inputs.items() if "follows" in e]
        + [
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
            check_follows(root.get(name), entry["follows"], name, name, errors)
            continue
        node_name = root.get(name)
        if not isinstance(node_name, str):
            if node_name is not None:
                errors.append(f"{name}: flake.lock resolves the root input by follows, registry declares a repository")
            continue
        check_entry(lock, name, entry, node_name, True, errors)

    if not expectations.get("pins"):
        errors.append("no pin expectation is declared; the comparison would pass vacuously")

    for name, want in expectations.get("pins", {}).items():
        entry = inputs.get(name)
        if entry is None:
            errors.append(f"pin for {name} has no registry entry")
            continue
        recorded = entry.get("ref", entry.get("rev"))
        if want.get("ref") is None and want.get("rev") is None:
            errors.append(f"pin for {name} records neither ref nor rev")
            continue
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
