/**
 * Recognises the scripts a shell tool call runs, so the run stream can show them as
 * their own rows: which script ran, with which parameters, from which directory.
 *
 * A command runs a script when one of its simple commands starts (after `VAR=value`
 * assignments and shell keywords such as `do` or `then`) with a script file — a word
 * ending in a script extension — or with an interpreter (`bash`, `node`, `python3`, ...)
 * whose first operand is one. Here-document bodies are skipped, so a script quoted in a
 * heredoc is not taken for a run. The parse is a reading aid, not a shell: it handles
 * quotes, escapes and the usual separators, and gives up quietly on anything else.
 *
 * It also reads what the run stream shows about a script call: variables set earlier
 * in the command, what kind each parameter is, and the tone of each output line.
 */

/** One script invocation found in a command. */
export interface ScriptRun {
  /** The script path as written, e.g. `scripts/scaffold.sh`. */
  script: string;
  /** The interpreter named before the script, when there was one (`bash`, `node`, ...). */
  interpreter?: string;
  /** Interpreter options before the script, e.g. `-x` in `bash -x run.sh`. */
  interpreterArgs: string[];
  /** The script's parameters, unquoted, in order. */
  args: string[];
  /** `VAR=value` assignments written in front of the invocation. */
  env: Record<string, string>;
  /** The directory the last `cd` before it changed to, when the command has one. */
  cwd?: string;
  /**
   * Shell variables set earlier in the same command (`D=src/test`, `export P=...`) that
   * this run's script, parameters or directory refer to. {@link expandVars} resolves them.
   */
  vars: Record<string, string>;
}

const SCRIPT_EXTENSION = /\.(?:sh|bash|zsh|js|mjs|cjs|ts|mts|py|rb|pl)$/;
const INTERPRETERS = new Set([
  'bash',
  'sh',
  'zsh',
  'dash',
  'node',
  'bun',
  'deno',
  'tsx',
  'ts-node',
  'python',
  'python3',
  'ruby',
  'perl',
]);
/** Words that may precede a command without being it. */
const PREFIX_WORDS = new Set([
  'do',
  'then',
  'else',
  'elif',
  'time',
  'exec',
  'command',
  '!',
  '{',
  '(',
]);
const ASSIGNMENT = /^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/s;

interface Word {
  text: string;
  /** The word had quoting, so it is never an operator or keyword. */
  quoted: boolean;
}

/** Split a command into simple commands, each a list of unquoted words. */
export function splitSimpleCommands(command: string): Word[][] {
  const commands: Word[][] = [];
  let words: Word[] = [];
  let current = '';
  let inWord = false;
  let quoted = false;
  const pendingHeredocs: { tag: string; stripTabs: boolean }[] = [];

  const endWord = (): void => {
    if (inWord) words.push({ text: current, quoted });
    current = '';
    inWord = false;
    quoted = false;
  };
  const endCommand = (): void => {
    endWord();
    if (words.length > 0) commands.push(words);
    words = [];
  };

  let i = 0;
  while (i < command.length) {
    const ch = command[i];

    if (ch === '\n') {
      endCommand();
      i += 1;
      // Skip the bodies of here-documents opened on the line just ended.
      while (pendingHeredocs.length > 0) {
        const doc = pendingHeredocs.shift();
        if (doc === undefined) break;
        while (i < command.length) {
          const lineEnd = command.indexOf('\n', i);
          const line = command.slice(i, lineEnd === -1 ? command.length : lineEnd);
          i = lineEnd === -1 ? command.length : lineEnd + 1;
          if ((doc.stripTabs ? line.replace(/^\t+/, '') : line) === doc.tag) break;
        }
      }
      continue;
    }
    if (ch === "'") {
      const end = command.indexOf("'", i + 1);
      const stop = end === -1 ? command.length : end;
      current += command.slice(i + 1, stop);
      inWord = true;
      quoted = true;
      i = stop + 1;
      continue;
    }
    if (ch === '"') {
      let j = i + 1;
      while (j < command.length && command[j] !== '"') {
        if (command[j] === '\\' && j + 1 < command.length && '"\\$`'.includes(command[j + 1])) {
          current += command[j + 1];
          j += 2;
        } else {
          current += command[j];
          j += 1;
        }
      }
      inWord = true;
      quoted = true;
      i = j + 1;
      continue;
    }
    if (ch === '\\') {
      if (command[i + 1] === '\n') {
        i += 2; // line continuation
        continue;
      }
      if (i + 1 < command.length) {
        current += command[i + 1];
        inWord = true;
        quoted = true;
      }
      i += 2;
      continue;
    }
    if (ch === '$' && command[i + 1] === '(') {
      // Keep a command substitution as part of the word it sits in.
      let depth = 0;
      let j = i + 1;
      for (; j < command.length; j += 1) {
        if (command[j] === '(') depth += 1;
        else if (command[j] === ')') {
          depth -= 1;
          if (depth === 0) break;
        }
      }
      current += command.slice(i, j + 1);
      inWord = true;
      i = j + 1;
      continue;
    }
    if (ch === '&' && (current.endsWith('>') || command[i + 1] === '>')) {
      // `2>&1`, `&>file`: a redirection, not a separator.
      current += ch;
      inWord = true;
      i += 1;
      continue;
    }
    if (ch === '(' || ch === ')') {
      endCommand();
      i += 1;
      continue;
    }
    if (ch === ';' || ch === '&' || ch === '|') {
      endCommand();
      i += command[i + 1] === ch ? 2 : 1;
      continue;
    }
    if (ch === '<' && command[i + 1] === '<' && command[i + 2] !== '<') {
      endWord();
      const match = /^<<(-?)\s*(['"]?)([A-Za-z_][A-Za-z0-9_]*)\2/.exec(command.slice(i));
      if (match !== null) {
        pendingHeredocs.push({ tag: match[3], stripTabs: match[1] === '-' });
        i += match[0].length;
        continue;
      }
      i += 2;
      continue;
    }
    if (ch === ' ' || ch === '\t') {
      endWord();
      i += 1;
      continue;
    }
    if (ch === '#' && !inWord) {
      const lineEnd = command.indexOf('\n', i);
      i = lineEnd === -1 ? command.length : lineEnd;
      continue;
    }
    current += ch;
    inWord = true;
    i += 1;
  }
  endCommand();
  return commands;
}

/** Redirections (`2>&1`, `>out`, `< in`) are not parameters. */
function isRedirection(word: Word): boolean {
  return !word.quoted && /^\d*(?:>>?|<|>&|&>)/.test(word.text);
}

function stripRedirections(words: Word[]): string[] {
  const out: string[] = [];
  for (let i = 0; i < words.length; i += 1) {
    const word = words[i];
    if (isRedirection(word)) {
      // `> file` with the target as its own word.
      if (/^\d*(?:>>?|<|&>)$/.test(word.text)) i += 1;
      continue;
    }
    out.push(word.text);
  }
  return out;
}

function isScriptPath(text: string): boolean {
  return SCRIPT_EXTENSION.test(text) && !text.startsWith('-') && !text.includes('$(');
}

const VAR_REFERENCE = /\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)/g;

/** Replace `$NAME` and `${NAME}` with the values in `vars`; unknown names stay as written. */
export function expandVars(text: string, vars: Readonly<Record<string, string>>): string {
  return text.replace(
    VAR_REFERENCE,
    (whole, braced: string | undefined, bare: string | undefined) => {
      const name = braced ?? bare ?? '';
      return Object.hasOwn(vars, name) ? vars[name] : whole;
    }
  );
}

/** The known variables `texts` refer to. */
function referencedVars(
  texts: readonly (string | undefined)[],
  known: Readonly<Record<string, string>>
): Record<string, string> {
  const used: Record<string, string> = {};
  for (const text of texts) {
    if (text === undefined) continue;
    for (const match of text.matchAll(VAR_REFERENCE)) {
      const name = match[1] ?? match[2];
      if (Object.hasOwn(known, name)) used[name] = known[name];
    }
  }
  return used;
}

/**
 * A simple command that only sets variables (`D=src`, `export A=1 B=2`), as
 * `[name, value]` pairs; null for any other command. A value holding a command
 * substitution is left out: its result is not in the command text.
 */
function assignmentsOnly(words: Word[]): [string, string][] | null {
  const rest = words[0]?.text === 'export' && !words[0].quoted ? words.slice(1) : words;
  if (rest.length === 0) return null;
  const pairs: [string, string][] = [];
  for (const word of rest) {
    const match = ASSIGNMENT.exec(word.text);
    if (match === null) return null;
    if (!match[2].includes('$(') && !match[2].includes('`')) pairs.push([match[1], match[2]]);
  }
  return pairs;
}

function parseSimpleCommand(words: Word[], cwd: string | undefined): ScriptRun | null {
  let i = 0;
  const env: Record<string, string> = {};
  while (i < words.length) {
    const word = words[i];
    if (!word.quoted && PREFIX_WORDS.has(word.text)) {
      i += 1;
      continue;
    }
    if (word.text === 'env' && !word.quoted) {
      i += 1;
      continue;
    }
    const assignment = word.quoted && !word.text.includes('=') ? null : ASSIGNMENT.exec(word.text);
    if (assignment !== null) {
      env[assignment[1]] = assignment[2];
      i += 1;
      continue;
    }
    break;
  }
  const head = words[i];
  if (head === undefined) return null;

  const base = head.text.split('/').pop() ?? head.text;
  if (INTERPRETERS.has(base)) {
    const interpreterArgs: string[] = [];
    let j = i + 1;
    while (j < words.length && words[j].text.startsWith('-') && !isScriptPath(words[j].text)) {
      if (words[j].text === '-' || words[j].text === '-c' || words[j].text === '-e') return null;
      interpreterArgs.push(words[j].text);
      j += 1;
    }
    const target = words[j];
    if (target === undefined || !isScriptPath(target.text)) return null;
    return {
      script: target.text,
      interpreter: base,
      interpreterArgs,
      args: stripRedirections(words.slice(j + 1)),
      env,
      ...(cwd !== undefined ? { cwd } : {}),
      vars: {},
    };
  }
  if (!isScriptPath(head.text)) return null;
  return {
    script: head.text,
    interpreterArgs: [],
    args: stripRedirections(words.slice(i + 1)),
    env,
    ...(cwd !== undefined ? { cwd } : {}),
    vars: {},
  };
}

/** Every script a shell command runs, in order. Empty when it runs none. */
export function findScriptRuns(command: string): ScriptRun[] {
  const runs: ScriptRun[] = [];
  let cwd: string | undefined;
  const known: Record<string, string> = {};
  for (const words of splitSimpleCommands(command)) {
    const first = words.findIndex(w => w.quoted || !PREFIX_WORDS.has(w.text));
    if (first !== -1 && words[first].text === 'cd' && !words[first].quoted) {
      const target = words[first + 1]?.text;
      if (target !== undefined && target !== '-') cwd = target;
      continue;
    }
    const assignments = first === -1 ? null : assignmentsOnly(words.slice(first));
    if (assignments !== null) {
      for (const [name, value] of assignments) known[name] = expandVars(value, known);
      continue;
    }
    const run = parseSimpleCommand(words, cwd);
    if (run !== null) {
      run.vars = referencedVars([run.script, run.cwd, ...run.args], known);
      runs.push(run);
    }
  }
  return runs;
}

/** The scripts a tool call runs, with its shell command; null when it runs none. */
export function scriptCallOf(input: unknown): { command: string; runs: ScriptRun[] } | null {
  const command = shellCommandOf(input);
  if (command === null) return null;
  const runs = findScriptRuns(command);
  return runs.length > 0 ? { command, runs } : null;
}

/** The description a shell tool call was given (`{ description: "..." }`), when it has one. */
export function shellDescriptionOf(input: unknown): string | null {
  if (typeof input !== 'object' || input === null || Array.isArray(input)) return null;
  const description = (input as Record<string, unknown>).description;
  return typeof description === 'string' && description.trim().length > 0
    ? description.trim()
    : null;
}

export type ArgKind = 'flag' | 'json' | 'path' | 'text';

/** How a parameter reads: an option, a JSON document, a file path or plain text. */
export function argKind(arg: string): ArgKind {
  if (/^--?[A-Za-z]/.test(arg)) return 'flag';
  if (prettyJsonParam(arg) !== null) return 'json';
  if (!/\s/.test(arg) && (arg.includes('/') || /\.[A-Za-z0-9]{1,6}$/.test(arg))) return 'path';
  return 'text';
}

const NAME_KEYS = ['name', 'Name', 'id', 'title', 'type'];

function shortValue(value: unknown): string {
  if (typeof value === 'string') return value.length > 32 ? `${value.slice(0, 32)}…` : value;
  if (typeof value === 'number' || typeof value === 'boolean' || value === null) {
    return String(value);
  }
  if (Array.isArray(value)) return `[${value.length.toString()}]`;
  return '{…}';
}

/**
 * A one-line digest of a JSON parameter for the row, naming keys first:
 * `{Name: IdentifierHash, package: app.rekord.identity, +1}`. Null when not JSON.
 */
export function jsonSummary(arg: string, maxEntries = 2): string | null {
  if (prettyJsonParam(arg) === null) return null;
  const parsed: unknown = JSON.parse(arg.trim());
  if (Array.isArray(parsed)) return `[${parsed.length.toString()} items]`;
  if (typeof parsed !== 'object' || parsed === null) return null;
  const entries = Object.entries(parsed as Record<string, unknown>);
  const ranked = [
    ...entries.filter(([key]) => NAME_KEYS.includes(key)),
    ...entries.filter(([key]) => !NAME_KEYS.includes(key)),
  ];
  const shown = ranked.slice(0, maxEntries).map(([key, value]) => `${key}: ${shortValue(value)}`);
  if (ranked.length > maxEntries) shown.push(`+${(ranked.length - maxEntries).toString()}`);
  return `{${shown.join(', ')}}`;
}

/** A parameter as the row shows it: JSON digested, a file path cut to its file name. */
export function argPreview(arg: string): string {
  switch (argKind(arg)) {
    case 'flag':
      return arg;
    case 'json':
      return jsonSummary(arg) ?? arg;
    case 'path': {
      // A file, or a deep directory, reads by its last segment; a short name such as
      // a template id (`domain/value-object`) stays whole.
      const segments = arg.replace(/\/+$/, '').split('/');
      const name = segments.at(-1) ?? '';
      const isFile = /\.[A-Za-z0-9]{1,6}$/.test(name);
      return name.length > 0 && (isFile || segments.length >= 3) ? name : arg;
    }
    case 'text': {
      const shown = arg.length > 40 ? `${arg.slice(0, 40)}…` : arg;
      return /\s/.test(shown) || shown.length === 0 ? `'${shown}'` : shown;
    }
  }
}

/** One run as a row preview: its parameters, resolved and shortened. */
export function runPreview(run: ScriptRun): string {
  return run.args.map(arg => argPreview(expandVars(arg, run.vars))).join(' ');
}

export type LineTone = 'error' | 'warning' | 'success';

export interface OutputLine {
  /** 1-based line number in its stream. */
  number: number;
  text: string;
  tone: LineTone | null;
  /** A leading tag such as `[scaffold]` or `mutation-gate:`, split off `text`'s start. */
  tag: string | null;
}

export interface OutputAnalysis {
  lines: OutputLine[];
  errors: number;
  warnings: number;
}

// A bare lowercase "error" is often prose or help text ("expected | error | throws"),
// so it counts only as a compiler-style `error:` / `error[E…]`.
const ERROR_LINE =
  /\berror(?::|\[)|\bError:|\bERROR\b|\bFAIL(?:ED|URE)?\b|\b[Ff]atal\b|\bSURVIVED\b|\bnot ok\b|^Traceback\b|✗|\bcommand not found\b|\bNo such file or directory\b/;
const WARNING_LINE = /\bWARN(?:ING)?\b|\b[Ww]arning\b|\bdeprecat/i;
const SUCCESS_LINE =
  /\bBUILD SUCCESSFUL\b|\bPASS(?:ED)?\b|✓|(?:^|:\s+)ok\b|\bsucceeded\b|\bsuccess\b|\ball \d+ passed\b|\b0 failed\b/;
const TAG = /^(\[[\w./:-]+\]|[\w./-]+:)(?=\s)/;
/** Words that open a message rather than name its source, so they stay in the text. */
const NOT_A_TAG = /^(?:error|warning|warn|fatal|fail|failed|note|info|hint|caused by):$/i;
const ANSI = /\u001b\[[0-9;?]*[A-Za-z]/g;

/** The tone of one output line, by the words build and test tools print. */
export function lineTone(line: string): LineTone | null {
  if (ERROR_LINE.test(line)) return 'error';
  if (WARNING_LINE.test(line)) return 'warning';
  if (SUCCESS_LINE.test(line)) return 'success';
  return null;
}

/** Split a stream into numbered lines with a tone and leading tag each, counting problems. */
export function analyzeOutput(text: string): OutputAnalysis {
  const clean = text.replace(ANSI, '').replace(/\r\n?/g, '\n').replace(/\n+$/, '');
  if (clean.length === 0) return { lines: [], errors: 0, warnings: 0 };
  let errors = 0;
  let warnings = 0;
  const lines = clean.split('\n').map((raw, index): OutputLine => {
    const tone = lineTone(raw);
    if (tone === 'error') errors += 1;
    else if (tone === 'warning') warnings += 1;
    const match = TAG.exec(raw)?.[1];
    const tag = match === undefined || NOT_A_TAG.test(match) ? null : match;
    return { number: index + 1, text: tag === null ? raw : raw.slice(tag.length), tone, tag };
  });
  return { lines, errors, warnings };
}

/** The shell command of a tool call's input, when it has one (`{ command: "..." }`). */
export function shellCommandOf(input: unknown): string | null {
  if (typeof input !== 'object' || input === null || Array.isArray(input)) return null;
  const command = (input as Record<string, unknown>).command;
  return typeof command === 'string' && command.length > 0 ? command : null;
}

/** A shell tool's result split into its streams. */
export interface ShellOutput {
  stdout: string;
  stderr: string;
  interrupted: boolean;
}

/**
 * Read a shell tool's recorded output. Providers record it either as a JSON object with
 * `stdout`/`stderr` or as the plain text; plain text is all stdout.
 */
export function parseShellOutput(output: string): ShellOutput {
  const trimmed = output.trimStart();
  if (trimmed.startsWith('{')) {
    try {
      const parsed: unknown = JSON.parse(trimmed);
      if (typeof parsed === 'object' && parsed !== null && !Array.isArray(parsed)) {
        const record = parsed as Record<string, unknown>;
        if (typeof record.stdout === 'string' || typeof record.stderr === 'string') {
          return {
            stdout: typeof record.stdout === 'string' ? record.stdout : '',
            stderr: typeof record.stderr === 'string' ? record.stderr : '',
            interrupted: record.interrupted === true,
          };
        }
      }
    } catch {
      // Not JSON after all: plain output.
    }
  }
  return { stdout: output, stderr: '', interrupted: false };
}

/** A parameter that is a JSON object or array, pretty-printed; otherwise null. */
export function prettyJsonParam(arg: string): string | null {
  const trimmed = arg.trim();
  if (!(trimmed.startsWith('{') || trimmed.startsWith('['))) return null;
  try {
    return JSON.stringify(JSON.parse(trimmed), null, 2);
  } catch {
    return null;
  }
}
