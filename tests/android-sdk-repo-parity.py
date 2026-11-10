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
then lags the nixpkgs it builds against. The declared build-tools
and platforms stay in nixpkgs' repo.json for years, so at least one package
must be comparable; none would leave the check asserting nothing.
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
        if entry != theirs:
            keys = sorted(
                k
                for k in entry.keys() | theirs.keys()
                if entry.get(k) != theirs.get(k)
            )
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
