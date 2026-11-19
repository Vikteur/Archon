// @@KIT_CONTRACT_SERVER_NAME@@ on the command line: the shell fallback for an MCP client whose policy blocks the local server. It runs
// the very tools server.mjs registers (tools.mjs), so the answer is byte-identical to the MCP tool's text. Prints that
// text (a JSON string) and exits 0; an error answer is printed too and exits 1; a usage error exits 2, --help exits 0.
//   node scripts/contract-mcp/cli.mjs --help
// Same root resolution as server.mjs (CLAUDE_PROJECT_DIR, else this file's place).
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { portalTools } from './tools.mjs';

const root = process.env.CLAUDE_PROJECT_DIR ?? path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const [command, ...args] = process.argv.slice(2);

const forms = {
  search: 'search <words...>',
  read: 'read <operationId>',
  where: 'where <operationId> | where --tag <tag> | where --status live|stub|none',
  schema: 'schema <name>',
  usedBy: 'usedBy <target>',
};

const { tools } = portalTools(root);
const usage = () => ['Usage: node scripts/contract-mcp/cli.mjs <command> ...', '',
  ...tools.map((t) => `  ${forms[t.name]}\n      ${t.def.description}`), '',
  '  --help    this text'].join('\n');
const usageError = (why) => { console.error(`${why ? `${why}\n\n` : ''}${usage()}`); process.exit(2); };

if (command === '--help' || command === '-h') { console.log(usage()); process.exit(0); }
if (!command) usageError('');
const tool = tools.find((t) => t.name === command);
if (!tool) usageError(`Unknown command: ${command}`);

const one = () => (args.length === 1 && !args[0].startsWith('--') ? args[0] : usageError(`Usage: ${forms[command]}`));
let input;
if (command === 'search') {
  if (!args.length) usageError(`Usage: ${forms.search}`);
  input = { query: args.join(' ') };
} else if (command === 'read') input = { operationId: one() };
else if (command === 'schema') input = { name: one() };
else if (command === 'usedBy') input = { target: one() };
else if (args[0] === '--tag' || args[0] === '--status') {
  if (args.length !== 2) usageError(`Usage: ${forms.where}`);
  input = { [args[0].slice(2)]: args[1] };
  if (input.status && !['live', 'stub', 'none'].includes(input.status)) usageError('status is live, stub or none');
} else input = { operationId: one() };

const result = await tool.handler(input);
console.log(result.content[0].text);
process.exit(result.isError ? 1 : 0);
