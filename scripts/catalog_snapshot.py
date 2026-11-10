"""What synthetic-models-watch and openrouter-catalog-snapshot share.

Each script keeps its own row validation, defaults, retries, and rule for a
missing key; this module holds the JSON I/O, the snapshot write and shrink
floor, and the fetch that sends a key only as a bearer header on the command's
stdin.
"""

import json
import math
import os
import subprocess

DEFAULT_FETCH = ["curl", "-sSfL", "--max-time", "60"]
MIN_RETENTION = 0.8


class Failure(Exception):
    """A refusal that should stop the run with a readable message."""


def is_int(value):
    return isinstance(value, int) and not isinstance(value, bool)


def is_strings(value):
    return isinstance(value, list) and all(isinstance(v, str) for v in value)


def read_json(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError) as exc:
        raise Failure(f"cannot read {path}: {exc}") from None


def existing_rows(path, parse_row):
    """Well-formed rows already in path, or {} when path is absent or not a snapshot."""
    try:
        with open(path, "r", encoding="utf-8") as f:
            payload = json.load(f)
    except (OSError, json.JSONDecodeError):
        return {}
    data = payload.get("data") if isinstance(payload, dict) else None
    if not isinstance(data, list):
        return {}
    rows = {}
    for row in data:
        try:
            entry = parse_row(row)
        except Failure:
            continue
        if entry is not None:
            rows[entry["id"]] = entry
    return rows


def check_shrink_floor(fresh_count, previous_count):
    """Refuse a snapshot whose valid fresh rows drop below the retention floor."""
    if not previous_count:
        return
    floor = math.ceil(previous_count * MIN_RETENTION)
    if fresh_count < floor:
        raise Failure(f"the catalog shrank from {previous_count} to {fresh_count} models (floor {floor})")


def write(path, text):
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


def write_if_changed(path, text):
    try:
        with open(path, "r", encoding="utf-8") as f:
            if f.read() == text:
                return
    except FileNotFoundError:
        pass
    write(path, text)


def child_env(key_variable):
    """The environment for subprocesses, without the API key."""
    env = dict(os.environ)
    env.pop(key_variable, None)
    return env


def run_fetch(url, key, key_variable):
    """Run curl once; a non-empty key goes only on its stdin, never in its argv."""
    return subprocess.run(
        DEFAULT_FETCH + (["-H", "@-"] if key else []) + [url],
        input=f"Authorization: Bearer {key}\n" if key else "",
        capture_output=True,
        text=True,
        env=child_env(key_variable),
    )
