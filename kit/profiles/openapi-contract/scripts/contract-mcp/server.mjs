// @@KIT_CONTRACT_SERVER_NAME@@: a local MCP server over the pinned portal API contract, as docs only. `search` finds operations by an
// agent's words, `read` answers one operation in full with its agent-readiness verdict, `where` answers where an
// operation lives in the Java code (code-index.mjs), `schema` one schema's fields and `usedBy` the operations and
// Java lines that carry a schema or a field (schema-graph.mjs). It reads two git-ignored files and the checkout's own
// Java sources: no backend, no sign-in, no network. What search and read send is defined once, in
// scripts/contract-agent-readiness/read.mjs, so the readiness check measures exactly what an agent gets here. The
// tools themselves are defined in tools.mjs, which cli.mjs shares (the shell fallback).
// Claude Code starts it over stdio: node scripts/contract-mcp/server.mjs (from any folder; CLAUDE_PROJECT_DIR or this
// file's place gives the repo root).
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { portalTools } from './tools.mjs';

const root = process.env.CLAUDE_PROJECT_DIR ?? path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const { serverName, projectName, spec, ops, tools } = portalTools(root);

const server = new McpServer({ name: serverName, version: '0.1.0' }, {
  instructions: `Searches and reads the ${projectName} API contract (v${spec.info?.version}, ${ops.length} operations) and each `
    + "operation's agent-readiness verdict, and finds where an operation and a schema live in this checkout's Java code. "
    + 'Order: search, read, then where or schema, then usedBy. It never calls the backend.',
});

for (const { name, def, handler } of tools) server.registerTool(name, def, handler);

await server.connect(new StdioServerTransport());
