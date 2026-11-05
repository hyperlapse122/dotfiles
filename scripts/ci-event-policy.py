import json
import os
from pathlib import Path
import subprocess
from urllib.parse import quote, urlencode


def decide(event_name, event, snapshot):
    def result(run, reason):
        return {"run": run, "reason": reason}

    if event_name not in ("push", "pull_request"):
        return result(True, "Explicit invocation retains independent validation")
    if snapshot.get("api_error"):
        return result(True, "Metadata lookup failed; retain validation: " + snapshot["api_error"])
    if event_name == "pull_request":
        original = event["pull_request"]
        current = snapshot.get("current_pr", original)
        if current["state"] != "open" or current["head"]["sha"] != original["head"]["sha"]:
            return result(False, "PR closed or head superseded; do not start obsolete integration checks")
        if current["base"]["sha"] != original["base"]["sha"]:
            return result(True, "Base advanced; retain this event's immutable merge-result validation")
        return result(True, "PR event validates its immutable merge result")
    ref = event["ref"]
    if not ref.startswith("refs/heads/"):
        return result(True, "Tag push retains its own validation")
    head = event["after"]
    if snapshot.get("branch_sha", head) != head:
        return result(False, "Branch head superseded before admission")
    repository = event["repository"]
    branch = ref.removeprefix("refs/heads/")
    if branch == repository["default_branch"]:
        return result(True, "Default-branch push retains validation")
    for pull in snapshot.get("pulls", []):
        pr_head = pull["head"]
        if (pull["state"] != "open" or pull.get("mergeable") is not True or
                pr_head["sha"] != head or pr_head["ref"] != branch or
                (pr_head.get("repo") or {}).get("full_name") != repository["full_name"]):
            continue
        title = f"Test pull_request refs/pull/{pull['number']}/merge"
        for run in snapshot.get("pr_runs", []):
            if (run["event"] == "pull_request" and run["head_sha"] == head and
                    run["display_title"] == title and
                    run.get("conclusion") not in ("cancelled", "skipped", "startup_failure")):
                return result(False, f"PR #{pull['number']} merge validation owns this head; omit duplicate push suite")
    return result(True, "No applicable scheduled PR merge validation; retain branch suite")


def api(endpoint, *, paginate=False):
    command = ["gh", "api", endpoint]
    if paginate:
        command += ["--paginate", "--slurp"]
    completed = subprocess.run(command, capture_output=True, text=True, encoding="utf-8", timeout=60)
    if completed.returncode:
        raise RuntimeError(completed.stderr.strip() or "GitHub metadata request failed")
    return json.loads(completed.stdout)


def fetch_snapshot(event_name, event):
    repository = os.environ["GITHUB_REPOSITORY"]
    root = f"repos/{repository}"
    if event_name == "pull_request":
        return {"current_pr": api(f"{root}/pulls/{event['number']}")}
    if event_name != "push" or not event["ref"].startswith("refs/heads/"):
        return {}
    branch = event["ref"].removeprefix("refs/heads/")
    ref = api(f"{root}/git/ref/heads/{quote(branch, safe='')}")
    snapshot = {"branch_sha": ref["object"]["sha"]}
    if branch == event["repository"]["default_branch"] or snapshot["branch_sha"] != event["after"]:
        return snapshot
    owner = repository.split("/", 1)[0]
    query = urlencode({"state": "open", "head": f"{owner}:{branch}", "per_page": 100})
    pages = api(f"{root}/pulls?{query}", paginate=True)
    snapshot["pulls"] = [api(f"{root}/pulls/{pull['number']}") for page in pages for pull in page]
    if any(pull.get("mergeable") is True and pull["head"]["sha"] == event["after"] for pull in snapshot["pulls"]):
        query = urlencode({"event": "pull_request", "head_sha": event["after"], "per_page": 100})
        pages = api(f"{root}/actions/workflows/test-events.yml/runs?{query}", paginate=True)
        snapshot["pr_runs"] = [run for page in pages for run in page["workflow_runs"]]
    return snapshot


def main():
    event_name = os.environ["GITHUB_EVENT_NAME"]
    event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text(encoding="utf-8"))
    try:
        snapshot = fetch_snapshot(event_name, event)
    except (OSError, RuntimeError, subprocess.TimeoutExpired, ValueError) as error:
        snapshot = {"api_error": str(error)}
    decision = decide(event_name, event, snapshot)
    print(json.dumps(decision), flush=True)
    with Path(os.environ["GITHUB_OUTPUT"]).open("a", encoding="utf-8") as output:
        output.write(f"run={str(decision['run']).lower()}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
