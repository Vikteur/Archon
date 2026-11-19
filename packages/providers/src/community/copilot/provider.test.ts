/**
 * CopilotProvider end-to-end test with a fully mocked @microsoft/copilot-sdk.
 *
 * Covers: streaming chunks flow through the async generator, resume
 * fallback on missing session, abort wiring, unsupported-option log-warn,
 * missing-model throw, terminal result chunk carries sessionId + tokens.
 *
 * Runs in its own bun test invocation — mocks @microsoft/copilot-sdk and
 * @archon/paths process-wide.
 */
import { afterEach, beforeEach, describe, expect, mock, test } from 'bun:test';
import { mkdirSync, mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import type {
  CopilotClientOptions,
  CreateSessionOptions as SessionConfig,
  SessionEvent,
  SpawnedStdioRuntimeConnection,
} from '@microsoft/copilot-sdk';
import { removeTempTree } from '@archon/paths/test-utils';

import { createMockLogger } from '../../test/mocks/logger';
import type { SendQueryOptions } from '../../types';

// ─── Mocks ───────────────────────────────────────────────────────────────

const mockLogger = createMockLogger();
mock.module('@archon/paths', () => ({
  createLogger: mock(() => mockLogger),
  BUNDLED_IS_BINARY: false,
  getArchonHome: mock(() => '/tmp/test-archon-home'),
}));

// Minimal fake session. Records prompt, exposes the listener so tests can
// fire events synthetically, and resolves sendAndWait when `resolveSend()` is called.
interface FakeSession {
  sessionId: string;
  prompt?: string;
  sendTimeout?: number;
  aborted: boolean;
  disconnected: boolean;
  listener: ((event: SessionEvent) => void) | undefined;
  fire: (event: SessionEvent) => void;
  resolveSend: (result?: unknown) => void;
  rejectSend: (err: Error) => void;
}

function makeFakeSession(sessionId = 'sess-1'): FakeSession {
  let resolveSend: (v?: unknown) => void = () => undefined;
  let rejectSend: (e: Error) => void = () => undefined;
  const sendPromise = new Promise<unknown>((resolve, reject) => {
    resolveSend = resolve;
    rejectSend = reject;
  });
  const fake: FakeSession = {
    sessionId,
    prompt: undefined,
    aborted: false,
    disconnected: false,
    listener: undefined,
    fire(event) {
      if (this.listener) this.listener(event);
    },
    resolveSend(result) {
      resolveSend(result);
    },
    rejectSend(err) {
      rejectSend(err);
    },
  };
  // Attach the session-shape methods the provider/bridge call:
  const session = fake as FakeSession & {
    on: (h: (e: SessionEvent) => void) => () => void;
    sendAndWait: (opts: { prompt: string }, timeout?: number) => Promise<unknown>;
    disconnect: () => Promise<void>;
    abort: () => Promise<void>;
  };
  session.on = (handler): (() => void) => {
    fake.listener = handler;
    return () => {
      fake.listener = undefined;
    };
  };
  session.sendAndWait = async (opts, timeout): Promise<unknown> => {
    fake.prompt = opts.prompt;
    fake.sendTimeout = timeout;
    return sendPromise;
  };
  session.disconnect = async (): Promise<void> => {
    fake.disconnected = true;
  };
  session.abort = async (): Promise<void> => {
    fake.aborted = true;
  };
  return session as unknown as FakeSession;
}

// Test-controlled fake client. We rebuild it per test via reset().
let nextCreateSessionResult: FakeSession | Error;
let nextResumeSessionResult: FakeSession | Error;
const createSessionSpy = mock((_opts: unknown): Promise<FakeSession> => {
  if (nextCreateSessionResult instanceof Error) {
    return Promise.reject(nextCreateSessionResult);
  }
  return Promise.resolve(nextCreateSessionResult);
});
const resumeSessionSpy = mock((_id: string, _opts: unknown): Promise<FakeSession> => {
  if (nextResumeSessionResult instanceof Error) {
    return Promise.reject(nextResumeSessionResult);
  }
  return Promise.resolve(nextResumeSessionResult);
});

let lastClientOpts: CopilotClientOptions | undefined;
class FakeCopilotClient {
  createSession = createSessionSpy;
  resumeSession = resumeSessionSpy;
  constructor(opts: CopilotClientOptions) {
    lastClientOpts = opts;
  }
}

/** The runtime connection the provider handed the client (always spawned stdio). */
function lastRuntime(): SpawnedStdioRuntimeConnection | undefined {
  return lastClientOpts?.runtime as SpawnedStdioRuntimeConnection | undefined;
}

// Capture the onPermissionRequest passed into createSession.
const approveAllStub = mock(() => ({ kind: 'approved' }));

mock.module('@microsoft/copilot-sdk', () => ({
  CopilotClient: FakeCopilotClient,
  approveAll: approveAllStub,
}));

// Provider imports AFTER mocks are installed.
import { runProviderConformance } from '@archon/provider-contract/conformance';
import { CopilotProvider, resetCopilotSingleton } from './provider';

function evt<T extends SessionEvent['type']>(type: T, data: unknown): SessionEvent {
  return {
    id: 'test',
    timestamp: new Date().toISOString(),
    parentId: null,
    type,
    data,
  } as unknown as SessionEvent;
}

// Drain an async generator (used when the producer feeds events async).
async function collect<T>(gen: AsyncGenerator<T>): Promise<T[]> {
  const out: T[] = [];
  for await (const x of gen) out.push(x);
  return out;
}

describe('CopilotProvider.getType / getCapabilities', () => {
  test('getType returns copilot', () => {
    expect(new CopilotProvider().getType()).toBe('copilot');
  });

  test('getCapabilities matches COPILOT_CAPABILITIES', () => {
    const c = new CopilotProvider().getCapabilities();
    expect(c.sessionResume).toBe(true);
    expect(c.effortControl).toBe(true);
    expect(c.mcp).toBe(true);
    expect(c.hooks).toBe(false);
  });
});

describe('CopilotProvider.sendQuery', () => {
  beforeEach(() => {
    resetCopilotSingleton();
    createSessionSpy.mockClear();
    resumeSessionSpy.mockClear();
    approveAllStub.mockClear();
    lastClientOpts = undefined;
  });

  test('defaults to model="auto" when none is configured', async () => {
    const session = makeFakeSession('sess-default-auto');
    nextCreateSessionResult = session;

    const p = new CopilotProvider();
    const gen = p.sendQuery('hi', '/tmp', undefined, { assistantConfig: {} });

    const firstNext = gen.next();
    await new Promise(resolve => setTimeout(resolve, 5));
    session.fire(evt('assistant.message', { messageId: 'm', content: 'hi' }));
    session.resolveSend(undefined);
    await firstNext;
    await collect(gen);

    expect(createSessionSpy).toHaveBeenCalledTimes(1);
    const opts = createSessionSpy.mock.calls[0]![0] as { model: string };
    expect(opts.model).toBe('auto');
  });

  test('passes model + streaming=true + workingDirectory to createSession', async () => {
    const session = makeFakeSession('sess-1');
    nextCreateSessionResult = session;

    const p = new CopilotProvider();
    const gen = p.sendQuery('hello', '/work/dir', undefined, { model: 'gpt-5' });

    // Drive: start iteration (kicks off createSession); fire a tiny stream
    // and resolve sendAndWait so the generator completes.
    const firstNext = gen.next();
    // Give the async chain a tick so createSession resolves.
    await new Promise(resolve => setTimeout(resolve, 5));
    session.fire(evt('assistant.message', { messageId: 'm', content: 'hi' }));
    session.resolveSend(undefined);
    const chunks = [(await firstNext).value, ...(await collect(gen))];

    expect(createSessionSpy).toHaveBeenCalledTimes(1);
    const opts = createSessionSpy.mock.calls[0]![0] as SessionConfig;
    expect(opts.model).toBe('gpt-5');
    expect(opts.events?.streaming).toBe(true);
    expect(opts.workingDirectory).toBe('/work/dir');
    expect(session.prompt).toBe('hello');
    expect(chunks.some(c => c && typeof c === 'object' && 'type' in c && c.type === 'result')).toBe(
      true
    );
  });

  test('reasoningEffort from nodeConfig.effort passes through', async () => {
    const session = makeFakeSession();
    nextCreateSessionResult = session;

    const p = new CopilotProvider();
    const gen = p.sendQuery('hi', '/w', undefined, {
      model: 'gpt-5',
      nodeConfig: { effort: 'high' },
    });

    const first = gen.next();
    await new Promise(resolve => setTimeout(resolve, 5));
    session.resolveSend(undefined);
    await first;
    await collect(gen);

    const opts = createSessionSpy.mock.calls[0]![0] as SessionConfig;
    expect(opts.inference?.reasoningEffort).toBe('high');
  });

  test.each(['max', 'ultra', 'persistent'] as const)(
    'workflow `effort: %s` maps to SDK `max`',
    async effort => {
      const session = makeFakeSession();
      nextCreateSessionResult = session;

      const p = new CopilotProvider();
      const gen = p.sendQuery('hi', '/w', undefined, {
        model: 'gpt-5',
        nodeConfig: { effort },
      });
      const first = gen.next();
      await new Promise(resolve => setTimeout(resolve, 5));
      session.resolveSend(undefined);
      await first;
      await collect(gen);

      const opts = createSessionSpy.mock.calls[0]![0] as SessionConfig;
      expect(opts.inference?.reasoningEffort).toBe('max');
    }
  );

  // #2556: `minimal` is a rung on Archon's shared ladder that Copilot's SDK
  // lacks, so it clamps to the SDK's shallowest — the same treatment `ultra`
  // already gets at the top end. Only a value that is not a rung at all is
  // dropped.
  test('effort: minimal clamps to the SDK shallowest rung', async () => {
    const session = makeFakeSession();
    nextCreateSessionResult = session;

    const p = new CopilotProvider();
    const gen = p.sendQuery('hi', '/w', undefined, {
      model: 'gpt-5',
      nodeConfig: { effort: 'minimal' },
    });
    const first = gen.next();
    await new Promise(resolve => setTimeout(resolve, 5));
    session.resolveSend(undefined);
    await first;
    await collect(gen);

    const opts = createSessionSpy.mock.calls[0]![0] as SessionConfig;
    expect(opts.inference?.reasoningEffort).toBe('low');
  });

  test.each([
    {
      source: 'request systemPrompt',
      expected: 'Be concise.',
      options: {
        systemPrompt: 'Be concise.',
        nodeConfig: { systemPrompt: 'Lower-priority node prompt.' },
        appendSystemPrompt: 'Lower-priority appended instructions.',
      },
    },
    {
      source: 'nodeConfig.systemPrompt',
      expected: 'Be concise.',
      options: {
        nodeConfig: { systemPrompt: 'Be concise.' },
        appendSystemPrompt: 'Lower-priority appended instructions.',
      },
    },
    {
      source: 'request array systemPrompt',
      expected: 'Be\nconcise.',
      options: {
        systemPrompt: ['Be', 'concise.'] satisfies string[],
        nodeConfig: { systemPrompt: 'Lower-priority node prompt.' },
        appendSystemPrompt: 'Lower-priority appended instructions.',
      },
    },
    {
      source: 'node array systemPrompt',
      expected: 'Be\nconcise.',
      options: {
        nodeConfig: { systemPrompt: ['Be', 'concise.'] satisfies string[] },
        appendSystemPrompt: 'Lower-priority appended instructions.',
      },
    },
  ])('$source appends to the default system message', async ({ expected, options }) => {
    const session = makeFakeSession();
    nextCreateSessionResult = session;

    const p = new CopilotProvider();
    const gen = p.sendQuery('hi', '/w', undefined, {
      model: 'gpt-5',
      ...options,
    });
    const first = gen.next();
    await new Promise(resolve => setTimeout(resolve, 5));
    session.resolveSend(undefined);
    await first;
    await collect(gen);

    const opts = createSessionSpy.mock.calls[0]![0] as SessionConfig;
    expect(opts.systemMessage).toEqual({ content: expected, mode: 'append' });
  });

  test('appendSystemPrompt appends to the default system message', async () => {
    const session = makeFakeSession();
    nextCreateSessionResult = session;

    const p = new CopilotProvider();
    const gen = p.sendQuery('hi', '/w', undefined, {
      model: 'gpt-5',
      appendSystemPrompt: 'Be concise.',
    });
    const first = gen.next();
    await new Promise(resolve => setTimeout(resolve, 5));
    session.resolveSend(undefined);
    await first;
    await collect(gen);

    const opts = createSessionSpy.mock.calls[0]![0] as SessionConfig;
    expect(opts.systemMessage).toEqual({ content: 'Be concise.', mode: 'append' });
  });

  test('resume failure falls back to createSession with warning chunk', async () => {
    const session = makeFakeSession('sess-new');
    nextResumeSessionResult = new Error('session not found');
    nextCreateSessionResult = session;

    const p = new CopilotProvider();
    const gen = p.sendQuery('hi', '/w', 'sess-missing', { model: 'gpt-5' });
    const first = gen.next();
    await new Promise(resolve => setTimeout(resolve, 5));
    session.resolveSend(undefined);
    const chunks = [(await first).value, ...(await collect(gen))];

    expect(resumeSessionSpy).toHaveBeenCalledTimes(1);
    expect(createSessionSpy).toHaveBeenCalledTimes(1);
    expect(chunks).toContainEqual({
      type: 'warning',
      code: 'copilot.resume_failed',
      message: expect.stringContaining('Could not resume'),
    });
  });

  test('forkSession=true with resumeSessionId creates fresh session (SDK has no fork)', async () => {
    const session = makeFakeSession('sess-fresh');
    nextCreateSessionResult = session;

    const p = new CopilotProvider();
    const gen = p.sendQuery('hi', '/w', 'sess-prior', {
      model: 'gpt-5',
      forkSession: true,
    });
    const first = gen.next();
    await new Promise(resolve => setTimeout(resolve, 5));
    session.resolveSend(undefined);
    const chunks = [(await first).value, ...(await collect(gen))];

    // resumeSession MUST NOT be called — we fork to fresh instead.
    expect(resumeSessionSpy).not.toHaveBeenCalled();
    expect(createSessionSpy).toHaveBeenCalledTimes(1);
    expect(chunks).toContainEqual({
      type: 'warning',
      code: 'copilot.fork_unsupported',
      message: expect.stringContaining('does not support session forking'),
    });
  });

  test('resumeSessionId without forkSession resumes in place (node-to-node continuation)', async () => {
    const session = makeFakeSession('sess-resumed');
    nextResumeSessionResult = session;

    const p = new CopilotProvider();
    const gen = p.sendQuery('hi', '/w', 'sess-prior', {
      model: 'gpt-5',
      forkSession: false,
    });
    const first = gen.next();
    await new Promise(resolve => setTimeout(resolve, 5));
    session.resolveSend(undefined);
    await first;
    await collect(gen);

    expect(resumeSessionSpy).toHaveBeenCalledTimes(1);
    expect(createSessionSpy).not.toHaveBeenCalled();
  });

  test('sendAndWait receives explicit timeout > SDK default of 60s', async () => {
    const session = makeFakeSession();
    nextCreateSessionResult = session;

    const p = new CopilotProvider();
    const gen = p.sendQuery('hi', '/w', undefined, { model: 'gpt-5' });
    const first = gen.next();
    await new Promise(resolve => setTimeout(resolve, 5));
    session.resolveSend(undefined);
    await first;
    await collect(gen);

    expect(session.sendTimeout).toBeDefined();
    expect(session.sendTimeout!).toBeGreaterThan(60_000);
  });

  test('terminal result chunk carries sessionId and tokens from usage event', async () => {
    const session = makeFakeSession('sess-42');
    nextCreateSessionResult = session;

    const p = new CopilotProvider();
    const gen = p.sendQuery('hi', '/w', undefined, { model: 'gpt-5' });
    const first = gen.next();
    await new Promise(resolve => setTimeout(resolve, 5));
    session.fire(evt('assistant.usage', { model: 'gpt-5', inputTokens: 10, outputTokens: 3 }));
    session.resolveSend(undefined);
    const chunks = [(await first).value, ...(await collect(gen))];

    const result = chunks.find(
      c => c && typeof c === 'object' && 'type' in c && c.type === 'result'
    ) as { sessionId?: string; tokens?: { input: number; output: number } } | undefined;
    expect(result?.sessionId).toBe('sess-42');
    expect(result?.tokens).toEqual({ input: 10, output: 3 });
  });

  /** Two tools start; only the first completes before the turn ends. */
  const toolTurnEvents = [
    evt('tool.execution_start', { toolCallId: 'c1', toolName: 'read', arguments: { path: 'a' } }),
    evt('tool.execution_start', {
      toolCallId: 'c2',
      toolName: 'bash',
      arguments: { cmd: 'sleep' },
    }),
    evt('tool.execution_complete', { toolCallId: 'c1', success: true, result: { content: 'A' } }),
    evt('assistant.message', { messageId: 'm', content: 'done' }),
  ];

  test('a tool the turn never completed closes as cancelled before the result', async () => {
    const session = makeFakeSession('sess-open-tool');
    nextCreateSessionResult = session;
    const gen = new CopilotProvider().sendQuery('hi', '/w', undefined, { model: 'gpt-5' });
    const first = gen.next();
    await new Promise(resolve => setTimeout(resolve, 5));
    for (const event of toolTurnEvents) session.fire(event);
    session.resolveSend(undefined);
    const chunks = [(await first).value, ...(await collect(gen))];

    expect(chunks).toEqual([
      { type: 'tool_call', toolCallId: 'c1', name: 'read', rawInput: { path: 'a' } },
      { type: 'tool_call', toolCallId: 'c2', name: 'bash', rawInput: { cmd: 'sleep' } },
      { type: 'tool_call_update', toolCallId: 'c1', status: 'completed', output: 'A' },
      { type: 'agent_message_chunk', text: 'done' },
      { type: 'tool_call_update', toolCallId: 'c2', status: 'cancelled' },
      { type: 'result', sessionId: 'sess-open-tool' },
      { type: 'settled' },
    ]);
  });

  test('conforms to the provider contract', async () => {
    /** One Copilot turn driven by a fake session that streams, then resolves or errors. */
    function turn(events: SessionEvent[], rejection?: Error): () => AsyncIterable<unknown> {
      return async function* () {
        const session = makeFakeSession('sess-conformance');
        nextCreateSessionResult = session;
        const gen = new CopilotProvider().sendQuery('hi', '/w', undefined, { model: 'gpt-5' });
        const first = gen.next();
        await new Promise(resolve => setTimeout(resolve, 5));
        for (const event of events) session.fire(event);
        if (rejection) session.rejectSend(rejection);
        else session.resolveSend(undefined);
        const head = await first;
        if (!head.done) yield head.value;
        yield* gen;
      };
    }
    const violations = await runProviderConformance({
      capabilities: new CopilotProvider().getCapabilities(),
      // Copilot's SDK exposes no structured failure class; only Archon's MCP config check
      // classifies its own error.
      failureCases: [
        {
          name: 'missing MCP config file',
          expected: 'misconfigured',
          evidence: 'MCP config file not found',
          run: () =>
            new CopilotProvider().sendQuery('hi', '/w', undefined, {
              model: 'gpt-5',
              nodeConfig: { mcp: 'does-not-exist.mcp.json' },
            }),
        },
        {
          name: 'session error',
          expected: 'unknown',
          evidence: 'upstream failed',
          run: turn([evt('session.error', { message: 'upstream failed' })]),
        },
        {
          name: 'sendAndWait rejection',
          expected: 'unknown',
          evidence: 'kaboom',
          run: turn([], new Error('kaboom')),
        },
      ],
      turns: [
        {
          name: 'completed turn',
          run: turn([evt('assistant.message', { messageId: 'm', content: 'hi' })]),
        },
      ],
      toolTurn: { name: 'tool turn', run: turn(toolTurnEvents) },
    });
    expect(violations).toEqual([]);
  });

  test('abort signal triggers session.abort', async () => {
    const session = makeFakeSession();
    nextCreateSessionResult = session;

    const p = new CopilotProvider();
    const ac = new AbortController();
    const gen = p.sendQuery('hi', '/w', undefined, {
      model: 'gpt-5',
      abortSignal: ac.signal,
    });
    const first = gen.next();
    await new Promise(resolve => setTimeout(resolve, 5));
    ac.abort();
    // Give the abort listener a tick to run session.abort().
    await new Promise(resolve => setTimeout(resolve, 5));
    session.resolveSend(undefined);
    await first;
    await collect(gen);

    expect(session.aborted).toBe(true);
  });

  test('session.disconnect is called in finally (even on success)', async () => {
    const session = makeFakeSession();
    nextCreateSessionResult = session;

    const p = new CopilotProvider();
    const gen = p.sendQuery('hi', '/w', undefined, { model: 'gpt-5' });
    const first = gen.next();
    await new Promise(resolve => setTimeout(resolve, 5));
    session.resolveSend(undefined);
    await first;
    await collect(gen);

    expect(session.disconnected).toBe(true);
  });

  test('a forkSession flag is logged at debug (not thrown)', async () => {
    const session = makeFakeSession();
    nextCreateSessionResult = session;

    const p = new CopilotProvider();
    const gen = p.sendQuery('hi', '/w', undefined, {
      model: 'gpt-5',
      forkSession: true,
    });
    const first = gen.next();
    await new Promise(resolve => setTimeout(resolve, 5));
    session.resolveSend(undefined);
    await first;
    await collect(gen);

    // No throw, and no warn-level log for forkSession — debug is fine.
    const warnCalls = mockLogger.warn.mock.calls;
    const sawUnsupported = warnCalls.some(args => args[1] === 'copilot.option_not_supported');
    expect(sawUnsupported).toBe(false);
  });

  test('GH_TOKEN is ignored by default (logged-in user wins)', async () => {
    const session = makeFakeSession();
    nextCreateSessionResult = session;

    const p = new CopilotProvider();
    const gen = p.sendQuery('hi', '/w', undefined, {
      model: 'gpt-5',
      env: { GH_TOKEN: 'ghp_testtoken' },
    });
    const first = gen.next();
    await new Promise(resolve => setTimeout(resolve, 5));
    session.resolveSend(undefined);
    await first;
    await collect(gen);

    expect(lastClientOpts?.github?.token).toBeUndefined();
    expect(lastClientOpts?.github?.useLoggedInUser).toBe(true);
    // copilot-sdk 2.0 placement guard: the runtime must run in the request cwd
    // via the connection's `workingDirectory` (a silent revert would strand
    // sessions in the server's cwd).
    expect(lastClientOpts?.mode).toBe('coding-agent');
    expect(lastRuntime()?.kind).toBe('spawned-stdio');
    expect(lastRuntime()?.workingDirectory).toBe('/w');
    // Dev mode resolves no custom CLI binary → no path override
    // (the SDK spawns its bundled runtime).
    expect(lastRuntime()?.path).toBeUndefined();
  });

  test("a run's identity in the request env reaches the Copilot runtime the agent's shell runs in", async () => {
    const session = makeFakeSession();
    nextCreateSessionResult = session;
    const identity = {
      WORKFLOW_ID: 'run-1',
      ARCHON_WORKFLOW_CODEBASE_ID: 'selected-project',
      ARCHON_NODE_EXECUTION: '{"runId":"run-1","path":"notes"}',
      ARCHON_CLI_COMMAND: '["/opt/archon/bin/archon"]',
    };

    const p = new CopilotProvider();
    const gen = p.sendQuery('hi', '/w', undefined, { model: 'gpt-5', env: identity });
    const first = gen.next();
    await new Promise(resolve => setTimeout(resolve, 5));
    session.resolveSend(undefined);
    await first;
    await collect(gen);

    // 2.0 defaults to an in-process runtime that cannot take this env, so the
    // provider must keep spawning it over stdio with the merged env.
    expect(lastRuntime()?.kind).toBe('spawned-stdio');
    expect(lastRuntime()?.env).toMatchObject(identity);
    expect(lastRuntime()?.baseDirectory).toBeUndefined();
  });

  test('configDir override → runtime baseDirectory (COPILOT_HOME), sdk-2.0 placement', async () => {
    const session = makeFakeSession();
    nextCreateSessionResult = session;

    const p = new CopilotProvider();
    const gen = p.sendQuery('hi', '/w', undefined, {
      model: 'gpt-5',
      assistantConfig: { configDir: '/custom/copilot-home' },
    });
    const first = gen.next();
    await new Promise(resolve => setTimeout(resolve, 5));
    session.resolveSend(undefined);
    await first;
    await collect(gen);

    expect(lastRuntime()?.baseDirectory).toBe('/custom/copilot-home');
  });

  test('COPILOT_GITHUB_TOKEN is always used (intent signal)', async () => {
    const session = makeFakeSession();
    nextCreateSessionResult = session;

    const p = new CopilotProvider();
    const gen = p.sendQuery('hi', '/w', undefined, {
      model: 'gpt-5',
      env: {
        COPILOT_GITHUB_TOKEN: 'ghp_copilot',
        GH_TOKEN: 'host-gh',
        GITHUB_TOKEN: 'host-github',
      },
      protectedEnvKeys: ['COPILOT_GITHUB_TOKEN'],
      assistantConfig: { useLoggedInUser: true },
    });
    const first = gen.next();
    await new Promise(resolve => setTimeout(resolve, 5));
    session.resolveSend(undefined);
    await first;
    await collect(gen);

    expect(lastClientOpts?.github?.token).toBe('ghp_copilot');
    expect(lastClientOpts?.github?.useLoggedInUser).toBe(false);
  });

  test('useLoggedInUser:false opts into generic GH_TOKEN', async () => {
    const session = makeFakeSession();
    nextCreateSessionResult = session;

    const p = new CopilotProvider();
    const gen = p.sendQuery('hi', '/w', undefined, {
      model: 'gpt-5',
      env: { GH_TOKEN: 'ghp_testtoken' },
      assistantConfig: { useLoggedInUser: false },
    });
    const first = gen.next();
    await new Promise(resolve => setTimeout(resolve, 5));
    session.resolveSend(undefined);
    await first;
    await collect(gen);

    expect(lastClientOpts?.github?.token).toBe('ghp_testtoken');
    expect(lastClientOpts?.github?.useLoggedInUser).toBe(false);
  });

  test('assistantConfig.useLoggedInUser=true overrides env token', async () => {
    const session = makeFakeSession();
    nextCreateSessionResult = session;

    const p = new CopilotProvider();
    const gen = p.sendQuery('hi', '/w', undefined, {
      model: 'gpt-5',
      env: { GH_TOKEN: 'ghp_testtoken' },
      assistantConfig: { useLoggedInUser: true },
    });
    const first = gen.next();
    await new Promise(resolve => setTimeout(resolve, 5));
    session.resolveSend(undefined);
    await first;
    await collect(gen);

    expect(lastClientOpts?.github?.token).toBeUndefined();
    expect(lastClientOpts?.github?.useLoggedInUser).toBe(true);
  });

  test('a sendAndWait rejection ends the turn in a typed failure, then settled', async () => {
    const session = makeFakeSession();
    nextCreateSessionResult = session;

    const p = new CopilotProvider();
    const gen = p.sendQuery('hi', '/w', undefined, { model: 'gpt-5' });
    const first = gen.next();
    await new Promise(resolve => setTimeout(resolve, 5));
    session.rejectSend(new Error('kaboom'));

    const head = await first;
    const chunks = [...(head.done ? [] : [head.value]), ...(await collect(gen))];
    const result = chunks.find(c => c.type === 'result');
    expect(result).toMatchObject({ type: 'result', isError: true, failure: { class: 'unknown' } });
    expect((result as { failure?: { evidence: string } }).failure?.evidence).toContain('kaboom');
    expect(chunks.at(-1)).toEqual({ type: 'settled' });
  });
});

// ─── Kit parity: file hooks, tool names, Copilot skill roots ─────────────────

async function runOnce(
  options: SendQueryOptions,
  cwd = '/w'
): Promise<{ opts: SessionConfig; chunks: unknown[] }> {
  const session = makeFakeSession();
  nextCreateSessionResult = session;
  const gen = new CopilotProvider().sendQuery('hi', cwd, undefined, options);
  const first = gen.next();
  await new Promise(resolve => setTimeout(resolve, 5));
  session.resolveSend(undefined);
  const chunks = [(await first).value, ...(await collect(gen))];
  const opts = createSessionSpy.mock.calls.at(-1)![0] as SessionConfig;
  return { opts, chunks };
}

describe('CopilotProvider kit parity', () => {
  beforeEach(() => {
    resetCopilotSingleton();
    createSessionSpy.mockClear();
  });

  test('file hooks are off by default (hooks.enableRepositoryHooks)', async () => {
    const { opts } = await runOnce({ model: 'gpt-5' });
    expect(opts.hooks?.enableRepositoryHooks).toBe(false);
  });

  test('fileHooks: true turns the runtime file hooks on', async () => {
    const { opts } = await runOnce({
      model: 'gpt-5',
      assistantConfig: { fileHooks: true },
    });
    expect(opts.hooks?.enableRepositoryHooks).toBe(true);
  });

  test('fileHooks: false keeps the runtime file hooks off', async () => {
    const { opts } = await runOnce({
      model: 'gpt-5',
      assistantConfig: { fileHooks: false },
    });
    expect(opts.hooks?.enableRepositoryHooks).toBe(false);
  });

  test('a hook.end from the runtime reaches the stream as a hook chunk', async () => {
    const session = makeFakeSession();
    nextCreateSessionResult = session;
    const gen = new CopilotProvider().sendQuery('hi', '/w', undefined, {
      model: 'gpt-5',
    });
    const first = gen.next();
    await new Promise(resolve => setTimeout(resolve, 5));
    session.fire(evt('hook.start', { hookInvocationId: 'h1', hookType: 'preToolUse' }));
    session.fire(
      evt('hook.end', {
        hookInvocationId: 'h1',
        hookType: 'preToolUse',
        success: false,
        error: { message: 'boom', source: '.github/hooks/policy.json' },
      })
    );
    session.resolveSend(undefined);
    const chunks = [(await first).value, ...(await collect(gen))];
    expect(chunks).toContainEqual({
      type: 'hook',
      hookId: 'h1',
      hookName: '.github/hooks/policy.json',
      hookEvent: 'preToolUse',
      status: 'failed',
    });
  });

  test('allowed_tools and denied_tools are translated to Copilot tool names', async () => {
    const { opts } = await runOnce({
      model: 'gpt-5',
      nodeConfig: {
        allowed_tools: ['Read', 'Grep', 'Bash', 'mcp__github__list_issues'],
        denied_tools: ['Write', 'Edit'],
      },
    });
    expect(opts.tools?.availableTools).toEqual(['view', 'grep', 'bash', 'github-list_issues']);
    expect(opts.tools?.excludedTools).toEqual(['create', 'edit']);
  });

  test('a denied argument pattern is dropped with one warning per process', async () => {
    const nodeConfig = { denied_tools: ['Bash(git push *)', 'Write'] };
    const firstRun = await runOnce({ model: 'gpt-5', nodeConfig });
    expect(firstRun.opts.tools?.excludedTools).toEqual(['create']);
    expect(firstRun.chunks).toContainEqual({
      type: 'warning',
      code: 'copilot.denied_tools_dropped',
      message: expect.stringContaining('Bash(git push *)'),
    });

    const secondRun = await runOnce({ model: 'gpt-5', nodeConfig });
    expect(secondRun.opts.tools?.excludedTools).toEqual(['create']);
    expect(
      secondRun.chunks.some(
        c => (c as { code?: string } | undefined)?.code === 'copilot.denied_tools_dropped'
      )
    ).toBe(false);
  });

  test('an allowed argument pattern keeps its tool, with a widened warning', async () => {
    const { opts, chunks } = await runOnce({
      model: 'gpt-5',
      nodeConfig: { allowed_tools: ['Bash(git status *)'] },
    });
    expect(opts.tools?.availableTools).toEqual(['bash']);
    expect(chunks).toContainEqual({
      type: 'warning',
      code: 'copilot.allowed_tools_widened',
      message: expect.stringContaining('Bash(git status *)'),
    });
  });

  test('agent tools are translated to Copilot tool names', async () => {
    const { opts } = await runOnce({
      model: 'gpt-5',
      nodeConfig: {
        agents: {
          reviewer: {
            description: 'Reviews',
            prompt: 'Review it.',
            tools: ['Read', 'Grep', 'Glob', 'mcp__github__get_pull_request', 'custom_tool'],
          },
          open: { description: 'Any tool', prompt: 'Go.' },
        },
      },
    });
    expect(opts.agents?.definitions).toEqual([
      {
        name: 'reviewer',
        description: 'Reviews',
        prompt: 'Review it.',
        tools: ['view', 'grep', 'glob', 'github-get_pull_request', 'custom_tool'],
      },
      { name: 'open', description: 'Any tool', prompt: 'Go.' },
    ]);
  });

  test('an agent tools pattern keeps its tool, with one warning per agent', async () => {
    const nodeConfig = {
      allowed_tools: ['Bash(git log *)'],
      agents: {
        a: { description: 'A', prompt: 'A.', tools: ['Bash(git log *)', 'mcp__github'] },
        b: { description: 'B', prompt: 'B.', tools: ['Bash(git log *)'] },
      },
    };
    const firstRun = await runOnce({ model: 'gpt-5', nodeConfig });
    expect(firstRun.opts.agents?.definitions?.map(agent => agent.tools)).toEqual([
      ['bash', 'mcp:*'],
      ['bash'],
    ]);
    const agentWarnings = firstRun.chunks.filter(
      c => (c as { code?: string } | undefined)?.code === 'copilot.agent_tools_widened'
    );
    expect(agentWarnings).toEqual([
      {
        type: 'warning',
        code: 'copilot.agent_tools_widened',
        message: expect.stringContaining(
          "agent 'a' allow their whole tool: Bash(git log *), mcp__github"
        ),
      },
      {
        type: 'warning',
        code: 'copilot.agent_tools_widened',
        message: expect.stringContaining("agent 'b'"),
      },
    ]);

    const secondRun = await runOnce({ model: 'gpt-5', nodeConfig });
    expect(
      secondRun.chunks.some(
        c => (c as { code?: string } | undefined)?.code === 'copilot.agent_tools_widened'
      )
    ).toBe(false);
  });

  test('an explicitly empty agent tools list stays empty (no tools)', async () => {
    const { opts } = await runOnce({
      model: 'gpt-5',
      nodeConfig: { agents: { none: { description: 'N', prompt: 'N.', tools: [] } } },
    });
    expect(opts.agents?.definitions?.[0]?.tools).toEqual([]);
  });

  describe('skills', () => {
    const originalHome = process.env.HOME;
    const originalCopilotHome = process.env.COPILOT_HOME;
    let root: string;
    let cwd: string;
    let home: string;

    const stage = (dir: string, name: string): string => {
      const skillDir = join(dir, name);
      mkdirSync(skillDir, { recursive: true });
      writeFileSync(join(skillDir, 'SKILL.md'), `# ${name}\n`);
      return skillDir;
    };

    beforeEach(() => {
      root = mkdtempSync(join(tmpdir(), 'archon-copilot-skills-'));
      cwd = join(root, 'project');
      home = join(root, 'home');
      mkdirSync(cwd, { recursive: true });
      mkdirSync(home, { recursive: true });
      process.env.HOME = home;
      delete process.env.COPILOT_HOME;
    });

    afterEach(async () => {
      if (originalHome === undefined) delete process.env.HOME;
      else process.env.HOME = originalHome;
      if (originalCopilotHome === undefined) delete process.env.COPILOT_HOME;
      else process.env.COPILOT_HOME = originalCopilotHome;
      await removeTempTree(root);
    });

    test('resolves a skill from <cwd>/.github/skills', async () => {
      const dir = stage(join(cwd, '.github', 'skills'), 'review');
      const { opts } = await runOnce({ model: 'gpt-5', nodeConfig: { skills: ['review'] } }, cwd);
      expect(opts.skills?.directories).toEqual([dir]);
    });

    test('resolves a skill from ~/.copilot/skills', async () => {
      const dir = stage(join(home, '.copilot', 'skills'), 'personal');
      const { opts } = await runOnce({ model: 'gpt-5', nodeConfig: { skills: ['personal'] } }, cwd);
      expect(opts.skills?.directories).toEqual([dir]);
    });

    test('the user skill dir follows configDir, then a request COPILOT_HOME', async () => {
      const configDir = join(root, 'config-home');
      const envHome = join(root, 'env-home');
      const fromConfig = stage(join(configDir, 'skills'), 'a');
      const fromEnv = stage(join(envHome, 'skills'), 'b');

      const viaConfig = await runOnce(
        {
          model: 'gpt-5',
          assistantConfig: { configDir },
          env: { COPILOT_HOME: envHome },
          nodeConfig: { skills: ['a', 'b'] },
        },
        cwd
      );
      expect(viaConfig.opts.skills?.directories).toEqual([fromConfig]);

      const viaEnv = await runOnce(
        {
          model: 'gpt-5',
          env: { COPILOT_HOME: envHome },
          nodeConfig: { skills: ['a', 'b'] },
        },
        cwd
      );
      expect(viaEnv.opts.skills?.directories).toEqual([fromEnv]);
    });

    test('a missing skill warning names the Copilot roots', async () => {
      const { chunks } = await runOnce({ model: 'gpt-5', nodeConfig: { skills: ['nope'] } }, cwd);
      expect(chunks).toContainEqual({
        type: 'warning',
        code: 'copilot.skills_missing',
        message: expect.stringContaining('.github/skills/'),
      });
    });
  });
});
