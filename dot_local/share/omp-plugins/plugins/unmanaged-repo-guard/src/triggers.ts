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

/**
 * Flags whose VALUE is executable text for the interpreter that owns them
 * (R14). `classifyBash` used to scan only heredoc/here-string bodies, so a
 * `bash -c` payload was never read at all.
 */
const INTERPRETER_CODE_FLAGS: Record<string, string[]> = {
  bash: ["-c"],
  sh: ["-c"],
  dash: ["-c"],
  zsh: ["-c"],
  ksh: ["-c"],
  python: ["-c"],
  python3: ["-c"],
  node: ["-e", "--eval", "-p", "--print"],
  bun: ["-e", "--eval", "-p", "--print"],
  perl: ["-e", "-E"],
  ruby: ["-e"],
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
 *
 * Three invariants here are load-bearing and easy to break:
 *
 * 1. **Backslash is bash-asymmetric.** It escapes the next character inside
 *    double quotes and inside an ANSI-C `$'…'` span, and is an ordinary
 *    literal inside plain single quotes. That is bash, not an oversight.
 * 2. **Command substitution is excluded two functions away.** This function
 *    deliberately does not detect `$(…)` or backticks; `argvHead` does, via
 *    its `opaque` check, which routes the whole classification to
 *    `fallbackScan`. Do not add substitution handling here redundantly.
 * 3. **`splitCommand` and `toArgv` are SEPARATE quote state machines and must
 *    stay in lockstep.** Teaching one a quoting form and not the other splits
 *    the tokenizer's model of the same input. Specifically, teaching this
 *    function a form that stops it setting `unparseable` while `toArgv` still
 *    mis-splits removes the `fallbackScan` safety net and yields a
 *    confidently wrong classification instead of a conservative one.
 */
export function splitCommand(command: string): SplitResult {
  const segments: Segment[] = [];
  let current: Segment = { text: "", bodies: [] };
  let quote: '"' | "'" | "$'" | null = null;
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

    // Backslash is bash-asymmetric: an escape inside `"…"` and `$'…'`, an
    // ordinary literal inside `'…'`. Keep this in lockstep with `toArgv`.
    if (quote) {
      if (quote === "$'") {
        if (c === "\\" && i + 1 < command.length) {
          current.text += c + command[i + 1];
          i += 2;
          continue;
        }
        if (c === "'") quote = null;
        current.text += c;
        i += 1;
        continue;
      }
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

    if (c === "$" && command[i + 1] === "'") {
      quote = "$'";
      current.text += "$'";
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
      if (q === "$" && command[i + 1] === "'") {
        // ANSI-C span. Keep the delimiters in `word` so `toArgv` — the single
        // decoder — resolves the escapes later. Without this arm the reader
        // falls to the unquoted branch, stops at the first space, and
        // truncates the body (R14). Mirrors the main loop's `$'` handling;
        // that lockstep is invariant 3 above.
        word += "$'";
        i += 2;
        let closed = false;
        while (i < command.length) {
          const ch = command[i] as string;
          if (ch === "\\" && i + 1 < command.length) {
            word += ch + command[i + 1];
            i += 2;
            continue;
          }
          word += ch;
          i += 1;
          if (ch === "'") {
            closed = true;
            break;
          }
        }
        if (!closed) unparseable = true;
      } else if (q === "'" || q === '"') {
        // Plain quotes are stripped here because their content is already
        // literal; the ANSI-C arm above keeps its delimiters on purpose.
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

/**
 * Decode one ANSI-C (`$'…'`) escape starting at the backslash in `text[i]`.
 *
 * This must be a real decode, not a "drop the backslash" approximation.
 * Bash resolves `$'\x69ssue'` to `issue`, so a tokenizer that yields
 * `x69ssue` classifies `gh $'\x69ssue' create --repo other/repo` as an
 * unrelated command and lets the write through with no permission probe.
 * `fallbackScan` cannot rescue that shape either, because the raw text holds
 * no literal `issue` for its regex to find.
 *
 * Returns the decoded text and the index just past the escape. An escape bash
 * does not recognise keeps its backslash, exactly as bash does.
 */
function decodeAnsiCEscape(text: string, i: number): { out: string; next: number } {
  const c = text[i + 1];
  if (c === undefined) return { out: "\\", next: i + 1 };
  const simple: Record<string, string> = {
    a: "\x07", b: "\b", e: "\x1b", E: "\x1b", f: "\f", n: "\n",
    r: "\r", t: "\t", v: "\v", "\\": "\\", "'": "'", '"': '"', "?": "?",
  };
  const mapped = simple[c];
  if (mapped !== undefined) return { out: mapped, next: i + 2 };

  const take = (from: number, max: number, re: RegExp): string => {
    let s = "";
    while (s.length < max && from + s.length < text.length && re.test(text[from + s.length] as string)) {
      s += text[from + s.length] as string;
    }
    return s;
  };
  // Bash's numeric and control escapes name a BYTE, not a code point: `\777`
  // is 0xff and `\400` wraps to NUL. Masking keeps this decoder byte-faithful
  // instead of minting U+01FF, which would encode as two bytes bash never
  // produces.
  const byte = (value: number): string => String.fromCharCode(value & 0xff);

  if (c === "x") {
    const digits = take(i + 2, 2, /[0-9a-fA-F]/);
    if (digits !== "") return { out: byte(parseInt(digits, 16)), next: i + 2 + digits.length };
  }
  if (c === "u" || c === "U") {
    const digits = take(i + 2, c === "u" ? 4 : 8, /[0-9a-fA-F]/);
    if (digits !== "") {
      const code = parseInt(digits, 16);
      // Bash DROPS an out-of-Unicode-range code point, producing nothing, and
      // `String.fromCodePoint` would throw on it. Emitting the literal
      // spelling instead would be a bypass, not a safe fallback:
      // `$'iss\UFFFFFFFFue'` is exactly `issue` to bash, so anything but an
      // empty string here loses the route.
      return {
        out: code <= 0x10ffff ? String.fromCodePoint(code) : "",
        next: i + 2 + digits.length,
      };
    }
  }
  if (c >= "0" && c <= "7") {
    const digits = take(i + 1, 3, /[0-7]/);
    return { out: byte(parseInt(digits, 8)), next: i + 1 + digits.length };
  }
  if (c === "c") {
    const target = text[i + 2];
    // NEVER consume the span's closing quote as a control target. `\c` is the
    // only escape whose target can be any character, so it is the only one
    // that could swallow a `'` and leave `toArgv` inside a quote that
    // `splitCommand` already closed - the exact two-machine desync invariant 3
    // warns about, and one `splitCommand` would report as parseable.
    if (target !== undefined && target !== "'") {
      return { out: byte(target.toUpperCase().charCodeAt(0) ^ 0x40), next: i + 3 };
    }
  }
  // Unrecognised: bash keeps the backslash.
  return { out: `\\${c}`, next: i + 2 };
}

/**
 * Split one simple command into argv, stripping one level of quoting.
 *
 * This is the SECOND of the tokenizer's two quote state machines; the first
 * is `splitCommand`. They are independent and must stay in lockstep — see
 * invariant 3 on `splitCommand`. Backslash is bash-asymmetric here too: an
 * escape inside `"…"` and `$'…'`, an ordinary literal inside `'…'`.
 */
export function toArgv(text: string): string[] {
  const argv: string[] = [];
  let token = "";
  let started = false;
  let quote: '"' | "'" | "$'" | null = null;

  // Bash cannot hold a NUL in an argv word: it truncates the word there. A
  // decoder that keeps the tail would build `issue\0…` where bash built
  // `issue`, and the positional compare in `cliIsIssueWrite` would miss the
  // route entirely. Truncating at flush keeps the word present but ends it
  // where bash ends it.
  const flush = () => {
    if (started) argv.push(token.split("\0")[0] as string);
    token = "";
    started = false;
  };

  for (let i = 0; i < text.length; i += 1) {
    const c = text[i] as string;
    if (quote) {
      if (quote === "$'") {
        if (c === "\\" && i + 1 < text.length) {
          const { out, next } = decodeAnsiCEscape(text, i);
          token += out;
          started = true;
          i = next - 1;
          continue;
        }
        if (c === "'") {
          quote = null;
          continue;
        }
        token += c;
        started = true;
        continue;
      }
      if (c === "\\" && quote === '"' && i + 1 < text.length) {
        // Line continuation: bash removes the pair rather than emitting the
        // newline.
        if (text[i + 1] !== "\n") token += text[i + 1];
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
      // Line continuation, unquoted: the pair vanishes and the word continues
      // across the break. Emitting a real newline here would split `issue`
      // into `\nissue` and lose the route.
      if (text[i + 1] !== "\n") {
        token += text[i + 1];
        started = true;
      }
      i += 1;
      continue;
    }

    // ANSI-C `$'...'` quoting. Escapes inside the span are DECODED (see
    // decodeAnsiCEscape): the argv this produces feeds route classification,
    // and bash resolves `$'\x69ssue'` to `issue`, so anything less lets an
    // encoded subcommand slip past `cliIsIssueWrite`.
    if (c === "$" && text[i + 1] === "'") {
      quote = "$'";
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
    // THIS is where command substitution is excluded — not `splitCommand`,
    // which deliberately does not detect `$(…)` or backticks. `opaque` routes
    // the whole classification to `fallbackScan`, so the boundary lives here
    // and nowhere else: `gh issue create --title $(cat x)`.
    if (t.includes("$(") || t.includes("`")) {
      return { head: null, rest: [], envHost, opaque: true };
    }
    // Strip a path prefix: /usr/bin/gh -> gh
    const base = t.slice(t.lastIndexOf("/") + 1);
    return { head: base, rest: argv.slice(i + 1), envHost, opaque: false };
  }
  return { head: null, rest: [], envHost, opaque: false };
}

/** One flag occurrence, in argv order. Repeats are kept: pflag is last-wins. */
type ParsedArgs = { positionals: string[]; flags: { name: string; value: string }[] };

/**
 * One consumption-aware pass over an argv, modelling cobra/pflag and the
 * shells: `--name value`, `--name=value`, `-N value`, `-N=value`, `-Nvalue`,
 * and a clustered short group where the FIRST value-taking letter takes the
 * rest of the group — or the next word when the group ends there. Everything
 * after a bare `--` is positional.
 *
 * One pass, deliberately, because two independent readers is how this guard
 * leaked. A token consumed here as a value can never also be read as a flag or
 * as a positional, which is the invariant three separate bypasses violated:
 * `gh api -iX POST …` lost its endpoint to the positional stream,
 * `gh api -XPATCH …` lost it to a last-character rule that disagreed with the
 * value lookup, and `gh issue create --title -Revil/x` had the title's own
 * value read back as a `-R` and aimed the probe at the attacker's repository.
 *
 * `valueFlags` is therefore not a detail: a value-taking flag missing from it
 * turns that flag's value into a positional, which shifts the API path or the
 * subcommand pair and drops the write.
 */
function parseArgs(argv: string[], valueFlags: string[]): ParsedArgs {
  const positionals: string[] = [];
  const flags: { name: string; value: string }[] = [];
  let endOfFlags = false;
  for (let i = 0; i < argv.length; i += 1) {
    const t = argv[i] as string;
    if (endOfFlags || t === "-" || !t.startsWith("-")) {
      positionals.push(t);
      continue;
    }
    if (t === "--") {
      endOfFlags = true;
      continue;
    }
    if (t.startsWith("--")) {
      const eq = t.indexOf("=");
      if (eq > 0) {
        flags.push({ name: t.slice(0, eq), value: t.slice(eq + 1) });
        continue;
      }
      if (!valueFlags.includes(t)) continue; // boolean long flag
      const next = argv[i + 1];
      if (next !== undefined) {
        flags.push({ name: t, value: next });
        i += 1;
      }
      continue;
    }
    // Short group: booleans until the first value-taking letter, which then
    // swallows whatever is left of the group.
    const letters = t.slice(1);
    let at = -1;
    for (let k = 0; k < letters.length; k += 1) {
      const ch = letters[k] as string;
      if (valueFlags.includes(`-${ch}`)) {
        at = k;
        break;
      }
      if (!/[A-Za-z]/.test(ch)) break;
    }
    if (at === -1) continue; // all boolean, or a shape this set does not model
    const name = `-${letters[at] as string}`;
    const attached = letters.slice(at + 1);
    if (attached !== "") {
      flags.push({ name, value: attached.startsWith("=") ? attached.slice(1) : attached });
      continue;
    }
    const next = argv[i + 1];
    if (next !== undefined) {
      flags.push({ name, value: next });
      i += 1;
    }
  }
  return { positionals, flags };
}

/**
 * The value cobra/pflag would resolve for any of `names`. Last-wins, because
 * that is what the real CLIs do: `gh issue create --repo mine/ok --repo
 * victim/x` writes to `victim/x`, and reading the first would hand the probe a
 * decoy the caller controls.
 */
function lastValue(parsed: ParsedArgs, names: string[]): string | null {
  let out: string | null = null;
  for (const flag of parsed.flags) if (names.includes(flag.name)) out = flag.value;
  return out;
}

/**
 * Value-taking flags of `gh api` / `glab api`, applied only after the `api`
 * subcommand is found. Any omission shifts the endpoint onto the flag's value
 * and the write stops being recognised, so this list tracks the real CLIs
 * (`gh api --help`, `glab api --help`). Short/long spellings are listed
 * independently rather than paired, because the two CLIs disagree on which
 * letter carries which name.
 */
const API_VALUE_FLAGS = [
  "-X",
  "--method",
  "-H",
  "--header",
  "-f",
  "-F",
  "--field",
  "--raw-field",
  "--form",
  "-q",
  "--jq",
  "-t",
  "--template",
  "-p",
  "--preview",
  "--cache",
  "--input",
  "--output",
  "--hostname",
  "--per-page",
];

/**
 * Value-taking flags of a `gh`/`glab` NON-api invocation (R16). Two jobs, and
 * both are load-bearing. `-R`/`--repo`/`--hostname` are persistent flags that
 * may precede the SUBCOMMAND, so omitting them made `glab -R g/p issue create`
 * read `g/p` as the subcommand and miss the write. The `issue create` value
 * flags are here so their values are consumed rather than re-read as flags:
 * without `-t`, `gh issue create --title -Revil/x` handed the probe the
 * repository named in the title instead of the one being written to.
 */
const CLI_VALUE_FLAGS = [
  "-R",
  "--repo",
  "--hostname",
  "-t",
  "--title",
  "-b",
  "--body",
  "-F",
  "--body-file",
  "-d",
  "--description",
  "-l",
  "--label",
  "-a",
  "--assignee",
  "-m",
  "--milestone",
  "-p",
  "--project",
  "--template",
];

/** Arguments after the `api` subcommand, so the subcommand is not read as the path. */
function apiArgs(rest: string[]): string[] {
  const at = rest.indexOf("api");
  return at === -1 ? rest : rest.slice(at + 1);
}

/**
 * Every positional is checked, not just the first. A short group whose
 * value-taking letter is not last leaves a leftover word ahead of the endpoint
 * (`gh api -qq .id repos/o/r/issues` really does pass `.id` positionally), and
 * reading only the first would drop the write.
 */
function apiPathIsIssueWrite(parsed: ParsedArgs): boolean {
  const method = lastValue(parsed, ["-X", "--method"]);
  if (!method || WRITE_METHODS[method.toUpperCase()] !== true) return false;
  return parsed.positionals.some((path) => {
    const clean = (path.split("?")[0] ?? "").replace(/^\/+/, "");
    return clean.split("/").some((seg) => ISSUE_PATH_SEGMENTS[seg.toLowerCase()] === true);
  });
}

function repoFromApiPath(parsed: ParsedArgs, cli: "gh" | "glab"): string | null {
  for (const path of parsed.positionals) {
    if (path === "") continue;
    const segs = (path.split("?")[0] ?? "").replace(/^\/+/, "").split("/");
    if (cli === "gh") {
      const at = segs.indexOf("repos");
      if (at >= 0 && segs[at + 1] && segs[at + 2]) return `${segs[at + 1]}/${segs[at + 2]}`;
      continue;
    }
    const at = segs.indexOf("projects");
    if (at < 0 || segs[at + 1] === undefined) continue;
    try {
      return decodeURIComponent(segs[at + 1] as string);
    } catch {
      return segs[at + 1] as string;
    }
  }
  return null;
}

/**
 * Does this `gh`/`glab` invocation describe an issue write? `parsed` is the
 * single consumption-aware pass over `rest`; reading `rest` minus every flag
 * token kept each value-taking flag's value and shifted the pair (R16).
 */
function cliIsIssueWrite(parsed: ParsedArgs, rest: string[]): boolean {
  const [subcommand, verb] = parsed.positionals;
  if (subcommand === "api") return apiPathIsIssueWrite(parseArgs(apiArgs(rest), API_VALUE_FLAGS));
  // `pr`/`mr` verbs are out of scope (R7), and `issue update` is the
  // self-assignment carve-out (R6); both fall through to false.
  if (subcommand !== "issue") return false;
  return verb === "create" || verb === "comment" || verb === "note";
}

/** A `cd` target this classifier can resolve literally, or `null` if it cannot. */
function literalCdTarget(rest: string[]): string | null {
  const target = parseArgs(rest, []).positionals[0] ?? null;
  if (target === null) return null; // bare `cd` goes $HOME; not resolvable here
  if (target === "-" || target.includes("$") || target.includes("`") || target.startsWith("~")) {
    return null;
  }
  return target;
}

/**
 * The argv that names `gh`/`glab`, or `null`. Token-level on purpose (R13,
 * R15): a quoted prose mention is ONE token whose basename is not `gh`, so
 * `echo "run gh issue create later"` stays ignored while `xargs gh issue
 * create` does not. A word-boundary scan of the raw text would flip both.
 *
 * Returns the NESTED argv when the match came from a wrapper forwarding a
 * whole command line as one word (`watch 'gh issue create …'`), so the caller
 * reads the target from the same tokens bash would.
 */
function cliMention(argv: string[]): string[] | null {
  for (const raw of argv) {
    const t = raw.replace(/^[({]+/, "").replace(/[)};]+$/, "");
    const base = t.slice(t.lastIndexOf("/") + 1);
    if (base === "gh" || base === "glab") return argv;
    // A whitespace-bearing token is a forwarded command LINE, not prose:
    // `watch 'gh issue create'` counts, `echo "run gh issue create later"`
    // does not, because only the first names gh as its head. Resolve it the
    // same way a real segment is resolved — split into simple commands, then
    // through `argvHead` — so a leading `cd`, `sudo`, or `VAR=x` inside the
    // forwarded line cannot hide it (`watch 'cd repo && gh issue create'`).
    if (!/\s/.test(t)) continue;
    for (const nested of splitCommand(t).segments) {
      const inner = toArgv(nested.text);
      const innerHead = argvHead(inner).head;
      if (innerHead === "gh" || innerHead === "glab") return inner;
    }
  }
  return null;
}

/**
 * Bash re-parses interpreter stdin, so a here-string word whose decoded value
 * carries whitespace is a command LINE, not one argument:
 * `bash <<< $'gh\x20issue\x20create'` runs `gh`. Returns the decoded text when
 * that second pass is needed, else `null` (R14).
 */
function expandedBody(body: string): string | null {
  const argv = toArgv(body);
  if (argv.length !== 1) return null;
  const only = argv[0] as string;
  if (only === body || !/\s/.test(only)) return null;
  return only;
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

    // Interpreter stdin and `-c`/`-e` payloads carry executable text, always:
    // recurse. A body attached to a gh/glab segment is inert issue data and is
    // never scanned, because that segment already classifies by its subcommand.
    // `parseArgs` resolves the combined-group form too (`sh -lc CMD`), so no
    // separate shell table is needed here.
    if (INTERPRETERS[head] === true) {
      // Every code payload is scanned, not just the last: `bash -c A -c B`
      // runs `A`, so a last-wins read would skip the command that executes.
      const codeFlags = INTERPRETER_CODE_FLAGS[head];
      const payloads = [...segment.bodies];
      if (codeFlags !== undefined) {
        for (const flag of parseArgs(rest, codeFlags).flags) {
          if (codeFlags.includes(flag.name)) payloads.push(flag.value);
        }
      }
      for (const payload of payloads) {
        // Decoded first: it is strictly more informative when it exists, and
        // scanning the raw word first would settle for a fallbackScan verdict
        // that loses the repo.
        for (const text of [expandedBody(payload), payload]) {
          if (text === null) continue;
          const inner = classifyBash(text);
          if (inner.kind === "issue-write") {
            return {
              ...inner,
              cdTarget: inner.cdTarget ?? cdTarget,
              // The payload's own cwd uncertainty must survive the merge:
              // `bash -c 'cd "$D" && gh issue create'` is not resolvable, and
              // overwriting this with the outer value produced `repo: null`
              // with `cwdUnresolvable: false` — the state that makes the
              // caller trust the current checkout's origin.
              cwdUnresolvable: cwdUnresolvable || inner.cwdUnresolvable,
            };
          }
        }
      }
      // Nothing classified: fall through to the fail-closed check below, so an
      // interpreter flag this table does not model still cannot hide a write.
    } else if (head === "gh" || head === "glab") {
      const parsed = parseArgs(rest, CLI_VALUE_FLAGS);
      if (cliIsIssueWrite(parsed, rest)) {
        const repo =
          lastValue(parsed, ["--repo", "-R"]) ??
          (parsed.positionals[0] === "api"
            ? repoFromApiPath(parseArgs(apiArgs(rest), API_VALUE_FLAGS), head)
            : null);
        const host = envHost ?? lastValue(parsed, ["--hostname"]);
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
      // A recognised gh/glab read is definitively not a write. Never fail
      // closed here, or every `gh issue list` becomes a probe candidate.
      continue;
    }

    // R13/R15: an unrecognised head — an argv-forwarding wrapper (`xargs`,
    // `timeout`, `nice`, `stdbuf`, `setsid`, `parallel`, `watch`, …) or a
    // recognised prefix's own option (`env -C`, `sudo -u`, which leave
    // `argvHead` returning a flag) — must not silently drop a segment that
    // still names gh/glab. One fail-closed rule closes both classes, so
    // `argvHead` deliberately keeps no per-prefix option grammar and no
    // wrapper denylist. Cost, accepted: more false candidates reach the probe,
    // which allows them whenever the repository is managed.
    const mention = cliMention(argv);
    if (mention === null) continue;
    // Scan the DECODED argv, rejoined — not `segment.text`. Two reasons, and
    // both are bypasses if ignored. Segment-scoped, because a whole-command
    // scan would pick up `gh` + `issue` from the READ half of
    // `gh issue view 3 | grep gh`. Decoded, because the mention test matched
    // argv while `fallbackScan` matches text: `xargs $'\x67h' issue create`
    // holds no literal `gh` for its regex, so scanning the raw text would let
    // the mention this branch just proved slip straight back out. Rejoining is
    // safe only because `cliMention` gated it — prose never reaches this line.
    const scanned = fallbackScan(mention.join(" "));
    if (scanned.kind !== "issue-write") continue;
    // Take the target from a consumption-aware parse of the decoded tokens,
    // never from `fallbackScan`'s regex. `fallbackScan` cannot tell a real
    // `--repo` from one that is some other flag's value, so it reads
    // `--title "--repo evil/x"` and `--title -Revil/x` as targets and aims the
    // probe at a repository the caller merely named. `fallbackScan` stays the
    // route detector; the target comes from here.
    const parsed = parseArgs(mention, CLI_VALUE_FLAGS);
    const repo = lastValue(parsed, ["--repo", "-R"]);
    return {
      ...scanned,
      repo,
      host: envHost ?? lastValue(parsed, ["--hostname"]),
      cdTarget,
      // No resolvable target means no assumption. `repo: null` with the cwd
      // marked unresolvable is the conservative state, not a silent guess.
      cwdUnresolvable: cwdUnresolvable || repo === null,
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
