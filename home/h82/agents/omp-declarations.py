"""Render OMP models.yml from the selected API catalog rows.

Bundled rows use overrides so OMP retains their transport and compatibility
rules. New rows use the providers' OpenAI-compatible chat transport. Codex
subscription discovery and metadata remain entirely owned by OMP.
"""

import decimal
import json
import sys


EFFORTS = ("minimal", "low", "medium", "high", "xhigh", "max")


def per_million(price):
    try:
        value = decimal.Decimal(str(price or "").lstrip("$"))
    except decimal.InvalidOperation:
        return 0
    return round(float(value * 1000000), 6) if value.is_finite() and value >= 0 else 0


def positive(value):
    return isinstance(value, int) and not isinstance(value, bool) and value > 0


def entry(row, provider):
    synthetic = provider == "synthetic"
    modalities = row.get("input_modalities") if synthetic else (row.get("architecture") or {}).get("input_modalities")
    name = row["display_name" if synthetic else "name"]
    if synthetic and row["id"].startswith("infinite:") and not name.endswith(" (infinite)"):
        name += " (infinite)"
    result = {
        "name": name,
        "input": [m for m in ("text", "image") if m in (modalities or [])],
    }
    # OpenRouter prices and provider limits belong to OMP's runtime metadata.
    # Omitting them preserves bundled estimates and unknown/free distinctions.
    if synthetic:
        pricing = row.get("pricing") or {}
        result["cost"] = {key: per_million(pricing.get(source)) for key, source in {
            "input": "prompt", "output": "completion",
            "cacheRead": "input_cache_reads", "cacheWrite": "input_cache_writes",
        }.items()}
    context = row.get("context_length")
    for key, value in (("contextWindow", context),
                       ("maxTokens", row.get("max_output_length") if synthetic else None)):
        if positive(value):
            result[key] = value
    reasoning_key = "reasoning_parameters" if synthetic else "reasoning"
    if synthetic or reasoning_key in row:
        reasoning = row.get(reasoning_key)
        result["reasoning"] = reasoning is not None
        if reasoning is not None:
            efforts = reasoning.get("efforts" if synthetic else "supported_efforts") or []
            # GLM 5.3 must not inherit Synthetic's generic ladder.
            if synthetic and row["id"] == "hf:zai-org/GLM-5.3":
                efforts = ["low", "high", "max"]
            supported = [effort for effort in EFFORTS if effort in efforts]
            if supported:
                result["thinking"] = {"mode": "effort", "efforts": supported}
                if not synthetic and "mandatory" in reasoning:
                    result["thinking"]["requiresEffort"] = reasoning["mandatory"]
    return result


def main(synthetic, openrouter, bundled, synthetic_helper, openrouter_helper, output):
    with open(bundled) as handle:
        known = {(m["provider"], m["id"]) for m in json.load(handle)["models"]}
    for provider in ("synthetic", "openrouter"):
        if not any(name == provider for name, _ in known):
            raise ValueError(f"OMP listed no bundled {provider} models")
    providers = {}
    for name, path, helper, url in (
        ("synthetic", synthetic, synthetic_helper, "https://api.synthetic.new/openai/v1"),
        ("openrouter", openrouter, openrouter_helper, "https://openrouter.ai/api/v1"),
    ):
        provider = {"baseUrl": url, "apiKey": "!" + helper, "models": [], "modelOverrides": {}}
        with open(path) as handle:
            rows = json.load(handle)["data"]
        for row in rows:
            metadata = entry(row, name)
            if (name, row["id"]) in known:
                provider["modelOverrides"][row["id"]] = metadata
            else:
                provider["models"].append({"id": row["id"], "api": "openai-completions", **metadata})
        providers[name] = provider
    with open(output, "w") as handle:
        json.dump({"providers": providers}, handle, indent=2, sort_keys=True)
        handle.write("\n")


if __name__ == "__main__":
    main(*sys.argv[1:])
