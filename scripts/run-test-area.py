"""Validate complete unittest ownership, then run one whole-module area.

The full tests directory stays importable for sibling fixture imports.
Use --validate-only or --list to inspect coverage without executing tests.
"""

import argparse
from collections import Counter
import json
from pathlib import Path
import sys
import time
import unittest


REPO = Path(__file__).resolve().parents[1]
AREAS = {
    "applications": (
        "test_personal_apps", "test_personal_app_lock", "test_harness_plugins",
        "test_harness_plugin_lock", "test_t3_code_desktop", "test_t3_code_settings",
        "test_codex", "test_claude",
        "test_font_lock", "test_fonts", "test_fonts_posix", "test_fonts_windows",
        "test_native_ca_shell", "test_native_ca_windows", "test_powershell_profile",
    ),
    "security": (
        "test_pinentry_apply",
        "test_secrets", "test_git_gpg", "test_script_lifecycle", "test_github_auth",
        "test_github_auth_import", "test_gitlab_auth", "test_gitlab_auth_import",
    ),
    "platform": (
        "test_bootstrap", "test_global_chezmoi", "test_windows_bootstrap",
        "test_windows_apply_hook", "test_windows_apps", "test_windows_virtualization",
        "test_macos_bootstrap", "test_macos_provision", "test_macos_apps", "test_macos_readiness",
        "test_ghostty_install", "test_terminal_environment",
    ),
    "build-contracts": (
        "test_windows_build_apply", "test_windows_build_environment", "test_windows_build_prepare",
        "test_windows_build_smoke", "test_windows_visual_studio", "test_ci_areas",
        "test_ci_event_policy",
        "test_macos_build_environment",
    ),
}


def cases(suite):
    for item in suite:
        if isinstance(item, unittest.TestSuite):
            yield from cases(item)
        else:
            yield item


def partition(baseline, assignments, modules):
    owners = {}
    for area, names in assignments.items():
        for name in names:
            if name in owners:
                raise ValueError(f"multiple assignments for {name}: {owners[name]}, {area}")
            owners[name] = area
    if missing := modules - owners.keys():
        raise ValueError(f"unassigned test modules: {', '.join(sorted(missing))}")
    if removed := owners.keys() - modules:
        raise ValueError(f"missing test modules: {', '.join(sorted(removed))}")
    selected = {area: unittest.TestSuite() for area in assignments}
    ids = set()
    for case in cases(baseline):
        module = type(case).__module__
        if module == "unittest.loader":
            raise ValueError(f"discovery failed: {case.id()}")
        if case.id() in ids:
            raise ValueError(f"duplicate test ID: {case.id()}")
        ids.add(case.id())
        if module not in owners:
            raise ValueError(f"unassigned test module: {module}")
        selected[owners[module]].addTest(case)
    return selected


def discover():
    test_root = REPO / "tests"
    sys.path.insert(0, str(test_root))
    loader = unittest.TestLoader()
    baseline = loader.discover(str(test_root))
    if loader.errors:
        raise ValueError("discovery failed:\n" + "\n".join(loader.errors))
    modules = {path.stem for path in test_root.glob("test_*.py")}
    selected = partition(baseline, AREAS, modules)
    baseline_ids = Counter(case.id() for case in cases(baseline))
    independent = unittest.TestLoader()
    selected_ids = Counter(case.id() for names in AREAS.values()
                           for case in cases(independent.loadTestsFromNames(names)))
    if independent.errors:
        raise ValueError("area loading failed:\n" + "\n".join(independent.errors))
    if selected_ids != baseline_ids:
        raise ValueError(f"area IDs differ from discovery: missing={baseline_ids - selected_ids}, extra={selected_ids - baseline_ids}")
    return selected


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--area", choices=["all", *AREAS], default="all")
    parser.add_argument("--validate-only", action="store_true")
    parser.add_argument("--list", action="store_true", help="Print selected test IDs as JSON without running tests")
    parser.add_argument("--report", type=Path, help="Write test IDs, skips and elapsed seconds as JSON")
    args = parser.parse_args()
    try:
        selected = discover()
    except ValueError as error:
        parser.exit(1, f"Test ownership validation failed: {error}\n")
    areas = list(AREAS) if args.area == "all" else [args.area]
    manifest = {area: [case.id() for case in cases(selected[area])] for area in areas}
    if args.list:
        print(json.dumps(manifest, indent=2))
        return 0
    print(f"Validated {sum(suite.countTestCases() for suite in selected.values())} test IDs across {len(AREAS)} areas", flush=True)
    if args.validate_only:
        return 0
    results = []
    success = True
    for area in areas:
        print(f"Running area: {area}", flush=True)
        started = time.monotonic()
        result = unittest.TextTestRunner(verbosity=2).run(selected[area])
        row = {"area": area, "seconds": round(time.monotonic() - started, 3),
               "selected_ids": manifest[area], "tests_run": result.testsRun,
               "skipped": [{"id": case.id(), "reason": reason} for case, reason in result.skipped],
               "failures": [case.id() for case, _ in result.failures],
               "errors": [case.id() for case, _ in result.errors]}
        results.append(row)
        success &= result.wasSuccessful()
        print(f"Area {area}: {row['seconds']:.3f}s, {result.testsRun} tests, {len(result.skipped)} skipped", flush=True)
    if args.report:
        args.report.write_text(json.dumps(results, indent=2) + "\n", encoding="utf-8")
    return 0 if success else 1


if __name__ == "__main__":
    raise SystemExit(main())
