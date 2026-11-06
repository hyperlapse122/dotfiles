"""Prove real native PIN storage with synthetic prompts on disposable CI only."""

import json
import os
from pathlib import Path
import random
import shutil
import subprocess
import sys
import tempfile

from smoke_github_auth import failure_summary, native_keychain


REPO = Path(__file__).resolve().parents[1]


class SmokeFailure(RuntimeError):
    """Only fixed, secret-free assertions may use this diagnostic."""


def require_disposable_runner():
    if not (os.environ.get("GITHUB_ACTIONS") == "true"
            and os.environ.get("RUNNER_ENVIRONMENT") == "github-hosted"):
        raise SystemExit("Native credential writes require a disposable GitHub-hosted runner")


def execute(arguments, env, *, input=""):
    return subprocess.run(arguments, env=env, input=input, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, text=True, encoding="utf-8", timeout=60)


def check(condition, operation):
    if not condition:
        raise SmokeFailure(operation)


def request(card, *, warning=False, prompt="PIN", description=None):
    description = description or (
        "Please unlock the card\n\nNumber: " + card + "\nHolder: Disposable fixture\nCounter: 1")
    if warning:
        description += "\n\nRemaining attempts: 2"
    encoded = description.replace("%", "%25").replace("\n", "%0A")
    return ("OPTION allow-external-password-cache\nSETKEYINFO --clear\nSETDESC "
            + encoded + "\nSETPROMPT " + prompt + "\nGETPIN\nBYE\n")


def prove_native(root, env, binary, cards):
    count_file = root / "frontend-count"
    mode_file = root / "frontend-mode"
    count_file.write_text("0", encoding="utf-8")
    mode_file.write_text("input", encoding="utf-8")
    observed_pins = set()

    def count():
        return int(count_file.read_text(encoding="utf-8"))

    def dialog(input, *, cached=False, cancelled=False, native_failure=False, child_env=None):
        result = execute([str(binary)], child_env or env, input=input)
        lines = result.stdout.splitlines()
        data = [line[2:] for line in lines if line.startswith("D ")]
        if native_failure:
            check(result.returncode != 0 and not data
                  and "ERR 83886081 Pinentry request failed" in lines,
                  "Unavailable store did not fail the request")
            check(result.stderr == "dotfiles-pinentry: native PIN store failed\n",
                  "Unavailable store diagnostic was missing")
            return None
        check(result.returncode == 0 and not result.stderr, "Pinentry process failed")
        if cancelled:
            check(not data and "ERR 83886179 Operation cancelled" in lines,
                  "Frontend cancellation changed")
            return None
        check(not any(line.startswith("ERR ") for line in lines), "Pinentry request failed")
        check(len(data) == 1, "Pinentry returned an unexpected data response")
        check(("S PASSWORD_FROM_CACHE" in lines) == cached, "Cache status did not match lookup")
        observed_pins.add(data[0])
        return data[0]

    def manual(input):
        before = count()
        value = dialog(input)
        check(count() == before + 1, "Manual request did not reach the frontend once")
        check(value == f"synthetic-pin-{count():08}", "Manual frontend data changed")
        return value

    def hit(card, expected):
        before = count()
        check(dialog(request(card), cached=True) == expected, "Native cache value changed")
        check(count() == before, "Native cache hit opened the PIN frontend")

    def forget(card, child_env=None):
        result = execute([str(binary), "forget", card], child_env or env)
        check(result.returncode == 0 and not result.stdout and not result.stderr,
              "Card-specific deletion failed or printed output")

    # A new process handles every request, so a hit must survive the process boundary.
    a, b, c, d = cards
    grouped_a = " ".join((a[:-6], a[-6:-3], a[-3:]))
    first = manual(request(grouped_a))
    hit(a, first)
    other = manual(request(b))
    check(other != first, "Separate cards returned the same frontend input")
    hit(a, first)
    hit(b, other)

    replacement = manual(request(a, warning=True))
    check(replacement != first, "Retry warning retained the prior PIN")
    hit(a, replacement)
    hit(b, other)

    forget(a)
    forget(a)
    renewed = manual(request(a))
    check(renewed != replacement, "Deletion retained the prior PIN")
    hit(a, renewed)
    hit(b, other)

    # Delegation must neither overwrite an existing entry nor create a new one.
    for input in (
        request(a, prompt="Admin PIN"),
        request(a, description="Please enter the new PIN"),
        request(a, description="Ordinary key passphrase"),
        request(a, description="Unrecognized card request"),
        request(d, prompt="Admin PIN"),
    ):
        manual(input)
        hit(a, renewed)
        hit(b, other)
    delegated = manual(request(d))
    hit(d, delegated)
    for command, response in (("CONFIRM", "confirmation"), ("MESSAGE", "message")):
        before = count()
        result = execute([str(binary)], env, input=request(a).split("GETPIN")[0]
                         + command + "\nBYE\n")
        check(result.returncode == 0 and not result.stderr
              and "OK frontend " + response in result.stdout.splitlines()
              and not any(line.startswith("D ") for line in result.stdout.splitlines())
              and count() == before, "Delegated dialog result changed")
        hit(a, renewed)

    mode_file.write_text("cancel", encoding="utf-8")
    before = count()
    dialog(request(c), cancelled=True)
    check(count() == before + 1, "Cancellation did not reach the frontend")
    hit(a, renewed)
    hit(b, other)
    mode_file.write_text("input", encoding="utf-8")
    enrolled = manual(request(c))
    hit(c, enrolled)

    # Warning invalidation is durable even if the replacement dialog is cancelled.
    mode_file.write_text("cancel", encoding="utf-8")
    dialog(request(a, warning=True), cancelled=True)
    mode_file.write_text("input", encoding="utf-8")
    after_cancel = manual(request(a))
    hit(a, after_cancel)
    hit(b, other)

    if sys.platform.startswith("linux"):
        unavailable = env | {"DBUS_SESSION_BUS_ADDRESS": "unix:path=" + str(root / "no-bus")}
        before = count()
        dialog(request(a), native_failure=True, child_env=unavailable)
        dialog(request(a, warning=True), native_failure=True, child_env=unavailable)
        check(count() == before, "Unavailable store opened the manual PIN dialog")
        failed_delete = execute([str(binary), "forget", a], unavailable)
        check(failed_delete.returncode != 0 and not failed_delete.stdout
              and failed_delete.stderr == "dotfiles-pinentry: native PIN store failed\n",
              "Unavailable store deletion did not fail safely")
        # Delegation still works when no native storage can be initialized.
        manual_input = request(a, description="Ordinary key passphrase")
        check(dialog(manual_input, child_env=unavailable) == f"synthetic-pin-{count():08}",
              "Delegation required an available native store")
        hit(a, after_cancel)

    for path in root.rglob("*"):
        if path.is_file():
            contents = path.read_bytes()
            check(not any(pin.encode("utf-8") in contents for pin in observed_pins),
                  "Synthetic PIN reached a fixture file")


def main():
    # This gate precedes native-store initialization, compilation, and fixture writes.
    require_disposable_runner()
    suffix = ".exe" if os.name == "nt" else ""
    release = REPO / "pinentry/target/release" / ("dotfiles-pinentry" + suffix)
    rustc = shutil.which("rustc")
    check(release.is_file() and rustc is not None, "Release binary or Rust compiler is missing")
    with tempfile.TemporaryDirectory(prefix="native-pinentry-", dir=os.environ["RUNNER_TEMP"]) as scratch:
        root = Path(scratch)
        binary = root / ("dotfiles-pinentry" + suffix)
        frontend = root / ("frontend" + suffix)
        shutil.copy2(release, binary)
        env = os.environ.copy()
        compiled = execute([rustc, "--edition=2024", "--crate-name", "pinentry_frontend",
                            str(REPO / "tests/fixtures/pinentry_frontend.rs"), "-o", str(frontend)], env)
        check(compiled.returncode == 0, "Native fixture frontend compilation failed")
        binary.with_suffix(".json").write_text(json.dumps({"fallback": str(frontend)}), encoding="utf-8")
        cards = [str(value) for value in random.SystemRandom().sample(range(3_000_000_000, 4_000_000_000), 4)]
        with native_keychain(root, env):
            try:
                prove_native(root, env, binary, cards)
            finally:
                failed = False
                for card in cards:
                    result = execute([str(binary), "forget", card], env)
                    failed |= result.returncode != 0 or bool(result.stdout) or bool(result.stderr)
                check(not failed, "Synthetic native-record cleanup failed")
    print("Native enrollment, cross-process hits, card isolation, warning replacement, deletion, "
          "cancellation, and delegation passed")
    if sys.platform.startswith("linux"):
        print("Isolated unavailable Secret Service read and deletion failures passed")


if __name__ == "__main__":
    try:
        main()
    except SmokeFailure as error:
        raise SystemExit("Native pinentry smoke failed: " + str(error)) from None
    except Exception as error:
        raise SystemExit(failure_summary(error, ("smoke_pinentry.py", "smoke_github_auth.py"))) from None
