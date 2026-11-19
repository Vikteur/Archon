/**
 * The seams of `archon kit setup` that touch the terminal and the processes: the dialog (clack in a terminal,
 * plain lines without one) and the runner that spawns a program into a log. The tests replace both.
 */
import { spawn } from 'child_process';
import * as clack from '@clack/prompts';
import type { OutputSink } from './kit';

export interface SetupSpinner {
  start(message: string): void;
  stop(message: string): void;
  error(message: string): void;
}

export interface SetupUi {
  intro(title: string): void;
  outro(message: string): void;
  note(message: string, title: string): void;
  info(message: string): void;
  warn(message: string): void;
  text(options: {
    message: string;
    placeholder?: string;
    initialValue?: string;
    validate: (value: string | undefined) => string | undefined;
  }): Promise<string | symbol | undefined>;
  confirm(options: { message: string }): Promise<boolean | symbol>;
  isCancel(value: unknown): value is symbol;
  cancel(message: string): void;
  spinner(): SetupSpinner;
}

export const clackUi: SetupUi = {
  intro: title => clack.intro(title),
  outro: message => clack.outro(message),
  note: (message, title) => clack.note(message, title),
  info: message => clack.log.info(message),
  warn: message => clack.log.warn(message),
  text: options => clack.text(options),
  confirm: options => clack.confirm(options),
  isCancel: (value): value is symbol => clack.isCancel(value),
  cancel: message => clack.cancel(message),
  spinner: () => clack.spinner(),
};

/** Plain lines for a run without a terminal: no animation, no prompts. */
export function plainUi(write: (line: string) => void = line => console.log(line)): SetupUi {
  const noPrompt = (): never => {
    throw new Error('kit setup cannot ask without a terminal');
  };
  return {
    intro: title => write(title),
    outro: message => write(message),
    note: (message, title) => write(`${title}\n${message}`),
    info: message => write(message),
    warn: message => write(`Warning: ${message}`),
    text: noPrompt,
    confirm: noPrompt,
    isCancel: (value): value is symbol => typeof value === 'symbol',
    cancel: message => write(message),
    spinner: () => ({
      start: () => undefined,
      stop: message => write(`ok  ${message}`),
      error: message => write(`FAIL ${message}`),
    }),
  };
}

/** Runs one program (no shell); its output goes to `output`, its stdin is closed. Resolves its exit code. */
export type Runner = (
  command: string,
  args: string[],
  options: { cwd: string; env: NodeJS.ProcessEnv; output: OutputSink }
) => Promise<number>;

export const spawnRunner: Runner = (command, args, { cwd, env, output }) =>
  new Promise(done => {
    let finished = false;
    const finish = (code: number): void => {
      if (finished) return;
      finished = true;
      done(code);
    };
    const child = spawn(command, args, { cwd, env, stdio: ['ignore', 'pipe', 'pipe'] });
    child.stdout.on('data', chunk => output(String(chunk)));
    child.stderr.on('data', chunk => output(String(chunk)));
    child.on('error', err => {
      output(`${err.message}\n`);
      finish(127);
    });
    child.on('close', code => finish(code ?? 1));
    // A background process the command started may hold its pipes open: its exit ends the step a moment later.
    child.on('exit', code => {
      setTimeout(() => {
        child.stdout.destroy();
        child.stderr.destroy();
        finish(code ?? 1);
      }, 1000).unref();
    });
  });
