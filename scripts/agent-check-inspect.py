"""Local source warnings and opt-in existence checks for registry dependencies."""

from concurrent.futures import ThreadPoolExecutor
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
from urllib.parse import quote, urlsplit


# The deterministic categories from Anthropic's security-guidance plugin.
JS = {".js", ".jsx", ".mjs", ".cjs", ".ts", ".tsx", ".mts", ".cts", ".vue", ".svelte", ".astro"}
PYTHON = {".py", ".pyw", ".pyi"}
WEB = JS | {".html", ".htm"}
CODE = JS | PYTHON | {".go", ".sh", ".bash", ".zsh", ".rb", ".php"}
CONFIG = CODE | {".json", ".toml", ".yaml", ".yml", ".nix", ".ini", ".cfg", ".env"}
RULES = [
    ("child_process_exec", JS, r"(?<![\w.])exec(?:Sync)?\s*\(|child_process\.exec\b"),
    ("new_function_injection", JS, r"\bnew\s+Function\s*\("),
    ("eval_injection", CODE, r"(?<![\w.$])eval\s*\("),
    ("react_dangerously_set_html", JS, r"\bdangerouslySetInnerHTML\b"),
    ("document_write_xss", WEB, r"\bdocument\.writeln?\s*\("),
    ("inner_html_xss", WEB, r"\.innerHTML\s*=(?!=)"),
    ("outer_html_xss", WEB, r"\.outerHTML\s*=(?!=)"),
    ("insert_adjacent_html_xss", WEB, r"\.insertAdjacentHTML\s*\("),
    ("pickle_deserialization", PYTHON, r"\bpickle\.(?:loads?|Unpickler)\b"),
    ("pickle_variants_load", PYTHON, r"\b(?:cPickle|cloudpickle|dill)\.loads?\s*\("),
    ("pickle_wrapper_load", PYTHON,
     r"\b(?:joblib\.load|(?:pd|pandas)\.read_pickle)\s*\(|\b(?:np|numpy)\.load\([^)]*allow_pickle\s*=\s*True"),
    ("os_system_injection", PYTHON, r"\bos\.system\s*\(|\bfrom os import system\b"),
    ("python_subprocess_shell", PYTHON,
     r"\bsubprocess\.(?:run|call|Popen|check_output|check_call)\s*\([^)]*shell\s*=\s*True"),
    ("go_exec_shell_injection", {".go"}, r'\bexec\.Command(?:Context)?\([^)]*"(?:/(?:usr/)?bin/)?(?:sh|bash)"'),
    ("unsafe_yaml_load", PYTHON, r"\byaml\.load\s*\((?![^)]*\bC?SafeLoader\b)"),
    ("yaml_unsafe_load_variants", PYTHON, r"\b(?:yaml\.unsafe_load|yaml_unsafe_load)\s*\("),
    ("node_createcipher_no_iv", JS, r"\bcrypto\.create(?:Cipher|Decipher)\s*\("),
    ("aes_ecb_mode", CODE, r"\bAES\.MODE_ECB\b|\bmodes\.ECB\s*\(|['\x22]aes-\d+-ecb['\x22]"),
    ("tls_verification_disabled", CONFIG,
     r"\bverify\s*=\s*False\b|rejectUnauthorized\s*:\s*false|InsecureSkipVerify\s*:\s*true"
     r"|NODE_TLS_REJECT_UNAUTHORIZED\s*=\s*['\x22]?0|ssl\._create_unverified_context|check_hostname\s*=\s*False"),
    ("marshal_loads", PYTHON, r"\bmarshal\.loads?\s*\("),
    ("shelve_open", PYTHON, r"\bshelve\.open\s*\("),
    ("xml_unsafe_parse", PYTHON,
     r"\b(?:xml\.etree\.ElementTree|ElementTree|ET|minidom|xml\.sax)\.(?:parse|fromstring|XML|parseString|make_parser)\s*\("),
    ("script_src_without_sri", WEB, r"<script\s+(?![^>]*\bintegrity\s*=)[^>]*\bsrc\s*=\s*['\x22](?:https?:)?//"),
    ("torch_unsafe_load", PYTHON, r"\b(?:torch\.load|torch_load)\s*\((?![^)]*weights_only\s*=\s*True)"),
    ("hardcoded_credential", CONFIG,
     r"(?i)\b(?:password|api[_-]?key|access[_-]?token|client[_-]?secret)\b['\x22]?\s*[:=]\s*['\x22][^'\x22\n$]{8,}"),
]
RULES = [(name, extensions, re.compile(pattern)) for name, extensions, pattern in RULES]


def rules_for(name):
    extension = Path(name).suffix.lower() or Path(name).name.lower()
    if Path(name).name.startswith(".env."):
        extension = ".env"
    rules = [(rule, pattern) for rule, extensions, pattern in RULES if extension in extensions]
    if name.startswith(".github/workflows/") and extension in {".yml", ".yaml"}:
        rules.append(("github_actions_workflow", re.compile(
            r"\$\{\{\s*(?:github\.(?:event|head_ref)\b|inputs\.)"
        )))
    return rules


def warn(name, content, rules):
    for rule, pattern in rules:
        match = pattern.search(content)
        if match:
            line = content.count("\n", 0, match.start()) + 1
            print(f"agent-check: warning {json.dumps(name)}:{line} {rule}")


MANIFESTS = {"package.json": "npm", "pyproject.toml": "python", "go.mod": "go"}
NPM_NAME = r"(?:@[a-z0-9_.-]+/)?[a-z0-9_][a-z0-9_.-]*"
# Registry specs are ranges or tags. URLs, paths, workspace references and
# GitHub shorthands carry a separator outside this alphabet.
NPM_SPEC = re.compile(r"[\w.*=<>~^|+ -]+", re.ASCII)
REGISTRIES = {
    "npm": "https://registry.npmjs.org",
    "python": "https://pypi.org",
    "go": "https://proxy.golang.org",
}


def npm_packages(content):
    manifest = json.loads(content)
    for field in ("dependencies", "devDependencies", "optionalDependencies", "peerDependencies"):
        for name, spec in (manifest.get(field) or {}).items():
            if spec.startswith("npm:"):
                alias = re.fullmatch(rf"({NPM_NAME})(?:@(.+))?", spec[4:])
                if not alias:
                    raise ValueError("invalid npm alias")
                name, spec = alias.groups()
            if not re.fullmatch(NPM_NAME, name):
                raise ValueError("invalid npm name")
            if not spec or (NPM_SPEC.fullmatch(spec) and not spec.startswith((".", "/"))):
                yield name, "", False


def python_packages(content):
    import tomllib

    from packaging.requirements import Requirement
    from packaging.utils import canonicalize_name

    manifest = tomllib.loads(content)
    project = manifest.get("project", {})
    tools = manifest.get("tool", {})
    groups = manifest.get("dependency-groups", {})
    uv = tools.get("uv", {})
    sources = {canonicalize_name(name): source for name, source in uv.get("sources", {}).items()}
    lists = [
        manifest.get("build-system", {}).get("requires", []),
        project.get("dependencies", []),
        *project.get("optional-dependencies", {}).values(),
        *groups.values(),
        uv.get("dev-dependencies", []),
    ]
    for group in lists:
        for spec in group:
            if isinstance(spec, dict) and set(spec) == {"include-group"}:
                continue
            requirement = Requirement(spec)
            if requirement.url:
                continue
            name = canonicalize_name(requirement.name)
            source = sources.get(name, {})
            entries = source if isinstance(source, list) else [source]
            if entries and all(entry.keys() & {"path", "git", "url", "workspace"} for entry in entries):
                continue
            yield name, "", any("index" in entry for entry in entries)

    poetry = tools.get("poetry", {})
    for table in [poetry, *poetry.get("group", {}).values(),
                  {"dependencies": poetry.get("dev-dependencies", {})}]:
        for name, specs in table.get("dependencies", {}).items():
            if name.lower() == "python":
                continue
            specs = specs if isinstance(specs, list) else [specs]
            entries = [spec for spec in specs
                       if isinstance(spec, str) or not spec.keys() & {"path", "git", "url"}]
            if entries:
                yield canonicalize_name(name, validate=True), "", any(
                    isinstance(spec, dict) and "source" in spec for spec in entries
                )


def go_packages(content):
    env = dict(os.environ, GOTOOLCHAIN="local", GOWORK="off", GOENV="off",
               GOPROXY="off", GOSUMDB="off", GOFLAGS="")
    with tempfile.NamedTemporaryFile(suffix=".mod") as manifest:
        manifest.write(content.encode())
        manifest.flush()
        result = subprocess.run(["go", "mod", "edit", "-json", manifest.name], env=env,
                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=True)
    module = json.loads(result.stdout)
    replacements = {(entry["Old"]["Path"], entry["Old"].get("Version", "")): entry["New"]
                    for entry in module.get("Replace") or []}
    for entry in module.get("Require") or []:
        original = (entry["Path"], entry["Version"])
        replacement = replacements.get(original, replacements.get((original[0], ""), entry))
        if version := replacement.get("Version"):
            name = replacement["Path"]
            if not re.fullmatch(r"[\w.~/-]+", name, re.ASCII) or any(
                part in {"", ".", ".."} for part in name.split("/")
            ) or not re.fullmatch(r"v[\w.+-]+", version, re.ASCII):
                raise ValueError("invalid Go module reference")
            yield name, version, False


PARSERS = {"npm": npm_packages, "python": python_packages, "go": go_packages}


def registry_policy(path, root):
    path = Path(path)
    if (not path.is_absolute() or Path(os.path.abspath(path)).is_relative_to(root)
            or path.resolve().is_relative_to(root)):
        raise ValueError("registry policy must be an absolute path outside the checkout")
    policy = json.loads(path.read_text())
    if not isinstance(policy, dict) or policy.keys() - {"public", "private"}:
        raise ValueError("invalid registry policy")
    return policy


def go_escape(value):
    return re.sub(r"[A-Z]", lambda match: "!" + match[0].lower(), value)


def request(url, token):
    headers = f"Authorization: Bearer {token}\n" if token else ""
    result = subprocess.run(
        ["curl", "-q", "--silent", "--globoff", "--noproxy", "*", "--proto", "=https",
         "--connect-timeout", "5", "--max-time", "15", "--max-filesize", "20000000",
         "--header", "@-", "--write-out", "\n%{http_code}", "--url", url],
        input=headers.encode(), stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
    )
    body, _, status = result.stdout.rpartition(b"\n")
    if result.returncode:
        return "incomplete", {}
    if status in (b"404", b"410"):
        return "missing", {}
    if status == b"200":
        try:
            doc = json.loads(body)
        except (ValueError, UnicodeError):
            doc = None
        if isinstance(doc, dict):
            return "found", doc
    return "incomplete", {}


def approved_route(policy, ecosystem, name, explicitly_private):
    private = policy.get("private", {}).get(ecosystem, {})
    public = policy.get("public", {}).get(ecosystem, [])
    if not isinstance(private, dict) or not isinstance(public, list):
        raise ValueError("invalid registry policy")
    matches = [key for key in private if key == name or (key.endswith("/") and name.startswith(key))]
    if matches:
        route = private[max(matches, key=len)]
        endpoint = route["url"]
        url = urlsplit(endpoint)
        if (url.scheme != "https" or not url.hostname or url.username is not None
                or "?" in endpoint or "#" in endpoint or any(char.isspace() for char in endpoint)):
            raise ValueError("invalid registry endpoint")
        token_env = route.get("tokenEnv")
        token = os.environ.get(token_env, "") if token_env else ""
        if token_env and not re.fullmatch(r"[!-~]+", token):
            raise ValueError("registry authentication unavailable")
        return endpoint.rstrip("/"), token, False
    if not explicitly_private and name in public:
        return REGISTRIES[ecosystem], "", True
    return None


def publication(value):
    if isinstance(value, str) and re.fullmatch(r"\d{4}-\d{2}-\d{2}(?:T[0-9:.+-]+Z?)?", value):
        return value[:10]
    return "unavailable"


def lookup(policy, ecosystem, name, version, explicitly_private):
    route = approved_route(policy, ecosystem, name, explicitly_private)
    if route is None:
        return False, f"agent-check: {ecosystem} lookup incomplete (no approved registry for a dependency)"
    endpoint, token, public = route
    encoded = quote(name, safe="@")
    suffix = {
        "npm": encoded,
        "python": f"pypi/{encoded}/json",
        "go": f"{go_escape(name)}/@v/{go_escape(version)}.info",
    }[ecosystem]
    status, metadata = request(f"{endpoint}/{suffix}", token)
    label = f"agent-check: {ecosystem} {name}"
    if status == "missing":
        return False, f"{label}: missing from approved registry"
    if status != "found":
        return False, f"{label}: lookup incomplete"

    count = metadata.get("downloads")
    date = None
    if ecosystem == "npm" and metadata.get("name") == name:
        times = metadata.get("time")
        date = times.get("created") if isinstance(times, dict) else None
        if public:
            _, downloads = request(f"https://api.npmjs.org/downloads/point/last-week/{encoded}", "")
            count = downloads.get("downloads")
    elif ecosystem == "python" and isinstance(metadata.get("info"), dict) and re.fullmatch(
        r"[A-Za-z0-9_.-]+", str(metadata["info"].get("name", ""))
    ) and re.sub(r"[-_.]+", "-", metadata["info"]["name"]).lower() == name:
        dates = [publication(file.get("upload_time_iso_8601")) for file in metadata.get("urls", [])
                 if isinstance(file, dict)]
        date = min(dates, default=None)
    elif ecosystem == "go" and metadata.get("Version") == version:
        date = metadata.get("Time")
    else:
        return False, f"{label}: lookup incomplete (unexpected registry response)"
    downloads = (f"{count} (last week)" if public and ecosystem == "npm" else str(count)
                 ) if type(count) is int and count >= 0 else "unavailable"
    return True, f"{label}: publication date {publication(date)}, downloads {downloads}"


def baseline(git_dir, tree, name):
    if not tree:
        return ""
    result = subprocess.run(["git", f"--git-dir={git_dir}", "show", f"{tree}:{name}"],
                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    return result.stdout.decode() if not result.returncode else ""


def inspect(args):
    policy = registry_policy(args.policy, Path(args.root)) if args.policy else None
    cwd = Path.cwd()
    pending = {}
    failures = False
    for raw in Path(args.paths).read_bytes().split(b"\0"):
        name = os.fsdecode(raw)
        path = cwd / name
        if not name:
            continue
        rules = rules_for(name)
        ecosystem = MANIFESTS.get(path.name) if policy is not None else None
        if not (rules or ecosystem) or path.resolve() != path or not path.is_file():
            continue
        content = path.read_text(errors="replace")
        warn(name, content, rules)
        if ecosystem is None:
            continue
        parse = PARSERS[ecosystem]
        try:
            old = baseline(args.git_dir, args.base, name)
            existing = {(package, private) for package, _, private in parse(old)} if old else set()
            for package, version, private in parse(content):
                if (package, private) not in existing:
                    key = (ecosystem, package, version)
                    pending[key] = pending.get(key, False) or private
        except (KeyError, ValueError, TypeError, AttributeError, subprocess.SubprocessError):
            print(f"agent-check: {json.dumps(name)} dependency lookup incomplete (invalid manifest)")
            failures = True
    def check_dependency(item):
        (ecosystem, name, version), private = item
        try:
            return lookup(policy, ecosystem, name, version, private)
        except (KeyError, ValueError, TypeError, AttributeError, OSError):
            return False, f"agent-check: {ecosystem} lookup incomplete (invalid policy, authentication, or response)"

    if pending:
        with ThreadPoolExecutor(max_workers=4) as workers:
            for passed, diagnostic in workers.map(check_dependency, sorted(pending.items())):
                print(diagnostic)
                failures |= not passed
    return int(failures)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--policy")
    parser.add_argument("--root", required=True)
    parser.add_argument("--git-dir", required=True)
    parser.add_argument("--base", default="")
    parser.add_argument("--paths", required=True)
    try:
        return inspect(parser.parse_args())
    except (OSError, ValueError, RuntimeError):
        print("agent-check: inspection incomplete (unreadable input or invalid registry policy; "
              "use an absolute policy path outside the checkout)")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
