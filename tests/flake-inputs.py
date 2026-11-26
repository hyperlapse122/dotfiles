"""Exercise the flake-inputs generator's rendering, drift, and schema rules."""

import json
from pathlib import Path
import subprocess
import sys
import tempfile

GENERATOR = sys.argv[1]
CONSISTENCY = sys.argv[2] if len(sys.argv) > 2 else None
COMMIT = "a" * 40

REGISTRY = {
    "version": 1,
    "inputs": {
        "nixpkgs": {"repo": "github:NixOS/nixpkgs", "ref": "nixos-unstable"},
        "locked": {"repo": "github:o/r", "rev": COMMIT, "flake": False},
        "bare": {"repo": "github:o/bare"},
        "home-manager": {
            "repo": "github:o/hm",
            "inputs": {"nixpkgs": {"follows": "nixpkgs"}},
        },
        "nix-homebrew": {
            "repo": "github:o/hb",
            "note": ["line one", "line two"],
            "inputs": {
                "brew-src": {"repo": "github:Homebrew/brew", "ref": "main", "flake": False}
            },
        },
    },
}

EXPECTED_SPAN = """  inputs = {
    nixpkgs = {
      url = "github:NixOS/nixpkgs/nixos-unstable";
    };
    locked = {
      url = "github:o/r/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
      flake = false;
    };
    bare = {
      url = "github:o/bare";
    };
    home-manager = {
      url = "github:o/hm";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nix-homebrew = {
      # line one
      # line two
      url = "github:o/hb";
      inputs.brew-src.url = "github:Homebrew/brew/main";
      inputs.brew-src.flake = false;
    };
  };
"""

FLAKE = """{
  description = "test";
  # BEGIN flake-inputs (generated from flake-inputs.json; do not edit)
  # END flake-inputs
  outputs = { self }: { };
}
"""

failures = []


def check(name, condition, detail=""):
    if condition:
        print(f"ok - {name}")
    else:
        print(f"FAIL - {name}" + (f": {detail}" if detail else ""), file=sys.stderr)
        failures.append(name)


def invoke(directory, *args):
    return subprocess.run(
        [GENERATOR, *args], cwd=directory, capture_output=True, text=True
    )


def workspace(registry=REGISTRY, flake=FLAKE):
    directory = Path(tempfile.mkdtemp(prefix="flake-inputs-test-"))
    (directory / "flake-inputs.json").write_text(json.dumps(registry, indent=2) + "\n")
    (directory / "flake.nix").write_text(flake)
    return directory


def write_registry(directory, registry):
    (directory / "flake-inputs.json").write_text(json.dumps(registry, indent=2) + "\n")


def read_span(directory):
    text = (directory / "flake.nix").read_text()
    begin = text.index("# BEGIN flake-inputs")
    end = text.index("  # END flake-inputs")
    return text[text.index("\n", begin) + 1 : end]


def test_rendering():
    directory = workspace()
    result = invoke(directory, "generate", "--write")
    check("generate --write succeeds", result.returncode == 0, result.stderr)
    check("renders the expected span", read_span(directory) == EXPECTED_SPAN, read_span(directory))
    check("preserves text outside the span", (directory / "flake.nix").read_text().endswith("}\n"))
    first = (directory / "flake.nix").read_text()
    result = invoke(directory, "generate", "--write")
    check("second write is a no-op", result.returncode == 0 and (directory / "flake.nix").read_text() == first)
    result = invoke(directory, "generate", "--check")
    check("check accepts a fresh span", result.returncode == 0, result.stderr)


def test_stale_and_markers():
    directory = workspace()
    invoke(directory, "generate", "--write")
    registry = json.loads(json.dumps(REGISTRY))
    registry["inputs"]["nixpkgs"]["ref"] = "nixos-24.11"
    write_registry(directory, registry)
    result = invoke(directory, "generate", "--check")
    check("check rejects a stale span", result.returncode == 1 and "stale" in result.stderr, result.stderr)

    directory = workspace(flake='{\n  description = "test";\n}\n')
    result = invoke(directory, "generate", "--check")
    check("missing markers fail", result.returncode == 1 and "exactly one" in result.stderr, result.stderr)

    doubled = FLAKE.replace(
        "  # END flake-inputs",
        "  # BEGIN flake-inputs (generated from flake-inputs.json; do not edit)\n  # END flake-inputs",
    )
    directory = workspace(flake=doubled)
    result = invoke(directory, "generate", "--check")
    check("duplicate markers fail", result.returncode == 1, result.stderr)

    reversed_markers = (
        '{\n  # END flake-inputs\n  # BEGIN flake-inputs (generated from flake-inputs.json; do not edit)\n}\n'
    )
    directory = workspace(flake=reversed_markers)
    result = invoke(directory, "generate", "--check")
    check("reversed markers fail", result.returncode == 1 and "before" in result.stderr, result.stderr)


def test_external_literal():
    flake = FLAKE.replace(
        '  outputs = { self }: { };',
        '  outputs = { self }: { url = "github:leak/leak"; };',
    )
    directory = workspace(flake=flake)
    invoke(directory, "generate", "--write")
    result = invoke(directory, "generate", "--check")
    check(
        "an external literal outside the span fails",
        result.returncode == 1 and "outside the generated span" in result.stderr,
        result.stderr,
    )
    directory = workspace(flake=FLAKE.replace('  outputs', '  # https://example.org is a comment\n  outputs'))
    invoke(directory, "generate", "--write")
    result = invoke(directory, "generate", "--check")
    check("a comment outside the span is allowed", result.returncode == 0, result.stderr)


def test_set():
    directory = workspace()
    invoke(directory, "generate", "--write")
    before = json.loads((directory / "flake-inputs.json").read_text())
    result = invoke(directory, "set", "nixpkgs", "--ref", "nixos-24.11")
    after = json.loads((directory / "flake-inputs.json").read_text())
    check("set --ref succeeds", result.returncode == 0, result.stderr)
    check("set --ref changes only the named entry", after["inputs"]["nixpkgs"] == {"repo": "github:NixOS/nixpkgs", "ref": "nixos-24.11"})
    untouched = {name: entry for name, entry in before["inputs"].items() if name != "nixpkgs"}
    check(
        "set --ref leaves every other entry alone",
        untouched == {name: entry for name, entry in after["inputs"].items() if name != "nixpkgs"},
    )
    check("set --ref keeps the registry readable", after["version"] == 1 and list(after["inputs"]) == list(before["inputs"]))

    result = invoke(directory, "set", "locked", "--ref", "v2.0.0")
    after = json.loads((directory / "flake-inputs.json").read_text())
    check(
        "set --ref replaces a rev",
        result.returncode == 0 and after["inputs"]["locked"] == {"repo": "github:o/r", "flake": False, "ref": "v2.0.0"},
        result.stderr,
    )

    aliased = json.loads(json.dumps(REGISTRY))
    aliased["inputs"]["alias"] = {"follows": "nixpkgs"}
    directory = workspace(registry=aliased)
    result = invoke(directory, "set", "alias", "--ref", "v9")
    check("set refuses a follows entry", result.returncode == 1, result.stderr)
    result = invoke(directory, "set", "missing", "--ref", "v9")
    check("set refuses an unknown name", result.returncode == 1, result.stderr)


def test_schema_rejections():
    cases = {
        "unknown key": lambda r: r["inputs"]["bare"].update({"colour": "red"}),
        "ref and rev": lambda r: r["inputs"]["bare"].update({"ref": "v1", "rev": COMMIT}),
        "empty ref": lambda r: r["inputs"]["bare"].update({"ref": "  "}),
        "non-boolean flake": lambda r: r["inputs"]["bare"].update({"flake": "false"}),
        "repo and follows": lambda r: r["inputs"]["bare"].update({"follows": "nixpkgs"}),
        "bad follows path": lambda r: r["inputs"]["home-manager"]["inputs"].update(
            {"nixpkgs": {"follows": "/nixpkgs"}}
        ),
        "unsupported repo type": lambda r: r["inputs"]["bare"].update({"repo": "https://example.org/x"}),
        "repo with a ref segment": lambda r: r["inputs"]["bare"].update({"repo": "github:o/r/v1"}),
        "short rev": lambda r: r["inputs"]["locked"].update({"rev": "abc"}),
        "empty inputs map": lambda r: r["inputs"]["home-manager"].update({"inputs": {}}),
        "note with a newline": lambda r: r["inputs"]["bare"].update({"note": ["a\nb"]}),
        "missing repo and follows": lambda r: r["inputs"]["bare"].pop("repo"),
    }
    for name, mutate in cases.items():
        registry = json.loads(json.dumps(REGISTRY))
        mutate(registry)
        directory = workspace(registry=registry)
        result = invoke(directory, "generate", "--check")
        check(f"rejects {name}", result.returncode == 1 and "flake-inputs:" in result.stderr, result.stderr)

    directory = workspace()
    (directory / "flake-inputs.json").write_text(
        '{"version": 1, "inputs": {"a": {"repo": "github:o/a"}, "a": {"repo": "github:o/b"}}}'
    )
    result = invoke(directory, "generate", "--check")
    check("rejects duplicate keys", result.returncode == 1 and "duplicate key" in result.stderr, result.stderr)

    directory = workspace()
    write_registry(directory, {"version": 2, "inputs": REGISTRY["inputs"]})
    result = invoke(directory, "generate", "--check")
    check("rejects an unknown version", result.returncode == 1, result.stderr)

    directory = workspace()
    write_registry(directory, {"version": 1, "inputs": {}})
    result = invoke(directory, "generate", "--check")
    check("rejects an empty registry", result.returncode == 1, result.stderr)


LOCK = {
    "nodes": {
        "root": {
            "inputs": {
                "nixpkgs": "nixpkgs",
                "locked": "locked",
                "bare": "bare",
                "home-manager": "home-manager",
                "nix-homebrew": "nix-homebrew",
            }
        },
        "nixpkgs": {
            "locked": {"rev": "c" * 40},
            "original": {"type": "github", "owner": "NixOS", "repo": "nixpkgs", "ref": "nixos-unstable"},
        },
        "locked": {
            "flake": False,
            "locked": {"rev": COMMIT},
            "original": {"type": "github", "owner": "o", "repo": "r", "rev": COMMIT},
        },
        "bare": {
            "locked": {"rev": "d" * 40},
            "original": {"type": "github", "owner": "o", "repo": "bare"},
        },
        "home-manager": {
            "locked": {"rev": "e" * 40},
            "original": {"type": "github", "owner": "o", "repo": "hm"},
            "inputs": {"nixpkgs": ["nixpkgs"]},
        },
        "nix-homebrew": {
            "locked": {"rev": "f" * 40},
            "original": {"type": "github", "owner": "o", "repo": "hb"},
            "inputs": {"brew-src": "brew-src"},
        },
        "brew-src": {
            "flake": False,
            "locked": {"rev": "a" * 40},
            "original": {"type": "github", "owner": "Homebrew", "repo": "brew", "ref": "main"},
        },
    }
}

EXPECTATIONS = {"pins": {"nixpkgs": {"ref": "nixos-unstable"}}}


def consistency_workspace():
    directory = Path(tempfile.mkdtemp(prefix="flake-inputs-consistency-"))
    (directory / "flake-inputs.json").write_text(json.dumps(REGISTRY, indent=2) + "\n")
    (directory / "flake.lock").write_text(json.dumps(LOCK, indent=2) + "\n")
    (directory / "expectations.json").write_text(json.dumps(EXPECTATIONS, indent=2) + "\n")
    return directory


def run_consistency(directory):
    return subprocess.run(
        [sys.executable, CONSISTENCY, "flake-inputs.json", "flake.lock", "expectations.json"],
        cwd=directory,
        capture_output=True,
        text=True,
    )


def test_consistency():
    directory = consistency_workspace()
    result = run_consistency(directory)
    check("a converged registry, lock, and pin agree", result.returncode == 0, result.stderr)

    def mutation(name, *, registry=None, lock=None, expectations=None):
        directory = consistency_workspace()
        if registry is not None:
            (directory / "flake-inputs.json").write_text(json.dumps(registry, indent=2) + "\n")
        if lock is not None:
            (directory / "flake.lock").write_text(json.dumps(lock, indent=2) + "\n")
        if expectations is not None:
            (directory / "expectations.json").write_text(json.dumps(expectations, indent=2) + "\n")
        result = run_consistency(directory)
        check(
            name,
            result.returncode == 1 and "flake-input-consistency:" in result.stderr,
            result.stderr,
        )

    registry = json.loads(json.dumps(REGISTRY))
    registry["inputs"]["nixpkgs"]["ref"] = "nixos-24.11"
    mutation("a registry ref drift is caught", registry=registry)

    lock = json.loads(json.dumps(LOCK))
    lock["nodes"]["locked"]["original"]["rev"] = "b" * 40
    mutation("a registry rev drift is caught", lock=lock)

    lock = json.loads(json.dumps(LOCK))
    lock["nodes"]["bare"]["flake"] = False
    mutation("a flake flag drift is caught", lock=lock)

    lock = json.loads(json.dumps(LOCK))
    lock["nodes"]["root"]["inputs"].pop("nixpkgs")
    mutation("a missing root input is caught", lock=lock)

    lock = json.loads(json.dumps(LOCK))
    lock["nodes"]["root"]["inputs"]["extra"] = "extra"
    mutation("an undeclared root input is caught", lock=lock)

    lock = json.loads(json.dumps(LOCK))
    lock["nodes"]["nix-homebrew"]["inputs"].pop("brew-src")
    mutation("a missing nested edge is caught", lock=lock)

    lock = json.loads(json.dumps(LOCK))
    lock["nodes"]["home-manager"]["inputs"]["nixpkgs"] = ["omp", "nixpkgs"]
    mutation("a follows mismatch is caught", lock=lock)

    lock = json.loads(json.dumps(LOCK))
    lock["nodes"]["brew-src"]["original"]["ref"] = "master"
    mutation("brew-src leaving main is caught", lock=lock)

    mutation(
        "a pin ref mismatch is caught",
        expectations={"pins": {"nixpkgs": {"ref": "v9.9.9"}}},
    )
    mutation(
        "a pin without a registry entry is caught",
        expectations={"pins": {"orphan": {"ref": "v1"}}},
    )
    mutation(
        "a registry rev that disagrees with a pin is caught",
        expectations={"pins": {"locked": {"ref": COMMIT, "rev": "b" * 40}}},
    )

    registry = json.loads(json.dumps(REGISTRY))
    registry["inputs"]["home-manager"]["inputs"] = {
        "nixpkgs": {"repo": "github:NixOS/nixpkgs", "ref": "nixos-unstable"}
    }
    lock = json.loads(json.dumps(LOCK))
    lock["nodes"]["home-manager"]["inputs"]["nixpkgs"] = "nixpkgs"
    mutation("an empty follows class is caught", registry=registry, lock=lock)


def main():
    if not Path(GENERATOR).exists():
        print(f"generator not found: {GENERATOR}", file=sys.stderr)
        return 2
    if CONSISTENCY is None or not Path(CONSISTENCY).exists():
        print(f"consistency script not found: {CONSISTENCY}", file=sys.stderr)
        return 2
    test_rendering()
    test_stale_and_markers()
    test_external_literal()
    test_set()
    test_schema_rejections()
    test_consistency()
    if failures:
        print(f"{len(failures)} case(s) failed", file=sys.stderr)
        return 1
    print("all flake-inputs cases passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
