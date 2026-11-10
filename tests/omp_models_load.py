"""Check managed API selection and metadata loaded by the pinned runtime."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


def environment(home):
    return {"HOME": str(home), "PATH": os.environ["PATH"],
            "SYNTHETIC_API_KEY": "sk-fake-synthetic",
            "OPENROUTER_API_KEY": "sk-fake-openrouter"}

EFFORTS = ("minimal", "low", "medium", "high", "xhigh", "max")


def expected_name(provider, row):
    if provider == "synthetic":
        name = row["display_name"]
        if row["id"].startswith("infinite:") and not name.endswith(" (infinite)"):
            return name + " (infinite)"
        return name
    return row["name"].removeprefix("OpenRouter: ")



def run(omp, documents, snapshots):
    providers = json.loads(Path(documents["models.yml"]).read_text())["providers"]
    assert set(providers) == {"synthetic", "openrouter"}, "unexpected providers in models.yml"
    selected_ids = {row["id"] for row in json.loads(Path(snapshots["openrouter"]).read_text())["data"]
                    if row["id"].startswith("openrouter/") and row["id"] != "openrouter/bodybuilder"}
    managed = providers["openrouter"]
    assert ({row["id"] for row in managed["models"]} | managed["modelOverrides"].keys()) == selected_ids, "managed OpenRouter selection"
    for metadata in [*managed["models"], *managed["modelOverrides"].values()]:
        assert "cost" not in metadata, "OpenRouter must use runtime pricing rather than snapshot overrides"
        assert "maxTokens" not in metadata, "OpenRouter must not retain provider output limits"
        assert "omitMaxOutputTokens" not in metadata, "explicit caller output caps must remain effective"
    with tempfile.TemporaryDirectory() as temporary:
        home = Path(temporary)
        agent = home / ".omp/agent"
        agent.mkdir(parents=True)
        for name in ("models.yml", "config.yml"):
            (agent / name).write_bytes(Path(documents[name]).read_bytes())
        result = subprocess.run([omp, "models", "--json"], cwd=home,
                                env=environment(home), capture_output=True, text=True, timeout=60)
        assert result.returncode == 0, result.stderr
        assert not result.stderr.strip(), result.stderr
        listed = {row["selector"]: row for row in json.loads(result.stdout)["models"]}
        for provider, path in snapshots.items():
            rows = json.loads(Path(path).read_text())["data"]
            if provider == "openrouter":
                rows = [row for row in rows if row["id"] in selected_ids]
            assert rows, f"empty {provider} snapshot"
            missing = {f"{provider}/{row['id']}" for row in rows} - listed.keys()
            assert not missing, f"snapshot selectors missing: {sorted(missing)}"
            for row in rows:
                actual = listed[f"{provider}/{row['id']}"]
                assert actual["name"] == expected_name(provider, row), (row["id"], actual["name"])
                modalities = row.get("input_modalities", (row.get("architecture") or {}).get("input_modalities", []))
                assert actual["input"] == [m for m in ("text", "image") if m in modalities], row["id"]
                context = row.get("context_length")
                if isinstance(context, int) and context > 0:
                    assert actual["contextWindow"] == context, row["id"]
                limit = row.get("max_output_length") if provider == "synthetic" else None
                if isinstance(limit, int) and limit > 0:
                    assert actual["maxTokens"] == limit, row["id"]
                reasoning = row.get("reasoning_parameters" if provider == "synthetic" else "reasoning")
                if reasoning:
                    efforts = reasoning.get("efforts" if provider == "synthetic" else "supported_efforts")
                    if efforts:
                        expected = [e for e in EFFORTS if e in efforts]
                        assert actual["thinking"] == expected, row["id"]
        glm = listed["synthetic/hf:zai-org/GLM-5.3"]
        assert glm["thinking"] == ["low", "high", "max"], glm
        # Every managed role runs a Synthetic model at an effort its loaded ladder offers.
        config = json.loads(Path(documents["config.yml"]).read_text())
        roles = [*(("modelRoles", k, v) for k, v in config["modelRoles"].items() if k != "web"),
                 *(("agentModelOverrides", k, v) for k, v in config["task"]["agentModelOverrides"].items())]
        for *role, value in roles:
            head, _, suffix = value.rpartition(":")
            selector, effort = (head, suffix) if suffix in EFFORTS else (value, config["defaultThinkingLevel"])
            assert selector.startswith("synthetic/") and selector in listed, (role, value)
            assert effort in listed[selector]["thinking"], (role, value, listed[selector]["thinking"])
        print("OMP loaded selected API metadata")


if __name__ == "__main__":
    omp, manifest, synthetic, openrouter, helpers, catalog_module, declarations_script = sys.argv[1:]
    with tempfile.TemporaryDirectory() as temporary:
        fixture = Path(temporary)
        (fixture / "catalog.nix").write_bytes(Path(catalog_module).read_bytes())
        (fixture / "synthetic-catalog.json").write_text(json.dumps({
            "data": [{"id": "unchanged-synthetic"}]}))
        (fixture / "openrouter-catalog.json").write_text(json.dumps({"data": [
            {"id": model} for model in (
                "openrouter/future-model", "other/model", "other/openrouter/model",
                "openrouter/bodybuilder", "openrouter/bodybuilder-new")]}))
        result = subprocess.run([
            "nix-instantiate", "--eval", "--strict", "--json", "--store", "dummy://",
            str(fixture / "catalog.nix")], capture_output=True, text=True, timeout=60)
        assert result.returncode == 0, result.stderr
        selected = json.loads(result.stdout)
    assert selected["synthetic"]["data"] == [{"id": "unchanged-synthetic"}]
    assert [row["id"] for row in selected["openrouter"]["data"]] == [
        "openrouter/future-model", "openrouter/bodybuilder-new"], "raw-ID regex and exact exclusion"
    assert selected["patterns"] == [
        "synthetic/unchanged-synthetic",
        "openrouter/openrouter/future-model",
        "openrouter/openrouter/bodybuilder-new",
    ], selected.get("patterns")
    with tempfile.TemporaryDirectory() as temporary:
        fixture = Path(temporary)
        bundled = subprocess.run([omp, "models", "--json"], cwd=fixture,
                                 env={**environment(fixture), "HTTP_PROXY": "http://127.0.0.1:1",
                                      "HTTPS_PROXY": "http://127.0.0.1:1", "ALL_PROXY": "http://127.0.0.1:1",
                                      "NO_PROXY": ""},
                                 capture_output=True, text=True, timeout=60)
        assert bundled.returncode == 0, bundled.stderr
        (fixture / "bundled.json").write_text(bundled.stdout)
        (fixture / "synthetic.json").write_text(json.dumps({"data": [
            {"id": "infinite:small:vision", "display_name": "Shared Flash"},
            {"id": "infinite:large:text", "display_name": "Already Tagged (infinite)"},
            {"id": "hf:org/Model", "display_name": "Shared Flash"},
            {"id": "syn:small:text", "display_name": "syn:small:text"},
        ]}))
        (fixture / "openrouter.json").write_text(json.dumps({"data": [
            {"id": "infinite:foreign", "name": "Foreign Infinite"},
            {"id": "openrouter/free", "name": "Free", "context_length": 200000},
            {"id": "openrouter/free-beta", "name": "Free Beta", "context_length": 200000},
        ]}))
        rendered_path = fixture / "models.yml"
        rendered_run = subprocess.run([
            sys.executable, "-I", declarations_script,
            str(fixture / "synthetic.json"), str(fixture / "openrouter.json"),
            str(fixture / "bundled.json"), "/bin/false", "/bin/false", str(rendered_path),
        ], capture_output=True, text=True, timeout=60)
        assert rendered_run.returncode == 0, rendered_run.stderr
        agent = fixture / ".omp/agent"
        agent.mkdir(parents=True, exist_ok=True)
        (agent / "models.yml").write_bytes(rendered_path.read_bytes())
        loaded = subprocess.run([omp, "models", "--json"], cwd=fixture,
                                env=environment(fixture), capture_output=True, text=True, timeout=60)
        assert loaded.returncode == 0, loaded.stderr
        models = {row["selector"]: row for row in json.loads(loaded.stdout)["models"]}
        names = {selector: row["name"] for selector, row in models.items()}
    assert names["synthetic/infinite:small:vision"] == "Shared Flash (infinite)", names
    assert names["synthetic/infinite:large:text"] == "Already Tagged (infinite)", names
    assert names["synthetic/hf:org/Model"] == "Shared Flash", names
    assert names["synthetic/syn:small:text"] == "syn:small:text", names
    assert names["openrouter/infinite:foreign"] == "Foreign Infinite", names
    unknown = models["openrouter/infinite:foreign"]
    assert unknown["pricingStatus"] == "unknown", "missing price must not declare a new route free"
    for selector in ("openrouter/openrouter/free", "openrouter/openrouter/free-beta"):
        free = models[selector]
        assert free["cost"]["input"] == free["cost"]["output"] == 0, selector
        assert free["contextWindow"] == 200000, selector
    for helper, env, expected in (
        ("omp-synthetic-key", {}, "sk-fake-file"),
        ("omp-synthetic-key", {"SYNTHETIC_API_KEY": "sk-fake-override"}, "sk-fake-override"),
        ("omp-openrouter-key", {}, None),
        ("omp-synthetic-key", {"SYNTHETIC_API_KEY": "invalid fake credential"}, None),
    ):
        result = subprocess.run([str(Path(helpers) / helper)], env=env, capture_output=True, text=True)
        assert (result.returncode == 0) == (expected is not None), "provider helper status"
        assert result.stdout == (expected or ""), "provider helper output"
        assert "fake" not in result.stderr, "provider helper leaked a credential"
    for documents in json.loads(Path(manifest).read_text()):
        run(omp, documents, {"synthetic": synthetic, "openrouter": openrouter})
