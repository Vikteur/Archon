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
    };
  }
  if (!isScriptPath(head.text)) return null;
  return {
    script: head.text,
    interpreterArgs: [],
    args: stripRedirections(words.slice(i + 1)),
    env,
    ...(cwd !== undefined ? { cwd } : {}),
  };
}

/** Every script a shell command runs, in order. Empty when it runs none. */
export function findScriptRuns(command: string): ScriptRun[] {
  const runs: ScriptRun[] = [];
  let cwd: string | undefined;
  for (const words of splitSimpleCommands(command)) {
    const first = words.findIndex(w => w.quoted || !PREFIX_WORDS.has(w.text));
    if (first !== -1 && words[first].text === 'cd' && !words[first].quoted) {
      const target = words[first + 1]?.text;
      if (target !== undefined && target !== '-') cwd = target;
      continue;
    }
    const run = parseSimpleCommand(words, cwd);
    if (run !== null) runs.push(run);
  }
  return runs;
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
