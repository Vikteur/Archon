import { describe, expect, test } from 'bun:test';
import { findScriptRuns, parseShellOutput, prettyJsonParam, shellCommandOf } from './script-run';

describe('parseShellOutput', () => {
  test('splits a recorded stdout/stderr object', () => {
    expect(parseShellOutput('{"stdout":"ok\\n","stderr":"warn","interrupted":false}')).toEqual({
      stdout: 'ok\n',
      stderr: 'warn',
      interrupted: false,
    });
  });

  test('takes plain text as stdout', () => {
    expect(parseShellOutput('{plain')).toEqual({
      stdout: '{plain',
      stderr: '',
      interrupted: false,
    });
    expect(parseShellOutput('{"a":1}')).toEqual({
      stdout: '{"a":1}',
      stderr: '',
      interrupted: false,
    });
  });
});

describe('findScriptRuns', () => {
  test('a script with a template and a JSON parameter', () => {
    const runs = findScriptRuns(
      `scripts/scaffold.sh domain/value-object '{"package":"app.x","Name":"Hash"}' src/Hash.java`
    );
    expect(runs).toEqual([
      {
        script: 'scripts/scaffold.sh',
        interpreterArgs: [],
        args: ['domain/value-object', '{"package":"app.x","Name":"Hash"}', 'src/Hash.java'],
        env: {},
      },
    ]);
  });

  test('an interpreter, env assignments, a cd and a redirection', () => {
    const runs = findScriptRuns(
      'cd /repo && AFFECTED_NO_SYNC=1 AFFECTED_BASE="$(cat base.sha)" bash .claude/scripts/affected-check.sh 2>&1 | grep -E "FAILED"'
    );
    expect(runs).toEqual([
      {
        script: '.claude/scripts/affected-check.sh',
        interpreter: 'bash',
        interpreterArgs: [],
        args: [],
        env: { AFFECTED_NO_SYNC: '1', AFFECTED_BASE: '$(cat base.sha)' },
        cwd: '/repo',
      },
    ]);
  });

  test('a script inside a for loop', () => {
    const runs = findScriptRuns(
      'for f in A B; do scripts/scaffold.sh --for $P/$f.java 2>&1 | grep -E "^domain"; done'
    );
    expect(runs.map(r => [r.script, r.args])).toEqual([
      ['scripts/scaffold.sh', ['--for', '$P/$f.java']],
    ]);
  });

  test('node with a script and several runs in one command', () => {
    const runs = findScriptRuns('node .archon/scripts/pick-tickets.js --max 2; ./run.sh a "b c"');
    expect(runs.map(r => [r.interpreter, r.script, r.args])).toEqual([
      ['node', '.archon/scripts/pick-tickets.js', ['--max', '2']],
      [undefined, './run.sh', ['a', 'b c']],
    ]);
  });

  test('reading or editing a script is not running it', () => {
    expect(findScriptRuns('sed -n 1,80p .archon/scripts/plan-order.js')).toEqual([]);
    expect(findScriptRuns('cat scripts/scaffold.sh; grep -n x run.sh')).toEqual([]);
    expect(findScriptRuns('bash -c "echo hi"')).toEqual([]);
  });

  test('here-document bodies are skipped', () => {
    const command = [
      "python3 - <<'EOF'",
      'scripts/scaffold.sh domain/entity',
      'EOF',
      'scripts/real.sh go',
    ].join('\n');
    expect(findScriptRuns(command).map(r => r.script)).toEqual(['scripts/real.sh']);
  });

  test('a plain command runs no script', () => {
    expect(findScriptRuns('git status && ls -la')).toEqual([]);
  });
});

describe('shellCommandOf', () => {
  test('reads the command of a shell tool input', () => {
    expect(shellCommandOf({ command: 'ls', description: 'x' })).toBe('ls');
    expect(shellCommandOf({ file_path: 'a' })).toBeNull();
    expect(shellCommandOf('ls')).toBeNull();
  });
});

describe('prettyJsonParam', () => {
  test('pretty-prints JSON objects and leaves other text alone', () => {
    expect(prettyJsonParam('{"a":1}')).toBe('{\n  "a": 1\n}');
    expect(prettyJsonParam('--for')).toBeNull();
    expect(prettyJsonParam('{not json')).toBeNull();
  });
});
