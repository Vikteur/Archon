import { describe, expect, test } from 'bun:test';
import { renderToStaticMarkup } from 'react-dom/server';
import { ToolCallItem } from './ToolCallItem';
import { StreamContextProvider } from '../lib/stream-context';
import type { InlineToolCall } from '../primitives/message';

const render = (call: InlineToolCall): string =>
  renderToStaticMarkup(
    <StreamContextProvider value={{ runStartedAt: '2026-10-02T09:59:00.000Z' }}>
      <ToolCallItem call={call} timestamp="2026-10-02T10:00:00.000Z" />
    </StreamContextProvider>
  );

describe('script rows in the run stream', () => {
  test('a shell call that runs a script is a SCRIPT row naming the script and its parameters', () => {
    const command = `scripts/scaffold.sh domain/value-object '{"Name":"Hash"}'`;
    const html = render({
      name: command,
      input: { command },
      status: 'completed',
      output: '{"stdout":"[scaffold] Hash.java\\n","stderr":""}',
    });
    expect(html).toContain('>Script<');
    expect(html).toContain('scaffold.sh');
    expect(html).toContain('domain/value-object');
    expect(html).toContain('✓ ok');
    expect(html).not.toContain('>Tool<');
  });

  test('a failed script row shows the exit code', () => {
    const command = 'bash .claude/scripts/affected-check.sh';
    const html = render({ name: command, input: { command }, status: 'failed', exitCode: 1 });
    expect(html).toContain('affected-check.sh');
    expect(html).toContain('failed (exit 1)');
  });

  test('a shell call that runs no script stays a TOOL row', () => {
    const html = render({
      name: 'git status',
      input: { command: 'git status' },
      status: 'completed',
    });
    expect(html).toContain('>Tool<');
    expect(html).not.toContain('>Script<');
  });

  test('the row resolves shell variables and shortens paths and JSON', () => {
    const command = `D=identity-domain/src/test/java/app/x; scripts/scaffold.sh domain/value-object-test '{"package":"app.x","Name":"Hash"}' $D/HashTest.java`;
    const html = render({ name: command, input: { command }, status: 'completed' });
    expect(html).toContain('domain/value-object-test {Name: Hash, package: app.x} HashTest.java');
    expect(html).not.toContain('$D');
  });

  test('the row shows the call description and counts problems in the output', () => {
    const command = 'bash scripts/build.sh';
    const html = render({
      name: command,
      input: { command, description: 'Build the domain module' },
      status: 'failed',
      exitCode: 1,
      output: JSON.stringify({
        stdout: 'Foo.java:3: error: cannot find symbol\nWARN slow\nBUILD FAILED\n',
        stderr: '',
      }),
    });
    expect(html).toContain('Build the domain module');
    expect(html).toContain('2 err');
    expect(html).toContain('1 warn');
  });
});
