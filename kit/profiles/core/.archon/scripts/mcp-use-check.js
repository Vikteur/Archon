// Did the explore and plan nodes ask the MCP servers, or search by hand? (docs/mcp/plan.md, C8; P2: a script, not a
// model.) Reads the run's Archon log (every tool call of every node) and writes <artifacts-dir>/mcp-use.md: per node,
// its calls to the contract server and CodeGraph against its Grep, Glob and Bash searches, its contract reads and its whole Java
// reads, and a verdict. pr-refresh.sh copies the report into the pull request.
//   node mcp-use-check.js <artifacts-dir> <run-id> [<node>...]   (default nodes: explore plan)
//   --strict   exit 1 when a node is warned (not yet used: the report mode comes first, as for tool-advice.sh, D5)
// Each Grep, Glob and Bash search (grep, sed, cat, find, ... as the first stage of a command) is sorted by what it names:
// docs (docs/, a .md file, the run's artifacts: CodeGraph does not index them, so reading them by hand is right), the
// contract (contract/, openapi.yaml, an operationId) or code (anything else). A Read of a .java file with no offset or
// limit is a whole Java read. Hand work is the code searches plus the whole Java reads.
// A Bash call to the codegraph CLI or to scripts/contract-mcp/cli.mjs counts as a call to that server.
// A node is warned when a server was up (the last "mcp: ..." line of <artifacts-dir>/mcp-status.txt) and the node
//   - did hand work at least its threshold of times (explore 8, plan 5, any other node 8) and never called CodeGraph, or
//   - read the contract by hand and never called the contract server.
// The contract server is contract.server_name of .archon/kit.yaml (default @@KIT_CONTRACT_SERVER_NAME@@); the status line names it too.
// A server that was down, or no status file at all, skips the rules that need it. No log, or a node with no tool call,
// is reported as such. Exits 0 (2 on a usage error), also when it cannot read the log: it never holds a run.
const fs = require('fs');
const path = require('path');
const { findLog } = require('./run-trace.js');
const { kitGet } = require('./kit-config.js');

const SERVER = kitGet('contract.server_name', '@@KIT_CONTRACT_SERVER_NAME@@');

const HAND_MIN = { explore: 8, plan: 5 };
const HAND_MIN_DEFAULT = 8;
// A Bash command whose first pipeline stage is one of these reads or searches files by hand; `| grep` after another
// command filters that command's output and is not counted.
const SEARCH_PROGS = new Set(['grep', 'egrep', 'fgrep', 'rg', 'ag', 'find', 'sed', 'awk', 'cat', 'head', 'tail', 'less']);
const MCP_LINE = /^mcp: (\S+) (up|down), codegraph (up|down)$/;
const CONTRACT = /(^|[\s/'"=])contract(\/|$|\s)|openapi\.ya?ml|operationId/;
const DOCS = /(^|[\s/'"=])docs\/|\.md\b|ARTIFACTS_DIR|\/artifacts\//;
// A Bash call that is the shell fallback of an MCP server (Copilot CLI blocks them): the codegraph CLI and the contract
// server's cli.mjs (contract-mcp, or the kit's renamed contract-mcp), after an optional `rtk ` or `rtk proxy `.
const CODEGRAPH_CLI = /^(?:rtk\s+(?:proxy\s+)?)?codegraph\s+(?:explore|node|callers|callees|impact|query)\s/;
const SERVER_CLI = /^(?:rtk\s+(?:proxy\s+)?)?node\s+(?:\.\/)?scripts\/(?:portal|contract)-mcp\/cli\.mjs\s/;
const kind = text => (CONTRACT.test(text) ? 'contract' : DOCS.test(text) ? 'docs' : 'code');

function servers(art) {
  let text;
  try { text = fs.readFileSync(path.join(art, 'mcp-status.txt'), 'utf8'); } catch { return null; }
  const m = text.split('\n').map(l => MCP_LINE.exec(l.trim())).filter(Boolean).pop();
  return m ? { server: m[1], contract: m[2] === 'up', codegraph: m[3] === 'up' } : null;
}

// The first pipeline stage of each command of a Bash line, without `VAR=value` prefixes
function stages(command) {
  return String(command || '').split(/;|&&|\|\||\n/)
    .map(seg => seg.split('|')[0].trim().replace(/^(?:[A-Za-z_][\w]*=\S*\s+)+/, ''))
    .filter(Boolean);
}

const rel = p => String(p || '').replace(/\\/g, '/').replace(/^.*?\/(?:worktrees|runs)\/[^/]+\//, '');

function newCounts() {
  return { calls: 0, server: 0, codegraph: 0, grep: 0, glob: 0, bash: 0, contract: 0, whole: 0 };
}

// Map<node, counts> over the log's tool calls; a node id matches its own steps and the steps inside it (implement.*)
function count(text, nodes) {
  const out = new Map(nodes.map(n => [n, newCounts()]));
  for (const l of text.split('\n')) {
    let o;
    try { o = JSON.parse(l); } catch { continue; }
    const e = o && o.event;
    if (!o || o.type !== 'provider_event' || !e || e.type !== 'tool_call') continue;
    const node = nodes.find(n => o.step === n || String(o.step || '').startsWith(`${n}.`));
    if (!node) continue;
    const c = out.get(node);
    const name = String(e.name || '');
    const input = e.rawInput || {};
    c.calls++;
    if (name.startsWith(`mcp__${SERVER}__`)) c.server++;
    else if (name.startsWith('mcp__codegraph__')) c.codegraph++;
    else if (name === 'Grep' || name === 'Glob') {
      // What a search covers: its path and file filter (a Grep's pattern is the text it looks for, not where)
      const where = [rel(input.path), input.glob, input.type === 'md' ? '.md' : '', name === 'Glob' ? input.pattern : ''].filter(Boolean).join(' ');
      const k = kind(where);
      if (k === 'contract') c.contract++;
      else if (k === 'code') c[name === 'Grep' ? 'grep' : 'glob']++;
    } else if (name === 'Read') {
      const f = rel(input.file_path);
      if (f.startsWith('contract/')) c.contract++;
      if (/\.java$/i.test(f) && input.offset === undefined && input.limit === undefined) c.whole++;
    } else if (name === 'Bash') {
      for (const s of stages(input.command)) {
        if (CODEGRAPH_CLI.test(`${s} `)) { c.codegraph++; continue; }
        if (SERVER_CLI.test(`${s} `)) { c.server++; continue; }
        const prog = s.split(/\s+/)[0].replace(/^.*\//, '');
        if (!SEARCH_PROGS.has(prog)) continue;
        const k = kind(s);
        if (k === 'contract') c.contract++;
        else if (k === 'code') c.bash++;
      }
    }
  }
  return out;
}

function verdict(node, c, up) {
  if (!c.calls) return 'no tool calls in the log';
  if (!up) return 'not judged: no MCP status for this run';
  const why = [];
  const hand = c.grep + c.glob + c.bash + c.whole;
  const min = HAND_MIN[node] || HAND_MIN_DEFAULT;
  if (up.codegraph && hand >= min && c.codegraph === 0) why.push(`searched or read code by hand ${hand} times (threshold ${min}) and never asked CodeGraph`);
  if (up.contract && c.contract > 0 && c.server === 0) why.push(`read the contract by hand ${c.contract} times and never asked ${up.server}`);
  return why.length ? `WARN: ${why.join('; ')}` : 'ok';
}

function report(nodes, counts, up, logFound) {
  const L = ['# MCP use per node', ''];
  const state = s => (s ? 'up' : 'down');
  L.push(up ? `Servers: ${up.server} ${state(up.contract)}, codegraph ${state(up.codegraph)}.` : 'Servers: no MCP status for this run.');
  if (!logFound) { L.push('', 'No Archon log for this run: nothing counted.', ''); return L.join('\n'); }
  L.push('', `| Node | ${up ? up.server : SERVER} | codegraph | Grep | Glob | Bash searches | Contract reads | Whole Java reads | Verdict |`,
    '| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |');
  for (const n of nodes) {
    const c = counts.get(n);
    L.push(`| ${n} | ${c.server} | ${c.codegraph} | ${c.grep} | ${c.glob} | ${c.bash} | ${c.contract} | ${c.whole} | ${verdict(n, c, up)} |`);
  }
  L.push('');
  return L.join('\n');
}

function main(argv) {
  const strict = argv.includes('--strict');
  const args = argv.filter(a => a !== '--strict');
  if (args.length < 2) {
    console.error('usage: mcp-use-check.js <artifacts-dir> <run-id> [<node>...] [--strict]');
    return 2;
  }
  const [art, runId, ...rest] = args;
  const nodes = rest.length ? rest : ['explore', 'plan'];
  const up = servers(art);
  const log = findLog(runId);
  let text = '';
  try { text = log ? fs.readFileSync(log, 'utf8') : ''; } catch { text = ''; }
  const counts = count(text, nodes);
  const md = report(nodes, counts, up, Boolean(log));
  try { fs.writeFileSync(path.join(art, 'mcp-use.md'), md); } catch (e) { console.error(`mcp-use-check: cannot write the report: ${e.message}`); }
  const warned = nodes.filter(n => verdict(n, counts.get(n), up).startsWith('WARN'));
  for (const n of warned) console.error(`mcp-use-check: ${n}: ${verdict(n, counts.get(n), up)}`);
  console.log(`mcp-use-check: ${warned.length ? `${warned.length} of ${nodes.length} nodes warned` : 'ok'}`);
  return strict && warned.length ? 1 : 0;
}

if (require.main === module) process.exit(main(process.argv.slice(2)));
module.exports = { count, verdict, stages };
