"""Check the Android SDK pin against the repo.json nixpkgs ships.

Usage: android-sdk-repo-parity.py PIN NIXPKGS_REPO_JSON

android-sdk-release converts Google's repository XML with functions vendored
from nixpkgs' androidenv update.rb. Every package the pin carries that
nixpkgs' own repo.json also carries must therefore be identical to it, apart
from the last-available-day stamp update.rb adds to expire old records. A
difference means the vendored conversion drifted from upstream, or one of the
two files was written from a different upstream archive.

The same holds for the pinned system images, which both files key
api -> tag -> abi. A package or image the pin carries but nixpkgs does not
yet list is skipped, since the pin can track a release before nixpkgs picks
it up. An image key carries no revision, so a newer image revision than
nixpkgs lists counts as not listed yet; an older one fails, since the pin
then lags the nixpkgs it builds against. When nixpkgs updates an entry whose
key carries no revision (system images and platforms) in place with
merge_recursively, XML children whose position shifted across revisions stay
beside the new children under their old :index keys, leaving duplicate child
indices in type-details or dependencies; those stale keys are ignored only
when every pinned child matches and nixpkgs' dict itself shows that index
collision. The declared build-tools and platforms stay in nixpkgs' repo.json
for years, so at least one package must be comparable; none would leave the
check asserting nothing.
"""

import json
import sys


def entries(repo):
    """Yield (label, key path, entry) for every package and system image."""
    for name, versions in sorted(repo.get("packages", {}).items()):
        for version, entry in sorted(versions.items()):
            yield f"{name} {version}", ("packages", name, version), entry
    for api, tags in sorted(repo.get("images", {}).items()):
        for tag, abis in sorted(tags.items()):
            for abi, entry in sorted(abis.items()):
                yield f"system-image {api} {tag} {abi}", ("images", api, tag, abi), entry


def lookup(repo, path):
    for key in path:
        repo = repo.get(key) if isinstance(repo, dict) else None
        if repo is None:
            return None
    return repo


def revision(entry):
    details = entry.get("revision-details")
    if not isinstance(details, dict) or not details:
        return None
    try:
        ordered = sorted(details.items(), key=lambda item: int(item[0].rsplit(":", 1)[1]))
        return tuple(name for name, _ in ordered), tuple(int(value) for _, value in ordered)
    except (IndexError, TypeError, ValueError):
        return None


def ordered_revisions(entry, theirs):
    """Both revisions when they order one against the other, else None.

    Two revisions order only when both carry the same revision-details
    fields; otherwise (6, 0) would read as newer than (6,), and a field the
    conversion gained or lost would skip as a release instead of failing as
    drift in the field-by-field comparison.
    """
    ours, upstream = revision(entry), revision(theirs)
    if ours is None or upstream is None or ours[0] != upstream[0]:
        return None
    return ours[1], upstream[1]


def show(numbers):
    return ".".join(map(str, numbers))


def indexed_children(doc):
    """Return ({key: index}, {index: [key, ...]}) for a to_json_collector dict, or None."""
    key_index = {}
    by_index = {}
    for key in doc:
        if key == "element-attributes":
            continue
        name, sep, raw_index = key.rpartition(":")
        if sep != ":" or not name or not raw_index.isascii() or not raw_index.isdigit():
            return None
        index = int(raw_index)
        if str(index) != raw_index:
            return None
        key_index[key] = index
        by_index.setdefault(index, []).append(key)
    return key_index, by_index


def collector_matches(ours, theirs):
    """True when ours matches theirs, ignoring stale merge_recursively children in theirs."""
    if ours == theirs:
        return True
    if not isinstance(ours, dict) or not isinstance(theirs, dict):
        return False
    if ("element-attributes" in ours) != ("element-attributes" in theirs):
        return False
    if ours.get("element-attributes") != theirs.get("element-attributes"):
        return False

    ours_indexed = indexed_children(ours)
    theirs_indexed = indexed_children(theirs)
    if ours_indexed is None or theirs_indexed is None:
        return False
    ours_keys, ours_by_index = ours_indexed
    theirs_keys, theirs_by_index = theirs_indexed

    count = len(ours_keys)
    if count == 0 or set(ours_by_index) != set(range(count)):
        return False
    if set(theirs_by_index) != set(range(len(theirs_by_index))):
        return False
    for key in ours_keys:
        if key not in theirs or not collector_matches(ours[key], theirs[key]):
            return False

    if not (theirs_keys.keys() - ours_keys.keys()):
        return True
    dup_indices = [idx for idx, keys in theirs_by_index.items() if len(keys) > 1]
    return bool(dup_indices) and min(dup_indices) < count


def field_matches(path, key, ours, theirs):
    if ours == theirs:
        return True
    unversioned_key = path[0] == "images" or path[:2] == ("packages", "platforms")
    if unversioned_key and key in ("type-details", "dependencies"):
        return collector_matches(ours, theirs)
    return False


def main(pin_path, upstream_path):
    with open(pin_path, encoding="utf-8") as f:
        pin = json.load(f)
    with open(upstream_path, encoding="utf-8") as f:
        upstream = json.load(f)

    compared = []
    failures = []
    for label, path, entry in entries(pin):
        theirs = lookup(upstream, path)
        if theirs is None:
            print(f"skip {label}: not in nixpkgs repo.json")
            continue
        revisions = ordered_revisions(entry, theirs)
        ours_revision, their_revision = revisions or (None, None)
        if revisions and ours_revision > their_revision:
            print(
                f"skip {label}: revision {show(ours_revision)} not in nixpkgs repo.json"
                f" (it has {show(their_revision)})"
            )
            continue
        if revisions and ours_revision < their_revision:
            failures.append(
                f"{label} revision {show(ours_revision)} is older than nixpkgs' {show(their_revision)}"
            )
            continue
        theirs = {k: v for k, v in theirs.items() if k != "last-available-day"}
        compared.append(label)
        keys = sorted(
            k
            for k in entry.keys() | theirs.keys()
            if not field_matches(path, k, entry.get(k), theirs.get(k))
        )
        if keys:
            failures.append(f"{label} differs in {', '.join(keys)}")

    if not compared:
        failures.append("no pinned package is in nixpkgs repo.json to compare")
    for failure in failures:
        print(f"android-sdk-repo-parity: {failure}", file=sys.stderr)
    if failures:
        return 1
    print(f"matches nixpkgs repo.json: {', '.join(compared)}")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    sys.exit(main(sys.argv[1], sys.argv[2]))
