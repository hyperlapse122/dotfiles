import { basename } from "node:path";

export interface Invocation {
  /** basename of the program token */
  program: string;
  /** the first following token that is not an option flag, or undefined */
  next: string | undefined;
  /**
   * Every token after the program, flags included.
   *
   * `next` skips flags, which is what a subcommand check wants. The launch
   * check needs the opposite: `claude --version` and a bare `claude` both have
   * no subcommand, and only the flags separate them.
   */
  args: readonly string[];
}

/** Commands that run another command, so the program is further along. */
const WRAPPERS: ReadonlySet<string> = new Set([
  "env",
  "command",
  "exec",
  "sudo",
  "doas",
  "nice",
  "time",
  "xargs",
  "nohup",
  "timeout",
  "stdbuf",
  "setsid",
]);

const SHELLS: ReadonlySet<string> = new Set(["bash", "sh", "zsh"]);

/**
 * Shell grammar words that precede a command rather than being one.
 *
 * Without these, `{ codex exec; }` scans `{` as the program and allows, and so
 * do `if true; then codex exec; fi` and every loop body. They are syntax, not
 * executables, so stepping over them is what makes the program the thing that
 * actually runs.
 */
const SHELL_KEYWORDS: ReadonlySet<string> = new Set([
  "{",
  "}",
  "(",
  ")",
  "!",
  "if",
  "then",
  "elif",
  "else",
  "fi",
  "for",
  "while",
  "until",
  "do",
  "done",
  "case",
  "esac",
  "in",
  "select",
  "function",
  "coproc",
]);

/**
 * Redirections are plumbing, not arguments.
 *
 * `codex --version > /tmp/v` must stay allowed: leaving `>` in the token stream
 * makes it read as the subcommand, and a version probe gets denied.
 */
const REDIRECTION = /^\d*(?:>>?|<<?|&>|>&|<>)/;

/** Drop redirection operators and the targets that belong to them. */
function stripRedirections(tokens: readonly string[]): string[] {
  const kept: string[] = [];
  for (let i = 0; i < tokens.length; i++) {
    const token = tokens[i]!;
    if (!REDIRECTION.test(token)) {
      kept.push(token);
      continue;
    }
    // A bare operator takes the next token as its target; `2>&1` and `>file`
    // already carry theirs.
    if (/^\d*(?:>>?|<<?|&>|>&|<>)$/.test(token)) i++;
  }
  return kept;
}

/** Wrapper flags that consume a following separate argument. */
const WRAPPER_OPTION_WITH_ARG: Record<string, ReadonlySet<string>> = {
  timeout: new Set(["-s", "--signal", "-k", "--kill-after"]),
  sudo: new Set([
    "-u",
    "--user",
    "-g",
    "--group",
    "-h",
    "--host",
    "-p",
    "--prompt",
    "-r",
    "--role",
    "-t",
    "--type",
    "-C",
    "--close-from",
    "-D",
    "--chdir",
    "-R",
    "--chroot",
  ]),
  doas: new Set(["-u", "-C"]),
  nice: new Set(["-n", "--adjustment"]),
  stdbuf: new Set(["-i", "--input", "-o", "--output", "-e", "--error"]),
  // Without these the flag's VALUE is read as the program: `env -u FOO codex`
  // stops at FOO and never sees codex.
  env: new Set(["-u", "--unset", "-C", "--chdir"]),
  xargs: new Set([
    "-n",
    "--max-args",
    "-I",
    "--replace",
    "-L",
    "--max-lines",
    "-s",
    "--max-chars",
    "-d",
    "--delimiter",
    "-P",
    "--max-procs",
    "-E",
    "--eof",
    "-a",
    "--arg-file",
  ]),
  exec: new Set(["-a"]),
};

/** A leading `NAME=VALUE` token, which sets the environment rather than naming the program. */
const ENV_ASSIGNMENT = /^[A-Za-z_][A-Za-z0-9_]*=/;

/** The first token that is not an option flag, which is where a subcommand sits. */
function firstNonFlag(tokens: readonly string[]): string | undefined {
  return tokens.find((token) => !token.startsWith("-"));
}

/**
 * The invocation a shell wrapper's `-c` argument describes, or null when this
 * is not a shell wrapper.
 *
 * Shared by the string and argv paths: both have to look past `bash -lc` the
 * same way, and two copies of that rule drift apart exactly where a missed
 * unwrap becomes a missed launch.
 */
function scanShellDashC(program: string, rest: readonly string[]): Invocation[] | null {
  if (!SHELLS.has(program)) return null;
  const flagIndex = rest.findIndex(isShellFlagWithC);
  if (flagIndex < 0) return null;
  const inner = rest[flagIndex + 1];
  return inner === undefined ? [] : scanInvocations(inner);
}

/**
 * The command string an `env -S` / `--split-string` option carries, or null.
 *
 * Accepts `-S x`, `-Sx`, `--split-string x` and `--split-string=x`.
 */
function splitStringArgument(tokens: readonly string[], idx: number): string | null {
  const token = tokens[idx];
  if (token === undefined) return null;
  if (token === "-S" || token === "--split-string") return tokens[idx + 1] ?? null;
  if (token.startsWith("--split-string=")) return token.slice("--split-string=".length);
  if (token.startsWith("-S") && token.length > 2) return token.slice(2);
  return null;
}

function isShellFlagWithC(flag: string): boolean {
  return flag.startsWith("-") && !flag.startsWith("--") && flag.slice(1).includes("c");
}

/**
 * The delimiter of the last `<<`/`<<-` redirection on this line, or null.
 *
 * The redirection is found anywhere on the line, not only at its end: a
 * heredoc can be followed by a pipeline, a comment, or another redirection,
 * and anchoring at the end would miss the opener and then scan the body.
 * A delimiter is a shell word, so it may carry punctuation such as `PATCH-1`;
 * `<<<` is a here-string, which takes no body.
 */
function heredocDelimiter(current: string): string | null {
  const opener = /(?<!<)<<(?!<)(-?)\s*(?:'([^']*)'|"([^"]*)"|([^\s;|&()<>'"]+))/g;
  let delimiter: string | null = null;
  for (let m = opener.exec(current); m !== null; m = opener.exec(current)) {
    delimiter = m[2] ?? m[3] ?? m[4] ?? null;
  }
  return delimiter;
}

/**
 * Index of the character before the newline that closes the heredoc body.
 *
 * Every line is tested, starting with the first: a body can be empty, and
 * leaving its terminator untested would keep the scan inside the heredoc and
 * swallow whatever follows — a launch included.
 *
 * Index arithmetic rather than slicing the remainder: a patch body is as long
 * as the file it edits, and re-copying the tail at each of its newlines would
 * make this per-tool-call scan quadratic.
 */
function heredocBodyEnd(input: string, from: number, delimiter: string): number {
  let lineStart = from;
  for (;;) {
    const newline = input.indexOf("\n", lineStart);
    const lineEnd = newline === -1 ? input.length : newline;
    if (input.slice(lineStart, lineEnd).trim() === delimiter) return lineEnd - 1;
    // Unterminated: the shell would reject this too, and there is nothing after
    // the body to hide.
    if (newline === -1) return input.length;
    lineStart = newline + 1;
  }
}

/**
 * Split command line into segments on ; && || | & newline (
 * only outside single quotes, double quotes, and backslash escapes.
 * Bare ( opens a subshell and segments; $( is command substitution and stays together.
 * Returns null if quotes are unmatched or escape is dangling.
 *
 * A heredoc body is data the shell hands to a program, never commands it runs,
 * so the body is skipped between the opening delimiter and its terminator. File
 * editing tools deliver a patch this way, and a patch is full of text that
 * parses as shell: a TypeScript union like `"claude" | "codex"` reads as two
 * pipeline stages naming bare programs, which denied the very edits that widen
 * that union. Skipping the body keeps a real launch after the heredoc visible.
 */
function splitSegments(input: string): string[] | null {
  const segments: string[] = [];
  let current = "";
  let inSingle = false;
  let inDouble = false;
  let escaped = false;
  // A heredoc belongs to its LINE, not to the segment that opened it: the body
  // starts after the newline even when a pipeline, a subshell, or another
  // command follows the redirection. Remember an opener seen in any segment of
  // the current line and spend it at that line's end.
  let lineHeredoc: string | null = null;

  /** Close off the current segment, keeping any heredoc it opened. */
  const flush = (): void => {
    lineHeredoc = heredocDelimiter(current) ?? lineHeredoc;
    if (current.trim().length > 0) segments.push(current);
    current = "";
  };

  for (let i = 0; i < input.length; i++) {
    const char = input[i]!;

    if (escaped) {
      current += char;
      escaped = false;
      continue;
    }

    if (char === "\\" && !inSingle) {
      current += char;
      escaped = true;
      continue;
    }

    if (char === "'" && !inDouble) {
      inSingle = !inSingle;
      current += char;
      continue;
    }

    if (char === '"' && !inSingle) {
      inDouble = !inDouble;
      current += char;
      continue;
    }

    if (!inSingle && !inDouble) {
      if (char === "\n" || char === ";") {
        flush();
        if (char === "\n" && lineHeredoc !== null) {
          i = heredocBodyEnd(input, i + 1, lineHeredoc);
        }
        if (char === "\n") lineHeredoc = null;
        continue;
      }

      // Bare ( and ) bound a subshell; $( is command substitution and remains
      // intact. Both sides are boundaries, so punctuation never clings to a
      // token and turn `--version)` into an unrecognized subcommand.
      if (char === "(" || char === ")") {
        if (char === "(" && i > 0 && input[i - 1] === "$") {
          current += char;
          continue;
        }
        flush();
        continue;
      }

      if (char === "&") {
        // `2>&1` and `>&2` are one redirection, not a background operator.
        if (current.endsWith(">") || current.endsWith("<")) {
          current += char;
          continue;
        }
        if (input[i + 1] === "&") {
          flush();
          i++;
          continue;
        }
        flush();
        continue;
      }

      if (char === "|") {
        if (input[i + 1] === "|") {
          flush();
          i++;
          continue;
        }
        flush();
        continue;
      }
    }

    current += char;
  }

  if (inSingle || inDouble || escaped) {
    return null;
  }

  if (current.trim().length > 0) {
    segments.push(current);
  }

  return segments;
}

/**
 * Tokenize a single segment into words, stripping outer quotes from tokens.
 *
 * An unresolvable construct ($(, `, ${) names something this scanner cannot
 * resolve. Where it sits decides what that means. BEFORE the program token, the
 * program itself is unknown and the segment yields nothing — R9 allows. AFTER
 * it, the program is already known and only an argument is opaque, so the
 * tokens gathered so far are returned; dropping them there let
 * `codex exec $(date)` through.
 */
function tokenizeSegment(segmentText: string): string[] | null {
  const tokens: string[] = [];
  let currentToken = "";
  let inSingle = false;
  let inDouble = false;
  let escaped = false;
  let inToken = false;

  for (let i = 0; i < segmentText.length; i++) {
    const char = segmentText[i]!;

    if (escaped) {
      currentToken += char;
      escaped = false;
      inToken = true;
      continue;
    }

    if (char === "\\" && !inSingle) {
      escaped = true;
      inToken = true;
      continue;
    }

    if (char === "'" && !inDouble) {
      inSingle = !inSingle;
      inToken = true;
      continue;
    }

    if (char === '"' && !inSingle) {
      inDouble = !inDouble;
      inToken = true;
      continue;
    }

    if (!inSingle) {
      const unresolvable =
        char === "`" ||
        (char === "$" && (segmentText[i + 1] === "(" || segmentText[i + 1] === "{"));
      if (unresolvable) {
        if (inToken) tokens.push(currentToken);
        return tokens.length > 0 ? tokens : null;
      }
    }

    if (!inSingle && !inDouble && /\s/.test(char)) {
      if (inToken) {
        tokens.push(currentToken);
        currentToken = "";
        inToken = false;
      }
      continue;
    }

    currentToken += char;
    inToken = true;
  }

  if (inToken) {
    tokens.push(currentToken);
  }

  return tokens;
}

function scanSegmentTokens(rawTokens: readonly string[]): Invocation[] {
  const tokens = stripRedirections(rawTokens);
  let idx = 0;

  // 1. Skip leading NAME=VALUE tokens
  while (idx < tokens.length && ENV_ASSIGNMENT.test(tokens[idx]!)) {
    idx++;
  }

  // 2. Step over shell grammar words and wrappers until a real program is next.
  while (idx < tokens.length) {
    const rawToken = tokens[idx]!;

    if (SHELL_KEYWORDS.has(rawToken)) {
      idx++;
      while (idx < tokens.length && ENV_ASSIGNMENT.test(tokens[idx]!)) {
        idx++;
      }
      continue;
    }

    const name = basename(rawToken);

    // `eval` runs the string it is handed, so the program is inside it.
    if (name === "eval") {
      const inner = tokens[idx + 1];
      return inner === undefined ? [] : scanInvocations(inner);
    }

    if (!WRAPPERS.has(name)) {
      break;
    }

    idx++;

    // `command -v foo` and `command -V foo` ask where foo is; they never run
    // it. Unwrapping them would make a lookup indistinguishable from a bare
    // launch, and the launch check would deny a presence probe.
    if (name === "command" && tokens[idx] !== undefined && /^-[vV]$/.test(tokens[idx]!)) {
      return [];
    }

    // `env -S "codex exec"` carries the command INSIDE the option's own value,
    // so consuming that value as an opaque argument loses the program entirely.
    // Every spelling GNU env accepts is handled: separate, attached, and
    // `--split-string=`.
    if (name === "env") {
      const split = splitStringArgument(tokens, idx);
      if (split !== null) return scanInvocations(split);
    }

    const flagArgTable = WRAPPER_OPTION_WITH_ARG[name];

    // Skip option flags and their arguments
    while (idx < tokens.length && tokens[idx]!.startsWith("-")) {
      const flag = tokens[idx]!;
      idx++;
      if (flagArgTable?.has(flag) === true && idx < tokens.length) {
        idx++;
      }
    }

    // timeout takes a duration argument; skip a bare non-flag token that follows it
    if (name === "timeout" && idx < tokens.length && !tokens[idx]!.startsWith("-")) {
      idx++;
    }

    // Skip assignments again
    while (idx < tokens.length && ENV_ASSIGNMENT.test(tokens[idx]!)) {
      idx++;
    }
  }

  if (idx >= tokens.length) {
    return [];
  }

  const token = tokens[idx]!;
  const progName = basename(token);

  // 3. Shell wrapper check: bash, sh, zsh with -c flag
  const rest = tokens.slice(idx + 1);
  const viaShell = scanShellDashC(progName, rest);
  if (viaShell !== null) return viaShell;

  // 4. Otherwise program is basename of token; next is following non-flag token
  return [{ program: progName, next: firstNonFlag(rest), args: rest }];
}

export function scanInvocations(command: string | readonly string[]): Invocation[] {
  if (typeof command !== "string") {
    if (command.length === 0) {
      return [];
    }

    // The same walk as a string segment: an argv array carries wrappers,
    // assignments and shell keywords too, and a separate simpler path here let
    // `["env","codex","exec"]` through as the program `env`.
    return scanSegmentTokens(command);
  }

  const segments = splitSegments(command);
  if (segments === null) {
    return [];
  }

  const results: Invocation[] = [];
  for (const seg of segments) {
    const tokens = tokenizeSegment(seg);
    if (tokens === null) {
      continue;
    }
    const invocations = scanSegmentTokens(tokens);
    results.push(...invocations);
  }

  return results;
}
