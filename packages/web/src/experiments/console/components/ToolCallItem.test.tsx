import { describe, test, expect } from 'bun:test';
import { renderToStaticMarkup } from 'react-dom/server';
import { ToolCallItem } from './ToolCallItem';
import type { InlineToolCall } from '../primitives/message';
import { StreamContextProvider } from '../lib/stream-context';

const render = (call: InlineToolCall): string =>
  renderToStaticMarkup(
    <StreamContextProvider value={{ runStartedAt: '2026-10-02T09:59:00.000Z' }}>
      <ToolCallItem call={call} timestamp="2026-10-02T10:00:00.000Z" />
    </StreamContextProvider>
  );

describe('ToolCallItem disclosure', () => {
  test('a call with detail to show is toggled by a native button', () => {
    const html = render({ name: 'Bash', input: 'x'.repeat(120) });
    expect(html).toContain('<button type="button" aria-expanded="false"');
  });

  test('a call with no input or output has nothing to toggle', () => {
    expect(render({ name: 'Bash', input: {} })).not.toContain('<button');
  });
});

describe('ToolCallItem subagent prompts', () => {
  test('an Agent call renders as a prompt row naming the subagent', () => {
    const html = render({
      name: 'Agent',
      input: {
        prompt: 'Review the diff\nthen report',
        subagent_type: 'reviewer',
        description: 'Review',
      },
      status: 'completed',
      output: 'Looks good',
    });
    expect(html).toContain('Subagent prompt');
    expect(html).toContain('reviewer');
    expect(html).toContain('Review the diff');
    expect(html).toContain('2 lines');
    expect(html).not.toContain('then report');
  });
});

describe('ToolCallItem MCP calls', () => {
  const call: InlineToolCall = {
    name: 'mcp__portal-api__search',
    input: { query: 'cancel a booked vendor' },
    status: 'completed',
    durationMs: 42,
    output: '[{"operationId":"cancelVendorBooking","path":"/bookings/{id}/cancel"}]',
  };

  test('renders as an MCP row naming the server, the tool, the params and the answer', () => {
    const html = render(call);
    expect(html).toContain('>MCP<');
    expect(html).toContain('portal-api');
    expect(html).toContain('>search<');
    expect(html).toContain('query=&quot;cancel a booked vendor&quot;');
    expect(html).toContain('→ 1 item');
    expect(html).toContain('✓ ok');
    expect(html).toContain('42ms');
    expect(html).not.toContain('>Tool<');
  });

  test('a failed call is marked failed', () => {
    expect(render({ ...call, status: 'failed', output: 'unknown operationId' })).toContain(
      'failed'
    );
  });
});
