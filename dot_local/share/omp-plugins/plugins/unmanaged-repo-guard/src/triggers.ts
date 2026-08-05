/**
 * Block-trigger classifier (plan U1).
 *
 * Decides whether a `tool_call` is an issue write the guard governs. Pure: no
 * I/O, no omp coupling. The guard blocks on permission it cannot decide, but
 * passes on a tool it does not recognise (plan KTD4) — so an unmatched tool
 * name is `ignore`, while an unparseable *recognised* command resolves toward
 * probing.
 */

export type HostKind = "github" | "gitlab";

export type Classification =
  | { kind: "ignore" }
  | {
      kind: "issue-write";
      /** CLI the write goes through, or `null` for an MCP-routed call. */
      cli: "gh" | "glab" | null;
      /** Repository named on the command, if any. Unvalidated. */
      repo: string | null;
      /** Host named on the command via GH_HOST/GITLAB_HOST/--hostname. */
      host: string | null;
      hostKind: HostKind | null;
      /**
       * Literal directory a preceding `cd` moved to, so the caller resolves
       * `origin` from the directory the write actually runs in.
       */
      cdTarget: string | null;
      /**
       * A preceding `cd` whose target this classifier cannot resolve literally.
       * With no explicit `--repo`, the write target is then unknowable and the
       * caller must fail closed (plan R3).
       */
      cwdUnresolvable: boolean;
    };

const IGNORE: Classification = { kind: "ignore" };

/** Interpreters whose heredoc/here-string body is executed, not data. */
const INTERPRETERS: Record<string, true> = {
  bash: true,
  sh: true,
  dash: true,
  zsh: true,
  ksh: true,
  python: true,
  python3: true,
  node: true,
  bun: true,
  perl: true,
  ruby: true,
};

/** Leading tokens that precede the real argv head. */
const ARGV_PREFIXES: Record<string, true> = {
  env: true,
  sudo: true,
  command: true,
  exec: true,
  nohup: true,
  time: true,
};

const WRITE_METHODS: Record<string, true> = { POST: true, PUT: true, PATCH: true, DELETE: true };

/** Any of these as a path segment makes an API write an issue write. */
const ISSUE_PATH_SEGMENTS: Record<string, true> = {
  issues: true,
  notes: true,
  discussions: true,
};

/** MCP tool names known to create or comment on an issue. */
const MCP_ISSUE_WRITE_TOOLS: Record<string, true> = {
  mcp__glab_issue_create: true,
  mcp__glab_issue_note: true,
  mcp__glab_work_items_create: true,
  mcp__github_issue_create: true,
  mcp__github_issue_comment: true,
};

/**
 * Narrow shape match for an MCP issue-write tool from a server this table does
 * not name yet. Deliberately narrow: a broad pattern would catch reads.
 */
const MCP_ISSUE_WRITE_PATTERN =
  /^mcp__[a-z0-9]+_(?:issue_create|issue_note(?:_create)?|issue_comment|work_items_create)$/;

/**
 * One simple command. `bodies` holds every heredoc/here-string opened on this
 * command, attached by object reference so a shell operator appearing before
 * the body is read cannot strand it on a later segment.
 */
type Segment = { text: string; bodies: string[] };

type SplitResult = { segments: Segment[]; unparseable: boolean };

/** Length of a shell control operator at `i`, or 0. Redirections are not operators. */
function operatorLength(s: string, i: number): number {
  if (s.startsWith("&&", i) || s.startsWith("||", i)) return 2;
  const c = s[i];
  if (c === ";" || c === "\n") return 1;
  if (c === "|") return 1;
  if (c === "&") {
    // `2>&1`, `>&2`, `&>file` are redirections; only a lone `&` backgrounds.
    if (s[i + 1] === ">") return 0;
    let k = i - 1;
    while (k >= 0 && /[0-9]/.test(s[k] as string)) k -= 1;
    if (s[k] === ">" || s[k] === "<") return 0;
    return 1;
  }
  return 0;
}

/**
 * Shell-aware split into simple commands.
 *
 * Tracks quote and heredoc state so an operator inside a quoted string or a
 * heredoc body never splits.
 */
export function splitCommand(command: string): SplitResult {
  const segments: Segment[] = [];
  let current: Segment = { text: "", bodies: [] };
  let quote: '"' | "'" | null = null;
  let unparseable = false;

  // Heredocs opened on the current line, consumed at the next newline. Each
  // holds its opening segment so the body lands on the right command.
  let pending: { delim: string; stripTabs: boolean; owner: Segment }[] = [];

  const pushSegment = () => {
    const owed = pending.some((h) => h.owner === current);
    if (current.text.trim() !== "" || current.bodies.length > 0 || owed) segments.push(current);
    current = { text: "", bodies: [] };
  };

  let i = 0;
  while (i < command.length) {
    const c = command[i] as string;

    if (quote) {
      if (c === "\\" && quote === '"' && i + 1 < command.length) {
        current.text += c + command[i + 1];
        i += 2;
        continue;
      }
      if (c === quote) quote = null;
      current.text += c;
      i += 1;
      continue;
    }

    if (c === "\\" && i + 1 < command.length) {
      current.text += c + command[i + 1];
      i += 2;
      continue;
    }

    if (c === "'" || c === '"') {
      quote = c;
      current.text += c;
      i += 1;
      continue;
    }

    // Here-string: the body is the next word, inline.
    if (command.startsWith("<<<", i)) {
      i += 3;
      while (command[i] === " " || command[i] === "\t") i += 1;
      let word = "";
      const q = command[i];
      if (q === "'" || q === '"') {
        i += 1;
        while (i < command.length && command[i] !== q) {
          word += command[i];
          i += 1;
        }
        if (i >= command.length) unparseable = true;
        i += 1;
      } else {
        while (i < command.length && !/\s/.test(command[i] as string)) {
          word += command[i];
          i += 1;
        }
      }
      current.bodies.push(word);
      continue;
    }

    // Heredoc: the body starts after the next newline.
    if (command.startsWith("<<", i)) {
      i += 2;
      let stripTabs = false;
      if (command[i] === "-") {
        stripTabs = true;
        i += 1;
      }
      while (command[i] === " " || command[i] === "\t") i += 1;
      let delim = "";
      const q = command[i];
      if (q === "'" || q === '"') {
        i += 1;
        while (i < command.length && command[i] !== q) {
          delim += command[i];
          i += 1;
        }
        if (i >= command.length) unparseable = true;
        i += 1;
      } else {
        while (i < command.length && /[A-Za-z0-9_]/.test(command[i] ?? "")) {
          delim += command[i];
          i += 1;
        }
      }
      if (delim === "") {
        unparseable = true;
      } else {
        pending.push({ delim, stripTabs, owner: current });
      }
      continue;
    }

    if (c === "\n" && pending.length > 0) {
      i += 1;
      for (const h of pending) {
        const lines: string[] = [];
        let closed = false;
        while (i < command.length) {
          let lineEnd = command.indexOf("\n", i);
          if (lineEnd === -1) lineEnd = command.length;
          const rawLine = command.slice(i, lineEnd);
          const line = h.stripTabs ? rawLine.replace(/^\t+/, "") : rawLine;
          i = lineEnd + 1;
          if (line.trim() === h.delim) {
            closed = true;
            break;
          }
          lines.push(rawLine);
        }
        if (!closed) unparseable = true;
        h.owner.bodies.push(lines.join("\n"));
      }
      pending = [];
      pushSegment();
      continue;
    }

    const opLen = operatorLength(command, i);
    if (opLen > 0) {
      i += opLen;
      pushSegment();
      continue;
    }

    current.text += c;
    i += 1;
  }

  if (quote) unparseable = true;
  if (pending.length > 0) unparseable = true;
  pushSegment();

  return { segments, unparseable };
}

/** Split one simple command into argv, stripping one level of quoting. */
export function toArgv(text: string): string[] {
  const argv: string[] = [];
  let token = "";
  let started = false;
  let quote: '"' | "'" | null = null;

  const flush = () => {
    if (started) argv.push(token);
    token = "";
    started = false;
  };

  for (let i = 0; i < text.length; i += 1) {
    const c = text[i] as string;
    if (quote) {
      if (c === "\\" && quote === '"' && i + 1 < text.length) {
        token += text[i + 1];
        i += 1;
        continue;
      }
      if (c === quote) {
        quote = null;
        continue;
      }
      token += c;
      started = true;
      continue;
    }
    if (c === "\\" && i + 1 < text.length) {
      token += text[i + 1];
      started = true;
      i += 1;
      continue;
    }
    if (c === "'" || c === '"') {
      quote = c;
      started = true;
      continue;
    }
    if (/\s/.test(c)) {
      flush();
      continue;
    }
    token += c;
    started = true;
  }
  flush();
  return argv;
}

type ArgvHead = {
  head: string | null;
  rest: string[];
  envHost: string | null;
  /** True when the head could not be determined (substitution, empty). */
  opaque: boolean;
};

function argvHead(argv: string[]): ArgvHead {
  let envHost: string | null = null;
  let i = 0;
  while (i < argv.length) {
    const raw = argv[i] as string;
    // Grouping punctuation is not part of the command name: `(gh …)`, `{ gh …; }`.
    const t = raw.replace(/^[({]+/, "").replace(/[)};]+$/, "");
    if (t === "") {
      i += 1;
      continue;
    }
    if (ARGV_PREFIXES[t] === true) {
      i += 1;
      continue;
    }
    const assignment = /^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/.exec(t);
    if (assignment) {
      const name = assignment[1];
      if (name === "GH_HOST" || name === "GITLAB_HOST") envHost = assignment[2] ?? null;
      i += 1;
      continue;
    }
    if (t.includes("$(") || t.includes("`")) {
      return { head: null, rest: [], envHost, opaque: true };
    }
    // Strip a path prefix: /usr/bin/gh -> gh
    const base = t.slice(t.lastIndexOf("/") + 1);
    return { head: base, rest: argv.slice(i + 1), envHost, opaque: false };
  }
  return { head: null, rest: [], envHost, opaque: false };
}

function flagValue(argv: string[], names: string[]): string | null {
  for (let i = 0; i < argv.length; i += 1) {
    const t = argv[i] as string;
    for (const name of names) {
      if (t === name) return argv[i + 1] ?? null;
      if (t.startsWith(`${name}=`)) return t.slice(name.length + 1);
    }
  }
  return null;
}

/** First argument that is not a flag or a flag's value. */
function firstPositional(argv: string[], valueFlags: string[]): string | null {
  for (let i = 0; i < argv.length; i += 1) {
    const t = argv[i] as string;
    if (t.startsWith("-")) {
      if (!t.includes("=") && valueFlags.includes(t)) i += 1;
      continue;
    }
    return t;
  }
  return null;
}

const API_VALUE_FLAGS = ["-X", "--method", "-H", "--header", "-f", "--field", "-F", "--raw-field"];

/** Arguments after the `api` subcommand, so the subcommand is not read as the path. */
function apiArgs(rest: string[]): string[] {
  const at = rest.indexOf("api");
  return at === -1 ? rest : rest.slice(at + 1);
}

function apiPathIsIssueWrite(argv: string[]): boolean {
  const method = flagValue(argv, ["-X", "--method"]);
  if (!method || WRITE_METHODS[method.toUpperCase()] !== true) return false;
  const path = firstPositional(argv, API_VALUE_FLAGS);
  if (!path) return false;
  const clean = (path.split("?")[0] ?? "").replace(/^\/+/, "");
  return clean.split("/").some((seg) => ISSUE_PATH_SEGMENTS[seg.toLowerCase()] === true);
}

function repoFromApiPath(argv: string[], cli: "gh" | "glab"): string | null {
  const path = firstPositional(argv, API_VALUE_FLAGS);
  if (!path) return null;
  const segs = (path.split("?")[0] ?? "").replace(/^\/+/, "").split("/");
  if (cli === "gh") {
    const at = segs.indexOf("repos");
    if (at >= 0 && segs[at + 1] && segs[at + 2]) return `${segs[at + 1]}/${segs[at + 2]}`;
    return null;
  }
  const at = segs.indexOf("projects");
  if (at >= 0 && segs[at + 1]) {
    try {
      return decodeURIComponent(segs[at + 1] as string);
    } catch {
      return segs[at + 1] as string;
    }
  }
  return null;
}

/** Does this `gh`/`glab` argv describe an issue write? `words` is `rest` minus flags. */
function cliIsIssueWrite(words: string[], rest: string[]): boolean {
  const [subcommand, verb] = words;
  if (subcommand === "api") return apiPathIsIssueWrite(apiArgs(rest));
  // `pr`/`mr` verbs are out of scope (R7), and `issue update` is the
  // self-assignment carve-out (R6); both fall through to false.
  if (subcommand !== "issue") return false;
  return verb === "create" || verb === "comment" || verb === "note";
}

/** A `cd` target this classifier can resolve literally, or `null` if it cannot. */
function literalCdTarget(rest: string[]): string | null {
  const target = firstPositional(rest, []);
  if (target === null) return null; // bare `cd` goes $HOME; not resolvable here
  if (target === "-" || target.includes("$") || target.includes("`") || target.startsWith("~")) {
    return null;
  }
  return target;
}

function classifyBash(command: string): Classification {
  const { segments, unparseable } = splitCommand(command);

  // `cd` state accumulated from segments preceding the matched write.
  let cdTarget: string | null = null;
  let cwdUnresolvable = false;

  for (const segment of segments) {
    const argv = toArgv(segment.text);
    const { head, rest, envHost, opaque } = argvHead(argv);
    if (opaque) return fallbackScan(command);
    if (!head) continue;

    if (head === "cd" || head === "pushd") {
      const target = literalCdTarget(rest);
      if (target === null) {
        cwdUnresolvable = true;
      } else if (target.startsWith("/")) {
        cdTarget = target;
      } else {
        cdTarget = cdTarget === null ? target : `${cdTarget}/${target}`;
      }
      continue;
    }
    if (head === "popd") {
      // Restoring an earlier directory is not something this classifier tracks.
      cwdUnresolvable = true;
      continue;
    }

    // Interpreter stdin carries executable text, always: recurse. A body
    // attached to a gh/glab segment is inert issue data and is never scanned,
    // because that segment already classifies by its subcommand.
    if (INTERPRETERS[head] === true) {
      for (const body of segment.bodies) {
        const inner = classifyBash(body);
        if (inner.kind === "issue-write") {
          return { ...inner, cdTarget: inner.cdTarget ?? cdTarget, cwdUnresolvable };
        }
      }
      continue;
    }

    if (head !== "gh" && head !== "glab") continue;
    // Skip global flags to find the subcommand pair.
    const words = rest.filter((t) => !t.startsWith("-"));
    if (!cliIsIssueWrite(words, rest)) continue;

    const repo =
      flagValue(rest, ["--repo", "-R"]) ??
      (words[0] === "api" ? repoFromApiPath(apiArgs(rest), head) : null);
    const host = envHost ?? flagValue(rest, ["--hostname"]);
    return {
      kind: "issue-write",
      cli: head,
      repo,
      host,
      hostKind: head === "gh" ? "github" : "gitlab",
      cdTarget,
      cwdUnresolvable,
    };
  }

  if (unparseable) return fallbackScan(command);
  return IGNORE;
}

/**
 * Ambiguity inside a recognised route resolves toward probing (plan U1 step 8,
 * KTD4). Safe: the probe still allows the call when the repo is managed.
 */
function fallbackScan(command: string): Classification {
  if (!/\b(?:gh|glab)\b/.test(command)) return IGNORE;
  if (!/\bissue\b/.test(command) && !/\bapi\b/.test(command)) return IGNORE;
  const repo = /(?:--repo[= ]|-R\s+)([^\s"']+)/.exec(command)?.[1] ?? null;
  const gitlab = /\bglab\b/.test(command);
  return {
    kind: "issue-write",
    cli: gitlab ? "glab" : "gh",
    repo,
    host: null,
    hostKind: gitlab ? "gitlab" : "github",
    cdTarget: null,
    // The command could not be decomposed, so any cwd assumption is unsafe.
    cwdUnresolvable: repo === null,
  };
}

function classifyMcp(toolName: string, input: Record<string, unknown>): Classification {
  if (MCP_ISSUE_WRITE_TOOLS[toolName] !== true && !MCP_ISSUE_WRITE_PATTERN.test(toolName)) {
    return IGNORE;
  }
  const repoLike = input["repo"] ?? input["repository"] ?? input["project"] ?? null;
  const hostKind: HostKind = toolName.includes("_glab_") ? "gitlab" : "github";
  return {
    kind: "issue-write",
    cli: null,
    repo: typeof repoLike === "string" && repoLike !== "" ? repoLike : null,
    host: null,
    hostKind,
    cdTarget: null,
    cwdUnresolvable: false,
  };
}

export function classify(toolName: string, input: Record<string, unknown>): Classification {
  if (toolName === "bash") {
    const command = input["command"];
    if (typeof command !== "string" || command === "") return IGNORE;
    return classifyBash(command);
  }
  if (toolName.startsWith("mcp__")) return classifyMcp(toolName, input);
  return IGNORE;
}
