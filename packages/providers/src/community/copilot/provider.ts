/**
 * GitHub Copilot provider (community tier).
 *
 * Implements `IAgentProvider` on top of @microsoft/copilot-sdk. Resolves auth +
 * binary path + reasoning config, translates Archon workflow options
 * (tool restrictions, MCP servers, skills, agents, structured output) to the
 * SDK's `SessionConfig`, creates or resumes a session, and hands the
 * streaming bridge off to `bridgeSession` in `event-bridge.ts`.
 *
 * Module-scope invariant: type-only imports from @microsoft/copilot-sdk. All
 * value imports (`CopilotClient`, `approveAll`) happen inside `sendQuery()`
 * via dynamic `await import(...)`. `provider-lazy-load.test.ts` asserts this
 * so a future SDK update that reads the filesystem at module load can't
 * break compiled-binary bootstrap.
 */
import type { CredentialStatus } from '@archon/provider-contract';
import { createLogger } from '@archon/paths';
import { sessionPreview } from '@archon/provider-contract';
import type {
  ClientGitHubOptions,
  CopilotClientOptions,
  CopilotSession,
  CreateSessionOptions,
  CustomAgentConfig,
  MCPServerConfig,
  SpawnedStdioRuntimeConnection,
  SystemMessageConfig,
} from '@microsoft/copilot-sdk';

import type {
  IAgentProvider,
  MessageChunk,
  ProviderCapabilities,
  ProviderWarning,
  SendQueryOptions,
} from '../../types';
import { loadMcpConfig } from '../../mcp/config';
import { copilotSkillSearchRoots, resolveSkillDirectoriesFromRoots } from '@archon/paths/skills';
import { augmentPromptForJsonSchema } from '../../shared/structured-output';
import { COPILOT_CAPABILITIES } from './capabilities';
import { COPILOT_EFFORTS, parseCopilotConfig, type CopilotProviderDefaults } from './config';
import { clampEffort } from '@archon/provider-contract';
import { resolveCopilotBinaryPath } from './binary-resolver';
import { bridgeSession } from './event-bridge';
import { mapAllowedTools, mapDeniedTools } from './tool-names';
import { closeOpenToolCalls } from '../../shared/tool-calls';
import { failureClassOfThrown, failureResult } from '../../shared/failure';

// The SDK's `ReasoningEffort` is a plain string since copilot-sdk 2.0, so the
// vocabulary Archon sends lives in ./config. Derive the type from that one
// array rather than restating the union here.
type CopilotReasoningEffort = (typeof COPILOT_EFFORTS)[number];

/**
 * The options `createSession` / `resumeSession` take. copilot-sdk 2.0 groups
 * them (`tools`, `skills`, `agents`, `mcp`, `hooks`, `permissions`, `events`,
 * `inference`); `CreateSessionOptions` is the wider of the two, and every
 * group Archon sets is shared with `ResumeSessionOptions`.
 */
type SessionConfig = CreateSessionOptions;

/**
 * Auth env vars, split by intent.
 *
 *   - `COPILOT_GITHUB_TOKEN` — Copilot-specific PAT. Setting it is a strong
 *     signal of intent ("use this for Copilot"), so it always wins.
 *   - `GH_TOKEN` / `GITHUB_TOKEN` — generic GitHub tokens. Most users have
 *     these set for `gh` CLI / clone helpers / webhooks, where classic PATs
 *     are fine. Those PATs typically lack Copilot entitlement, so picking
 *     them up automatically yields a misleading "Session was not created
 *     with authentication info" error from the SDK. We therefore ignore
 *     these unless the user explicitly opts in via `useLoggedInUser: false`.
 */
const COPILOT_TOKEN_ENV_KEY = 'COPILOT_GITHUB_TOKEN';
const GENERIC_GITHUB_TOKEN_ENV_KEYS = ['GH_TOKEN', 'GITHUB_TOKEN'] as const;

let cachedLog: ReturnType<typeof createLogger> | undefined;
function getLog(): ReturnType<typeof createLogger> {
  if (!cachedLog) cachedLog = createLogger('provider.copilot');
  return cachedLog;
}

/**
 * No-op kept for back-compat with tests that previously called into the
 * singleton-reset API. The client is now constructed fresh per `sendQuery()`
 * so each request sees correct per-request env vars.
 */
export function resetCopilotSingleton(): void {
  warnedToolEntries.clear();
}

/**
 * Tool entries already warned about in this process. The same workflow runs the
 * same `denied_tools` on every node, so each untranslatable entry is announced
 * once rather than on every turn; later sightings only reach the debug log.
 */
const warnedToolEntries = new Set<string>();

/** `scope` keeps an agent's entries apart from the node's own lists. */
function firstSightings(entries: string[], scope = ''): string[] {
  const fresh = entries.filter(entry => !warnedToolEntries.has(`${scope}\0${entry}`));
  for (const entry of fresh) warnedToolEntries.add(`${scope}\0${entry}`);
  return fresh;
}

// ─── Env + auth ─────────────────────────────────────────────────────────────

/**
 * Merge process.env with per-request env vars from the workflow node's
 * codebase-scoped env bag. Request env wins — matches the layering
 * Claude/Codex use for their SDK env handoff.
 */
function buildCopilotEnv(requestEnv?: Record<string, string>): Record<string, string> {
  const baseEnv = Object.fromEntries(
    Object.entries(process.env).filter((entry): entry is [string, string] => entry[1] !== undefined)
  );
  return { ...baseEnv, ...(requestEnv ?? {}) };
}

function resolveCopilotToken(env: Record<string, string>): string | undefined {
  const value = env[COPILOT_TOKEN_ENV_KEY];
  return value ? value : undefined;
}

function resolveGenericGitHubToken(env: Record<string, string>): string | undefined {
  for (const key of GENERIC_GITHUB_TOKEN_ENV_KEYS) {
    const value = env[key];
    if (value) return value;
  }
  return undefined;
}

// ─── Reasoning ──────────────────────────────────────────────────────────────

function normalizeReasoning(value: unknown): CopilotReasoningEffort | undefined {
  const clamped = clampEffort(value, COPILOT_EFFORTS);
  // Copilot's SDK lacks both ends of the ladder, so it clamps more often than
  // any other provider — the one that most needs the adjustment to be visible.
  // Matches `claude.effort_clamped` / `codex.effort_clamped`.
  if (clamped !== undefined && clamped !== value) {
    getLog().debug({ declared: value, applied: clamped }, 'copilot.effort_clamped');
  }
  return clamped;
}

/**
 * Resolve Copilot's `reasoningEffort` from the node or assistant default.
 */
function resolveCopilotReasoning(
  nodeConfig: SendQueryOptions['nodeConfig'] | undefined,
  copilotConfig: CopilotProviderDefaults
): { effort: CopilotReasoningEffort | undefined; warning?: string } {
  const declared = nodeConfig?.effort ?? copilotConfig.modelReasoningEffort;
  const effort = normalizeReasoning(declared);
  if (declared !== undefined && effort === undefined) {
    return {
      effort: undefined,
      warning: `Copilot ignored invalid effort '${declared}'.`,
    };
  }
  return { effort };
}

// ─── System prompt ──────────────────────────────────────────────────────────

function resolveSystemMessage(requestOptions?: SendQueryOptions): SystemMessageConfig | undefined {
  const requestPrompt = requestOptions?.systemPrompt;
  const explicitPrompt = requestPrompt ?? requestOptions?.nodeConfig?.systemPrompt;
  const prompt = explicitPrompt ?? requestOptions?.appendSystemPrompt;
  const content = Array.isArray(prompt) ? prompt.join('\n') : prompt;
  if (typeof content === 'string' && content.length > 0) {
    return { mode: 'append', content };
  }
  return undefined;
}

// ─── Translations ───────────────────────────────────────────────────────────

/**
 * Translate Archon's per-node `allowed_tools` / `denied_tools` (Claude tool
 * names) to Copilot's `tools.availableTools` / `tools.excludedTools` (Copilot built-in
 * names, see ./tool-names). The SDK always sends `toolFilterPrecedence:
 * "excluded"`, so an excluded tool stays excluded even when also allowed.
 *
 * Argument patterns (`Bash(git push *)`) and whole MCP servers have no exact
 * Copilot form: denied ones are dropped (a preToolUse file hook enforces them),
 * allowed ones keep their broader tool. Each such entry is warned about once
 * per process.
 */
function applyToolRestrictions(
  sessionConfig: SessionConfig,
  nodeConfig: SendQueryOptions['nodeConfig'],
  warnings: ProviderWarning[]
): void {
  if (!nodeConfig) return;
  if (nodeConfig.allowed_tools !== undefined) {
    const allowed = mapAllowedTools(nodeConfig.allowed_tools);
    sessionConfig.tools = { ...sessionConfig.tools, availableTools: allowed.tools };
    const fresh = firstSightings(allowed.widened);
    if (fresh.length > 0) {
      warnings.push({
        code: 'copilot.allowed_tools_widened',
        message: `Copilot filters tools by name only, so these allowed_tools entries allow their whole tool: ${fresh.join(', ')}.`,
      });
    }
  }
  if (nodeConfig.denied_tools !== undefined) {
    const denied = mapDeniedTools(nodeConfig.denied_tools);
    sessionConfig.tools = { ...sessionConfig.tools, excludedTools: denied.tools };
    const fresh = firstSightings(denied.dropped);
    if (fresh.length > 0) {
      warnings.push({
        code: 'copilot.denied_tools_dropped',
        message: `Copilot filters tools by name only and ignored these denied_tools entries: ${fresh.join(', ')}. Enforce them with a preToolUse hook in .github/hooks/.`,
      });
    }
  }
  getLog().debug(
    {
      availableTools: sessionConfig.tools?.availableTools,
      excludedTools: sessionConfig.tools?.excludedTools,
    },
    'copilot.tool_filters_mapped'
  );
}

/**
 * Translate Archon's `nodeConfig.mcp` (JSON-file path) to Copilot's
 * `SessionConfig.mcp.servers`. Reuses the shared `loadMcpConfig` helper so
 * env-var expansion and missing-var detection behave consistently across
 * providers.
 */
async function applyMcpServers(
  sessionConfig: SessionConfig,
  nodeConfig: SendQueryOptions['nodeConfig'],
  cwd: string,
  warnings: ProviderWarning[]
): Promise<void> {
  const mcpPath = nodeConfig?.mcp;
  if (typeof mcpPath !== 'string' || mcpPath.length === 0) return;

  const { servers, serverNames, missingVars } = await loadMcpConfig(mcpPath, cwd);

  if (missingVars.length > 0) {
    warnings.push({
      code: 'copilot.mcp_env_vars_missing',
      message: `Copilot MCP config references undefined env vars: ${missingVars.join(', ')}. Servers using them may fail at runtime.`,
    });
  }

  sessionConfig.mcp = { ...sessionConfig.mcp, servers: servers as Record<string, MCPServerConfig> };
  getLog().info({ serverNames, missingVars }, 'copilot.mcp_loaded');
}

/**
 * Translate Archon's `nodeConfig.skills` (string names) to Copilot's
 * `SessionConfig.skills.directories` (absolute paths). Unresolved names become
 * a single system warning so the user notices the typo/missing skill.
 */
function applySkills(
  sessionConfig: SessionConfig,
  nodeConfig: SendQueryOptions['nodeConfig'],
  cwd: string,
  copilotHome: string | undefined,
  warnings: ProviderWarning[]
): void {
  if (!nodeConfig?.skills || nodeConfig.skills.length === 0) return;

  const { paths, missing } = resolveSkillDirectoriesFromRoots(
    copilotSkillSearchRoots(cwd, { copilotHome }),
    nodeConfig.skills
  );

  if (missing.length > 0) {
    warnings.push({
      code: 'copilot.skills_missing',
      message: `Copilot ignored missing skills: ${missing.join(', ')}. Expected a directory with SKILL.md under .github/skills/, .agents/skills/ or .claude/skills/ (project), or under the Copilot home's skills/, ~/.agents/skills/ or ~/.claude/skills/.`,
    });
  }

  if (paths.length > 0) {
    sessionConfig.skills = { ...sessionConfig.skills, directories: paths };
  }
  getLog().info({ resolved: paths.length, missing }, 'copilot.skills_resolved');
}

/**
 * Translate Archon's `nodeConfig.agents` (Record<name, AgentDef>) to
 * Copilot's `SessionConfig.agents.definitions`. Only the fields Copilot's
 * `CustomAgentConfig` supports pass through (description, prompt, tools).
 * An agent's `tools` is an allowlist and gets the same Claude-to-Copilot name
 * translation as `allowed_tools`, widened entries warned about once per agent.
 * Archon agent fields Copilot cannot represent (`model`, `disallowedTools`,
 * `skills`, `maxTurns`) surface as one consolidated warning per agent.
 *
 * We do NOT set `SessionConfig.agents.selected` — Archon's workflow model invokes
 * sub-agents via the Task tool, not by switching active agent at session
 * start.
 */
function applyAgents(
  sessionConfig: SessionConfig,
  nodeConfig: SendQueryOptions['nodeConfig'],
  warnings: ProviderWarning[]
): void {
  const agents = nodeConfig?.agents;
  if (!agents) return;
  const entries = Object.entries(agents);
  if (entries.length === 0) return;

  const customAgents: CustomAgentConfig[] = entries.map(([name, def]) => {
    const ignored: string[] = [];
    if (def.model !== undefined) ignored.push('model');
    if (def.disallowedTools !== undefined) ignored.push('disallowedTools');
    if (def.skills !== undefined) ignored.push('skills');
    if (def.maxTurns !== undefined) ignored.push('maxTurns');

    if (ignored.length > 0) {
      warnings.push({
        code: 'copilot.agent_fields_ignored',
        message: `Copilot agent '${name}' ignored unsupported fields: ${ignored.join(', ')}. Copilot supports description, prompt, tools (allowlist) only.`,
      });
    }

    return {
      name,
      description: def.description,
      prompt: def.prompt,
      ...(def.tools !== undefined ? { tools: agentTools(name, def.tools, warnings) } : {}),
    };
  });

  sessionConfig.agents = { ...sessionConfig.agents, definitions: customAgents };
  getLog().info(
    { count: customAgents.length, names: customAgents.map(a => a.name) },
    'copilot.agents_registered'
  );
}

function agentTools(name: string, tools: string[], warnings: ProviderWarning[]): string[] {
  const allowed = mapAllowedTools(tools);
  const fresh = firstSightings(allowed.widened, `agent:${name}`);
  if (fresh.length > 0) {
    warnings.push({
      code: 'copilot.agent_tools_widened',
      message: `Copilot filters tools by name only, so these tools entries of agent '${name}' allow their whole tool: ${fresh.join(', ')}.`,
    });
  }
  return allowed.tools;
}

// ─── SessionConfig assembly ─────────────────────────────────────────────────

type CopilotTokenSource = 'copilot-token' | 'generic-token' | 'logged-in-user';

/**
 * Pick the client's GitHub credential. Auth precedence: see
 * COPILOT_TOKEN_ENV_KEY / GENERIC_GITHUB_TOKEN_ENV_KEYS docs.
 */
function resolveGitHubAuth(
  copilotConfig: CopilotProviderDefaults,
  env: Record<string, string>
): { github: ClientGitHubOptions; tokenSource: CopilotTokenSource } {
  const copilotToken = resolveCopilotToken(env);
  if (copilotToken) {
    return {
      github: { token: copilotToken, useLoggedInUser: false },
      tokenSource: 'copilot-token',
    };
  }
  if (copilotConfig.useLoggedInUser !== false) {
    return { github: { useLoggedInUser: true }, tokenSource: 'logged-in-user' };
  }
  const genericGithubToken = resolveGenericGitHubToken(env);
  return genericGithubToken
    ? {
        github: { token: genericGithubToken, useLoggedInUser: false },
        tokenSource: 'generic-token',
      }
    : { github: { useLoggedInUser: false }, tokenSource: 'logged-in-user' };
}

/**
 * The client options for one request.
 *
 * copilot-sdk 2.0 defaults to an in-process runtime, which cannot take a
 * per-request env; spawn it over stdio so `env` reaches the agent's shell. A
 * custom CLI binary (compiled builds) rides the same connection; without one
 * the SDK spawns its bundled runtime. configDir → baseDirectory (sets
 * COPILOT_HOME on the runtime). `coding-agent` keeps the built-in tools and
 * defaults Archon relies on (the SDK requires an explicit mode since 2.0).
 */
function buildClientOptions(
  copilotConfig: CopilotProviderDefaults,
  env: Record<string, string>,
  cwd: string,
  cliPath: string | undefined
): { clientOpts: CopilotClientOptions; tokenSource: CopilotTokenSource } {
  const runtime: SpawnedStdioRuntimeConnection = {
    kind: 'spawned-stdio',
    env,
    workingDirectory: cwd,
    ...(cliPath ? { path: cliPath } : {}),
    ...(copilotConfig.configDir ? { baseDirectory: copilotConfig.configDir } : {}),
  };
  const { github, tokenSource } = resolveGitHubAuth(copilotConfig, env);
  const clientOpts: CopilotClientOptions = {
    mode: 'coding-agent',
    runtime,
    github,
    ...(copilotConfig.logLevel ? { observability: { logLevel: copilotConfig.logLevel } } : {}),
  };
  return { clientOpts, tokenSource };
}

/**
 * Single construction site for the Copilot SessionConfig. Callers add new
 * translations as `applyX(sessionConfig, ..., warnings)` calls below — keep
 * business logic here straight-through.
 */
async function buildSessionConfig(
  copilotConfig: CopilotProviderDefaults,
  requestOptions: SendQueryOptions | undefined,
  cwd: string,
  approveAll: NonNullable<SessionConfig['permissions']>['onRequest'],
  warnings: ProviderWarning[],
  env: Record<string, string>
): Promise<SessionConfig> {
  const reasoning = resolveCopilotReasoning(requestOptions?.nodeConfig, copilotConfig);
  if (reasoning.warning) {
    warnings.push({ code: 'copilot.reasoning_ignored', message: reasoning.warning });
  }

  const requestedModel = requestOptions?.model?.trim() || undefined;
  const defaultModel = copilotConfig.model?.trim() || undefined;
  // Default to 'auto' so Copilot picks a model when neither request nor
  // config names one. Matches the shipping Copilot CLI default.
  const resolvedModel = requestedModel ?? defaultModel ?? 'auto';

  const sessionConfig: SessionConfig = {
    model: resolvedModel,
    inference: { reasoningEffort: reasoning.effort },
    workingDirectory: cwd,
    // configDir lives on the runtime connection (baseDirectory — sets
    // COPILOT_HOME on the spawned runtime); applied in sendQuery's
    // CopilotClientOptions, not here.
    events: { streaming: true },
    systemMessage: resolveSystemMessage(requestOptions),
    enableConfigDiscovery: copilotConfig.enableConfigDiscovery ?? false,
    // Opt-in (off by default): the runtime loads `<cwd>/.github/hooks/*.json`
    // itself, so on any checked-out tree (an untrusted PR branch too) it would
    // run that tree's commands. `archon kit add` turns it on for a kit project.
    // It applies Copilot CLI semantics (deny/exit 2/error block a tool, a timeout does not); its
    // `hook.start` / `hook.end` events reach the stream via the event bridge.
    hooks: { enableRepositoryHooks: copilotConfig.fileHooks ?? false },
    permissions: { onRequest: approveAll },
  };

  applyToolRestrictions(sessionConfig, requestOptions?.nodeConfig, warnings);
  await applyMcpServers(sessionConfig, requestOptions?.nodeConfig, cwd, warnings);
  // The user skill dir follows the runtime's COPILOT_HOME: `configDir` sets it
  // (client baseDirectory), else the env the runtime is spawned with.
  const copilotHome = copilotConfig.configDir ?? (env.COPILOT_HOME || undefined);
  applySkills(sessionConfig, requestOptions?.nodeConfig, cwd, copilotHome, warnings);
  applyAgents(sessionConfig, requestOptions?.nodeConfig, warnings);

  return sessionConfig;
}

// ─── Error classification ──────────────────────────────────────────────────

/** Best-effort stringify that never yields '[object Object]'. */
function safeErrorString(value: unknown): string {
  if (value === undefined || value === null) return 'Unknown error';
  if (typeof value === 'string') return value || 'Unknown error';
  if (typeof value === 'number' || typeof value === 'boolean') return String(value);
  try {
    const json = JSON.stringify(value);
    if (json && json !== '{}') return json;
  } catch {
    /* fall through */
  }
  return 'Unknown error';
}

function isModelAccessError(errorMessage: string): boolean {
  const normalized = errorMessage.toLowerCase();
  const hasModel = normalized.includes('model');
  const hasAvailabilitySignal =
    normalized.includes('not available') ||
    normalized.includes('not found') ||
    normalized.includes('unsupported');
  return hasModel && hasAvailabilitySignal;
}

/**
 * Classify common Copilot failure modes and return a more actionable Error.
 * Combines the thrown message with any `lastSessionError` collected via the
 * SDK's `session.error` event — the latter often carries the specific
 * model-access / auth detail while the thrown error is generic.
 */
function buildFriendlyCopilotError(error: unknown, lastSessionError?: string): Error {
  const thrownMessage =
    error instanceof Error && error.message ? error.message : safeErrorString(error);
  const parts = [thrownMessage, lastSessionError].filter(
    (m): m is string => typeof m === 'string' && m.length > 0
  );
  const combined = parts.join('\n');

  if (isModelAccessError(combined)) {
    return new Error(
      `Copilot model access error: ${combined}\n\n` +
        'Try a different model in the workflow node or set assistants.copilot.model in .archon/config.yaml.'
    );
  }

  const normalized = combined.toLowerCase();
  if (
    normalized.includes('auth') ||
    normalized.includes('login') ||
    normalized.includes('unauthorized') ||
    normalized.includes('forbidden')
  ) {
    return new Error(
      `Copilot authentication failed: ${combined}\n\n` +
        'Run `copilot login` (default), set COPILOT_GITHUB_TOKEN, or set ' +
        '`useLoggedInUser: false` in `.archon/config.yaml` to use GH_TOKEN / GITHUB_TOKEN.'
    );
  }

  return error instanceof Error ? error : new Error(combined);
}

// ─── Provider class ─────────────────────────────────────────────────────────

/**
 * GitHub Copilot community provider. Implements `IAgentProvider` on top of
 * `@microsoft/copilot-sdk`, translating Archon workflow options (tools, MCP,
 * skills, agents, structured output, reasoning) to the SDK's `SessionConfig`,
 * bridging its event stream via `bridgeSession()`, and surfacing provider
 * signals (translation warnings, fork workaround, resume fallback) to the
 * caller. Each `sendQuery()` constructs a fresh `CopilotClient` so
 * per-request env vars are honored.
 */
export class CopilotProvider implements IAgentProvider {
  async checkCredential(): Promise<CredentialStatus> {
    return { state: 'not_checked', source: 'native' };
  }

  getType(): string {
    return 'copilot';
  }

  getCapabilities(): ProviderCapabilities {
    return COPILOT_CAPABILITIES;
  }

  /**
   * One call is one turn. A failure, including one thrown while setting the turn up,
   * ends in a `result` carrying a typed `failure`, then `settled`: Copilot reports
   * no structured failure class, so a failure is `unknown` with its text as evidence
   * unless Archon's own MCP config check classified it. Only cancellation throws.
   */
  async *sendQuery(
    prompt: string,
    cwd: string,
    resumeSessionId?: string,
    requestOptions?: SendQueryOptions
  ): AsyncGenerator<MessageChunk> {
    let resultReported = false;
    try {
      for await (const chunk of this.streamTurn(prompt, cwd, resumeSessionId, requestOptions)) {
        if (chunk.type === 'result') resultReported = true;
        yield chunk;
      }
    } catch (error) {
      if (requestOptions?.abortSignal?.aborted === true) throw error;
      const err = error as Error;
      // The turn already reported its one result; a later error does not change it.
      if (resultReported) getLog().error({ err }, 'copilot.error_after_result');
      else yield failureResult(failureClassOfThrown(err), 'copilot_query_failed', err.message);
    }
    // Nothing more runs for this turn once its stream has ended.
    yield { type: 'settled' };
  }

  private async *streamTurn(
    prompt: string,
    cwd: string,
    resumeSessionId?: string,
    requestOptions?: SendQueryOptions
  ): AsyncGenerator<MessageChunk> {
    const log = getLog();

    // The executor sets forkSession in normal operation; log rather than throw,
    // which would block ordinary session reuse.
    if (requestOptions?.forkSession !== undefined) {
      log.debug(
        { option: 'forkSession', value: requestOptions.forkSession },
        'copilot.option_not_supported'
      );
    }

    const assistantConfig = requestOptions?.assistantConfig ?? {};
    const copilotConfig = parseCopilotConfig(assistantConfig);

    const mergedEnv = buildCopilotEnv(requestOptions?.env);
    const cliPath = await resolveCopilotBinaryPath(copilotConfig.copilotCliPath);

    const sdk = await import('@microsoft/copilot-sdk');
    const { CopilotClient: copilotClientCtor, approveAll } = sdk;

    const warnings: ProviderWarning[] = [];
    const sessionConfig = await buildSessionConfig(
      copilotConfig,
      requestOptions,
      cwd,
      approveAll,
      warnings,
      mergedEnv
    );

    // Flush translation warnings before session creation so the user sees
    // them even if session construction fails.
    for (const w of warnings) {
      yield { type: 'warning', ...w };
    }

    // Best-effort structured output: augment the prompt with the schema.
    // bridgeSession parses the
    // accumulated assistant transcript and attaches `structuredOutput` to
    // the terminal result chunk.
    const outputFormat = requestOptions?.outputFormat;
    const wantsStructured = outputFormat?.type === 'json_schema';
    const effectivePrompt = wantsStructured
      ? augmentPromptForJsonSchema(prompt, outputFormat.schema)
      : prompt;

    const { clientOpts, tokenSource } = buildClientOptions(copilotConfig, mergedEnv, cwd, cliPath);
    const client = new copilotClientCtor(clientOpts);

    let session: CopilotSession;
    let resumeFailed = false;
    let forkedToFresh = false;
    // Archon's dag-executor sets `forkSession: true` on every reuse so retries
    // start from the pre-node conversation state. The Copilot SDK has no fork
    // API — resumeSession mutates the source session in place. When fork is
    // requested we therefore create a fresh session rather than pollute the
    // source with retry attempts. That loses the prior conversation context,
    // but preserves retry correctness (which is what the executor cares about).
    const wantsFork = requestOptions?.forkSession === true;
    try {
      if (resumeSessionId && !wantsFork) {
        log.debug(
          { sessionIdPreview: sessionPreview(resumeSessionId), cwd },
          'copilot.resume_attempt'
        );
        try {
          session = await client.resumeSession(resumeSessionId, sessionConfig);
        } catch (err) {
          log.debug(
            { err, sessionIdPreview: sessionPreview(resumeSessionId) },
            'copilot.resume_failed_falling_back_to_create'
          );
          resumeFailed = true;
          session = await client.createSession(sessionConfig);
        }
      } else {
        if (resumeSessionId && wantsFork) {
          log.warn(
            { requestedResumeSessionIdPreview: sessionPreview(resumeSessionId) },
            'copilot.fork_unsupported_creating_fresh_session'
          );
          forkedToFresh = true;
        } else {
          log.debug({ cwd }, 'copilot.create_session');
        }
        session = await client.createSession(sessionConfig);
      }
    } catch (err) {
      // Can't connect / create — surface a friendly error and stop the client.
      try {
        await client.stop();
      } catch (stopErr) {
        log.debug({ err: stopErr }, 'copilot.client_stop_failed_after_session_error');
      }
      throw buildFriendlyCopilotError(err);
    }

    if (resumeFailed) {
      yield {
        type: 'warning',
        code: 'copilot.resume_failed',
        message: 'Could not resume Copilot session — starting a fresh conversation.',
      };
    } else if (forkedToFresh) {
      yield {
        type: 'warning',
        code: 'copilot.fork_unsupported',
        message:
          'Copilot SDK does not support session forking; starting a fresh conversation to keep retries safe.',
      };
    }

    log.info(
      {
        sessionIdPreview: sessionPreview(session.sessionId),
        model: sessionConfig.model,
        cwd,
        reasoningEffort: sessionConfig.inference?.reasoningEffort,
        hasSystemMessage: sessionConfig.systemMessage !== undefined,
        mcpServers: sessionConfig.mcp?.servers ? Object.keys(sessionConfig.mcp.servers).length : 0,
        skills: sessionConfig.skills?.directories?.length ?? 0,
        fileHooks: sessionConfig.hooks?.enableRepositoryHooks,
        agents: sessionConfig.agents?.definitions?.length ?? 0,
        tokenSource,
        resumed: resumeSessionId !== undefined && !resumeFailed,
      },
      'copilot.session_started'
    );

    try {
      yield* closeOpenToolCalls(
        bridgeSession(
          session,
          effectivePrompt,
          requestOptions?.abortSignal,
          wantsStructured ? outputFormat.schema : undefined
        ),
        { resultEndsTurn: true }
      );
      log.info({ sessionIdPreview: sessionPreview(session.sessionId) }, 'copilot.prompt_completed');
    } catch (err) {
      log.error(
        { err, sessionIdPreview: sessionPreview(session.sessionId) },
        'copilot.prompt_failed'
      );
      throw buildFriendlyCopilotError(err);
    } finally {
      // Stop the client so its CLI subprocess shuts down; bridgeSession already
      // handled session.abort() + session.disconnect() in its own finally.
      try {
        const stopErrors = await client.stop();
        if (stopErrors.length > 0) {
          log.warn({ errors: stopErrors.map(e => e.message) }, 'copilot.client_stop_errors');
        }
      } catch (stopErr) {
        log.debug({ err: stopErr }, 'copilot.client_stop_threw');
      }
    }
  }
}
