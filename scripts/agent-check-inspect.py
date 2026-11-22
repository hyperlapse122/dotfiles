"""Local source warnings and opt-in existence checks for registry dependencies."""

from concurrent.futures import ThreadPoolExecutor
from functools import cache
import argparse
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
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


def npm_config(content):
    registries = {}
    for line in content.splitlines():
        line = line.lstrip("\ufeff \t")
        if line.startswith(("#", ";")):
            continue
        key, separator, value = line.partition("=")
        key = key.strip()
        if key.startswith("'") and key.endswith("'"):
            key = key[1:-1]
        if key.startswith('"') and key.endswith('"'):
            key = json.loads(key)
        if "${" in key:
            # npm also interpolates keys, so their scope may be unknown.
            registries[None] = True
            continue
        key = key.lower()
        if not re.fullmatch(r"(?:@[^:\s]+:)?registry(?:\[\])?", key):
            continue
        value = value.strip()
        if value.startswith(('"', "'")) and value.endswith(value[0]):
            value = value[1:-1]
        else:
            value = re.split(r"(?<!\\)[;#]", value, maxsplit=1)[0].strip()
        # Unknown, interpolated and array values also require a private approval.
        route_key = key.removesuffix("[]")
        private = not separator or key.endswith("[]") or value.rstrip("/") != REGISTRIES["npm"]
        registries[route_key] = registries.get(route_key, False) or private
    return registries


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
        result = subprocess.run(["go", "mod", "edit", "-json", manifest.name], env=env, cwd="/",
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
    token_names = set()
    for routes in policy.get("private", {}).values():
        for route in routes.values():
            if "tokenEnv" in route:
                name = route["tokenEnv"]
                if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", name):
                    raise ValueError("invalid registry token variable")
                token_names.add(name)
    tokens = {name: os.environ.pop(name, "") for name in token_names}
    return policy, tokens


def go_escape(value):
    return re.sub(r"[A-Z]", lambda match: "!" + match[0].lower(), value)


def request(url, token):
    headers = f"Authorization: Bearer {token}\n" if token else ""
    result = subprocess.run(
        ["curl", "-q", "--silent", "--globoff", "--noproxy", "*", "--proto", "=https",
         "--connect-timeout", "5", "--max-time", "15", "--max-filesize", "20000000",
         "--header", "@-", "--write-out", "\n%{http_code}", "--url", url],
        input=headers.encode(), stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, cwd="/",
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


def approved_route(policy, tokens, ecosystem, name, explicitly_private):
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
        token = tokens.get(token_env, "") if token_env else ""
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


def lookup(policy, tokens, ecosystem, name, version, explicitly_private):
    route = approved_route(policy, tokens, ecosystem, name, explicitly_private)
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


def inspect_source(paths):
    cwd = Path.cwd()
    for raw in Path(paths).read_bytes().split(b"\0"):
        name = os.fsdecode(raw)
        path = cwd / name
        rules = rules_for(name)
        if rules and path.resolve() == path and path.is_file():
            warn(name, path.read_text(errors="replace"), rules)
    return 0


def git(*args, check=True):
    result = subprocess.run(
        ["git", "-c", "core.fsmonitor=false", "--no-replace-objects", "--no-lazy-fetch", *args],
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=check,
    )
    return result.stdout if not result.returncode else b""


class Snapshot:
    def __init__(self, files, worktree=None):
        self.files = files
        self.worktree = worktree
        self.directories = {str(parent) for name in files for parent in Path(name).parents}

    def read(self, name):
        if self.worktree is not None:
            return (self.worktree / name).read_bytes()
        return git("cat-file", "blob", self.files[name][1])

    def link(self, name):
        if self.worktree is not None:
            path = self.worktree / name
            return os.readlink(path) if path.is_symlink() else None
        if self.files.get(name, ("", ""))[0] == "120000":
            return os.fsdecode(self.read(name))
        return None

    @cache
    def resolve(self, name):
        """Return the in-snapshot file and every path consulted along the way."""
        remaining = name.split("/")
        parents = []
        visited = {name}
        links = 0
        while remaining:
            part, *remaining = remaining
            if part in ("", "."):
                continue
            if part == "..":
                if not parents:
                    return None, visited
                parents.pop()
                continue
            path = "/".join([*parents, part])
            visited.add(path)
            link = self.link(path)
            if link is None:
                if remaining and path not in self.directories:
                    return None, visited
                parents.append(part)
                continue
            links += 1
            if not link or link.startswith("/") or "\0" in link or links > 40:
                return None, visited
            remaining = link.split("/") + remaining
        resolved = "/".join(parents)
        visited.add(resolved)
        if resolved in self.files:
            if self.worktree is not None:
                regular = stat.S_ISREG((self.worktree / resolved).lstat().st_mode)
            else:
                regular = self.files[resolved][0] in ("100644", "100755")
            if regular:
                return resolved, visited
        return None, visited


def git_snapshot(tree=None):
    if tree is None:
        records = git("ls-files", "--stage", "-z")
    else:
        records = git("ls-tree", "-rz", tree) if tree else b""
    files = {}
    for record in records.split(b"\0")[:-1]:
        fields, name = record.split(b"\t", 1)
        if tree is None:
            mode, oid, stage = fields.decode().split()
            if stage != "0":
                raise ValueError("unmerged Git index")
        else:
            mode, _, oid = fields.decode().split()
        files[os.fsdecode(name)] = (mode, oid)
    return Snapshot(files)


def selected_snapshots(args, root):
    if args.snapshot == "range":
        base = git("rev-parse", "--verify", "--end-of-options", f"{args.base}^{{tree}}").decode().strip()
        head = git("rev-parse", "--verify", "--end-of-options", f"{args.head}^{{commit}}").decode().strip()
        selected = git_snapshot(head)
        diff_args = [base, head]
    else:
        base = git("rev-parse", "--verify", "HEAD^{tree}", check=False).decode().strip()
        diff_args = ["--cached", *([base] if base else [])]
        if args.snapshot == "staged":
            selected = git_snapshot()
        else:
            names = git("ls-files", "--cached", "--others", "--exclude-standard", "-z")
            paths = map(os.fsdecode, names.split(b"\0")[:-1])
            files = {name: None for name in paths if os.path.lexists(root / name)}
            selected = Snapshot(files, root)
    previous = git_snapshot(base)
    if not base:
        return selected, previous, set(selected.files), {}
    diff = git("diff", "--no-ext-diff", "--no-textconv", "--find-renames",
               "--name-status", "-z", *diff_args, "--")
    fields = iter(diff.split(b"\0")[:-1])
    changed, renamed = set(), {}
    for status in fields:
        name = os.fsdecode(next(fields))
        changed.add(name)
        if status.startswith(b"R"):
            destination = os.fsdecode(next(fields))
            changed.add(destination)
            renamed[destination] = name
    return selected, previous, changed, renamed


def manifest_inputs(snapshot, name, ecosystem):
    names = [name]
    if ecosystem == "npm":
        names.extend(str(parent / ".npmrc") for parent in Path(name).parents)
    used = set()
    resolved = []
    for path in names:
        target, followed = snapshot.resolve(path)
        used.update(followed)
        resolved.append(target)
    return used, list(zip(names, resolved))


def read_inputs(snapshot, inputs):
    if inputs[0][0] not in snapshot.files:
        return ()
    contents = []
    for name, target in inputs:
        if target is None and name in snapshot.files:
            raise ValueError("unresolved manifest or config")
        contents.append(snapshot.read(target) if target is not None else None)
    return contents


def dependencies(contents, ecosystem):
    if not contents:
        return
    manifest, *configs = contents
    npm_registries = [npm_config(config.decode()) for config in configs if config is not None]
    for package, version, private in PARSERS[ecosystem](manifest.decode()):
        scope = package.split("/", 1)[0] + ":registry" if package.startswith("@") else "registry"
        yield package, version, private or any(
            registry.get(None) or registry.get(scope, registry.get("registry", False))
            for registry in npm_registries
        )


def restrict_path(root):
    entries = []
    for entry in map(Path, os.get_exec_path()):
        if entry.is_absolute() and not any(
            (entry / tool).resolve().is_relative_to(root) for tool in ("git", "go", "curl")
        ):
            entries.append(str(entry))
    if not entries:
        raise ValueError("no trusted tool path")
    os.environ["PATH"] = os.pathsep.join(entries)


def inspect_registry(args):
    cwd = Path.cwd()
    # Filter the normal checkout (including linked worktrees) before starting Git.
    hint = next((directory for directory in (cwd, *cwd.parents)
                 if (directory / ".git").exists()), cwd)
    policy, tokens = registry_policy(args.policy, hint)
    restrict_path(hint)
    root = Path(os.fsdecode(git("rev-parse", "--show-toplevel").removesuffix(b"\n"))).resolve()
    if Path(args.policy).resolve().is_relative_to(root):
        raise ValueError("registry policy must be outside the checkout")
    restrict_path(root)
    os.chdir(root)
    selected, previous, changed, renamed = selected_snapshots(args, root)
    pending = {}
    failures = False
    worktree = args.snapshot == "worktree"
    for name in sorted(selected.files) if changed or worktree else ():
        ecosystem = MANIFESTS.get(Path(name).name)
        if ecosystem is None:
            continue
        current_paths, current_inputs = manifest_inputs(selected, name, ecosystem)
        old_name = renamed.get(name, name)
        old_paths, old_inputs = manifest_inputs(previous, old_name, ecosystem)
        if not worktree and not changed.intersection(current_paths | old_paths):
            continue
        try:
            before = read_inputs(previous, old_inputs) if MANIFESTS.get(Path(old_name).name) == ecosystem else ()
            after = read_inputs(selected, current_inputs)
            # Read live inputs directly. Git's worktree diff can invoke clean filters.
            if before == after:
                continue
            existing = {(package, private) for package, _, private in dependencies(before, ecosystem)}
            for package, version, private in list(dependencies(after, ecosystem)):
                if (package, private) not in existing:
                    key = (ecosystem, package, version)
                    pending[key] = pending.get(key, False) or private or (package, True) in existing
        except (KeyError, ValueError, TypeError, AttributeError, OSError, subprocess.SubprocessError):
            print(f"agent-check: {json.dumps(name)} dependency lookup incomplete (invalid manifest)")
            failures = True

    def check_dependency(item):
        (ecosystem, name, version), private = item
        try:
            return lookup(policy, tokens, ecosystem, name, version, private)
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
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--policy")
    mode.add_argument("--paths")
    parser.add_argument("--snapshot", choices=("worktree", "staged", "range"))
    parser.add_argument("--base", default="")
    parser.add_argument("--head", default="")
    args = parser.parse_args()
    try:
        return inspect_registry(args) if args.policy else inspect_source(args.paths)
    except (OSError, KeyError, ValueError, TypeError, AttributeError, RuntimeError, subprocess.SubprocessError):
        print("agent-check: inspection incomplete (unreadable input or invalid registry policy; "
              "use an absolute policy path outside the checkout)", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
