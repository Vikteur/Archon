import { describe, expect, test } from 'bun:test';
import {
  analyzeOutput,
  argKind,
  expandVars,
  findScriptRuns,
  jsonSummary,
  lineTone,
  parseShellOutput,
  prettyJsonParam,
  runPreview,
  scriptCallOf,
  shellCommandOf,
  shellDescriptionOf,
} from './script-run';

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
        vars: {},
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
        vars: {},
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

describe('shell variables', () => {
  test('a run records the variables set before it that it uses', () => {
    const [run] = findScriptRuns(
      'D=identity-domain/src/test/java/app/x; P=app.x; U=unused\nscripts/scaffold.sh domain/value-object-test "{\\"package\\":\\"$P\\"}" $D/HashTest.java'
    );
    expect(run.vars).toEqual({ D: 'identity-domain/src/test/java/app/x', P: 'app.x' });
    expect(expandVars(run.args[2], run.vars)).toBe(
      'identity-domain/src/test/java/app/x/HashTest.java'
    );
  });

  test('export, braces, chained values and command substitutions', () => {
    const [run] = findScriptRuns(
      'export ROOT=/repo; S=${ROOT}/scripts; SHA=$(git rev-parse HEAD); bash $S/ci.sh $SHA'
    );
    expect(run.vars).toEqual({ S: '/repo/scripts' });
    expect(expandVars(run.script, run.vars)).toBe('/repo/scripts/ci.sh');
    expect(expandVars(run.args[0], run.vars)).toBe('$SHA');
  });

  test('an assignment prefix is still environment, not a variable', () => {
    const [run] = findScriptRuns('X=1 ./run.sh $X');
    expect(run.env).toEqual({ X: '1' });
    expect(run.vars).toEqual({});
  });
});

describe('parameters', () => {
  test('kinds', () => {
    expect(argKind('--dry-run')).toBe('flag');
    expect(argKind('{"a":1}')).toBe('json');
    expect(argKind('src/Hash.java')).toBe('path');
    expect(argKind('domain/value-object')).toBe('path');
    expect(argKind('hello world')).toBe('text');
  });

  test('a JSON summary names its name-like keys first', () => {
    expect(jsonSummary('{"package":"app.x","Name":"Hash","cases":[1,2,3]}')).toBe(
      '{Name: Hash, package: app.x, +1}'
    );
    expect(jsonSummary('[1,2]')).toBe('[2 items]');
    expect(jsonSummary('nope')).toBeNull();
  });

  test('a row preview resolves variables and shortens paths and JSON', () => {
    const [run] = findScriptRuns(
      'D=src/test/java; scripts/scaffold.sh --test domain/value-object \'{"Name":"Hash"}\' $D/HashTest.java'
    );
    expect(runPreview(run)).toBe('--test domain/value-object {Name: Hash} HashTest.java');
  });
});

describe('tool call helpers', () => {
  test('scriptCallOf finds the runs of a shell call and nothing else', () => {
    expect(scriptCallOf({ command: './a.sh x' })?.runs.map(r => r.script)).toEqual(['./a.sh']);
    expect(scriptCallOf({ command: 'git status' })).toBeNull();
    expect(scriptCallOf({ file_path: 'a.sh' })).toBeNull();
  });

  test('shellDescriptionOf', () => {
    expect(shellDescriptionOf({ command: 'x', description: ' Run it ' })).toBe('Run it');
    expect(shellDescriptionOf({ command: 'x', description: '' })).toBeNull();
    expect(shellDescriptionOf('x')).toBeNull();
  });
});

describe('output lines', () => {
  test('tones', () => {
    expect(lineTone('error: cannot find symbol')).toBe('error');
    expect(lineTone('Foo.java:12: error: cannot find symbol')).toBe('error');
    expect(lineTone('FAIL: image-check')).toBe('error');
    expect(lineTone('SURVIVED: HashTest#equals')).toBe('error');
    expect(lineTone('BUILD FAILED in 3s')).toBe('error');
    expect(lineTone('warning: [deprecation] old()')).toBe('warning');
    expect(lineTone('WARN unused import')).toBe('warning');
    expect(lineTone('BUILD SUCCESSFUL in 12s')).toBe('success');
    expect(lineTone('affected-check: ok')).toBe('success');
    expect(lineTone('[scaffold] src/Hash.java')).toBeNull();
    expect(lineTone('errorprone is on the path')).toBeNull();
    expect(lineTone('        error | throws]')).toBeNull();
    expect(lineTone('error[E0425]: cannot find value')).toBe('error');
    expect(lineTone('[ERROR] Failed to execute goal')).toBe('error');
  });

  test('analyzeOutput numbers lines, splits tags, counts problems and drops ANSI', () => {
    const out = analyzeOutput(
      '[scaffold] src/Hash.java\n\u001b[31merror: boom\u001b[0m\nWARN careful\naffected-check: ok\n'
    );
    expect(out.errors).toBe(1);
    expect(out.warnings).toBe(1);
    expect(out.lines.map(l => [l.number, l.tag, l.text, l.tone])).toEqual([
      [1, '[scaffold]', ' src/Hash.java', null],
      [2, null, 'error: boom', 'error'],
      [3, null, 'WARN careful', 'warning'],
      [4, 'affected-check:', ' ok', 'success'],
    ]);
    expect(analyzeOutput('\n\n').lines).toEqual([]);
  });
});
