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

const WRAPPERS: Record<string, true> = {
  env: true,
  command: true,
  exec: true,
  sudo: true,
  doas: true,
  nice: true,
  time: true,
  xargs: true,
  nohup: true,
  timeout: true,
  stdbuf: true,
  setsid: true,
};

const SHELLS: Record<string, true> = {
  bash: true,
  sh: true,
  zsh: true,
};

/** Flags known to take a following separate argument for common wrappers */
const WRAPPER_OPTION_WITH_ARG: Record<string, Record<string, true>> = {
  timeout: { "-s": true, "-k": true, "--signal": true, "--kill-after": true },
  sudo: { "-u": true, "-g": true, "-h": true, "-p": true, "-r": true, "-t": true, "-C": true },
  doas: { "-u": true, "-C": true },
  nice: { "-n": true },
  stdbuf: { "-i": true, "-o": true, "-e": true },
};

function isShellFlagWithC(flag: string): boolean {
  return flag.startsWith("-") && !flag.startsWith("--") && flag.slice(1).includes("c");
}

interface SegmentRaw {
  text: string;
}

/**
 * Split command line into segments on ; && || | & newline (
 * only outside single quotes, double quotes, and backslash escapes.
 * Bare ( opens a subshell and segments; $( is command substitution and stays together.
 * Returns null if quotes are unmatched or escape is dangling.
 */
function splitSegments(input: string): SegmentRaw[] | null {
  const segments: SegmentRaw[] = [];
  let current = "";
  let inSingle = false;
  let inDouble = false;
  let escaped = false;

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
        if (current.trim().length > 0) {
          segments.push({ text: current });
        }
        current = "";
        continue;
      }

      // Bare ( is a subshell boundary; $( is command substitution and remains intact
      if (char === "(") {
        if (i > 0 && input[i - 1] === "$") {
          current += char;
          continue;
        }
        if (current.trim().length > 0) {
          segments.push({ text: current });
        }
        current = "";
        continue;
      }

      if (char === "&") {
        if (input[i + 1] === "&") {
          if (current.trim().length > 0) {
            segments.push({ text: current });
          }
          current = "";
          i++;
          continue;
        }
        if (current.trim().length > 0) {
          segments.push({ text: current });
        }
        current = "";
        continue;
      }

      if (char === "|") {
        if (input[i + 1] === "|") {
          if (current.trim().length > 0) {
            segments.push({ text: current });
          }
          current = "";
          i++;
          continue;
        }
        if (current.trim().length > 0) {
          segments.push({ text: current });
        }
        current = "";
        continue;
      }
    }

    current += char;
  }

  if (inSingle || inDouble || escaped) {
    return null;
  }

  if (current.trim().length > 0) {
    segments.push({ text: current });
  }

  return segments;
}

/**
 * Tokenize a single segment into words, stripping outer quotes from tokens.
 * Returns null if the segment contains unresolvable constructs ($(, `, ${).
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
      if (char === "`") {
        return null;
      }
      if (char === "$" && (segmentText[i + 1] === "(" || segmentText[i + 1] === "{")) {
        return null;
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

function scanSegmentTokens(tokens: string[]): Invocation[] {
  let idx = 0;

  // 1. Skip leading NAME=VALUE tokens
  while (idx < tokens.length && /^[A-Za-z_][A-Za-z0-9_]*=/.test(tokens[idx]!)) {
    idx++;
  }

  // 2. While the next token is a wrapper, skip it and its flags, then skip assignments
  while (idx < tokens.length) {
    const rawToken = tokens[idx]!;
    const name = basename(rawToken);

    if (WRAPPERS[name] !== true) {
      break;
    }

    idx++;

    const flagArgTable = WRAPPER_OPTION_WITH_ARG[name];

    // Skip option flags and their arguments
    while (idx < tokens.length && tokens[idx]!.startsWith("-")) {
      const flag = tokens[idx]!;
      idx++;
      if (flagArgTable?.[flag] === true && idx < tokens.length) {
        idx++;
      }
    }

    // timeout takes a duration argument; skip a bare non-flag token that follows it
    if (name === "timeout" && idx < tokens.length && !tokens[idx]!.startsWith("-")) {
      idx++;
    }

    // Skip assignments again
    while (idx < tokens.length && /^[A-Za-z_][A-Za-z0-9_]*=/.test(tokens[idx]!)) {
      idx++;
    }
  }

  if (idx >= tokens.length) {
    return [];
  }

  const token = tokens[idx]!;
  const progName = basename(token);

  // 3. Shell wrapper check: bash, sh, zsh with -c flag
  if (SHELLS[progName] === true) {
    for (let j = idx + 1; j < tokens.length; j++) {
      const candidate = tokens[j]!;
      if (isShellFlagWithC(candidate)) {
        const subCommand = tokens[j + 1];
        if (subCommand !== undefined) {
          return scanInvocations(subCommand);
        }
        return [];
      }
    }
  }

  // 4. Otherwise program is basename of token; next is following non-flag token
  let nextToken: string | undefined;
  for (let j = idx + 1; j < tokens.length; j++) {
    const candidate = tokens[j]!;
    if (!candidate.startsWith("-")) {
      nextToken = candidate;
      break;
    }
  }

  return [{ program: progName, next: nextToken, args: tokens.slice(idx + 1) }];
}

export function scanInvocations(command: string | readonly string[]): Invocation[] {
  if (typeof command !== "string") {
    if (command.length === 0) {
      return [];
    }

    const first = command[0]!;
    const firstProg = basename(first);

    if (SHELLS[firstProg] === true) {
      for (let i = 1; i < command.length; i++) {
        const arg = command[i]!;
        if (isShellFlagWithC(arg)) {
          const subCommand = command[i + 1];
          if (subCommand !== undefined) {
            return scanInvocations(subCommand);
          }
          return [];
        }
      }
    }

    let nextToken: string | undefined;
    for (let i = 1; i < command.length; i++) {
      const arg = command[i]!;
      if (!arg.startsWith("-")) {
        nextToken = arg;
        break;
      }
    }

    return [{ program: firstProg, next: nextToken, args: command.slice(1) }];
  }

  const segments = splitSegments(command);
  if (segments === null) {
    return [];
  }

  const results: Invocation[] = [];
  for (const seg of segments) {
    const tokens = tokenizeSegment(seg.text);
    if (tokens === null) {
      continue;
    }
    const invocations = scanSegmentTokens(tokens);
    results.push(...invocations);
  }

  return results;
}
