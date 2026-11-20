// Audit adapter for Copilot runs (P2: a script, not a model). Claude Code's PostToolUse hook writes the audit trail the
// gates read (.apm-audit/sessions/<session>.jsonl: skill-check.js, step-check.js, scaffold-check.js). The Copilot CLI
// reads the hooks of .claude/settings.json too, but whether a session under Archon fires them is unverified, and a hook
// trail may hold only some tools. This rebuilds one from the run's Archon log, whose provider_event lines carry the
// tool calls (Archon's copilot provider logs `tool.execution_start` as {type:"tool_call", name, rawInput}).
//   node copilot-audit.js <run-id>           write .apm-audit/sessions/copilot-<run-id>.jsonl in the current directory
//   node copilot-audit.js --names <run-id>   list the tool names the run log holds, with how each one maps
// The file is rewritten whole on every call (idempotent), with records in the shape audit-log.sh writes; `agent` is the
// node the call ran in (the hooks write the node too, from KIT_NODE or ARCHON_NODE_EXECUTION, plus a "node" field; records
// from before that say "main", so copilot-usage.js still joins a trail to a node by its session id). Which Copilot
// tool is which Claude tool is .archon/copilot/tools.json (COPILOT_TOOLS overrides the path), never code here.
// Fallback only: audit-log.sh may already have written this run's trail. The hooks cover the run only when a session file
// other than copilot-*.jsonl holds a Skill record (tool === 'Skill', what skill-check.js needs) stamped at or after the
// run's first log line: then any copilot-<run-id>.jsonl written earlier is removed and nothing is written (never both).
// Hook records of other tools alone (say Bash) do not cover the run: the adapter still writes its file.
// Prints nothing on stdout (the gate node after it prints JSON). Fails closed with exit 3 when the log holds no tool
// calls, or none that tools.json maps: the gates would otherwise fail on a trail that is silently empty.
// Exit 0 written, 2 usage or unreadable tools.json, 3 nothing to audit.
const fs = require('fs');
const path = require('path');
const { findLog } = require('./run-trace.js');

const TOOLS = process.env.COPILOT_TOOLS || path.join(__dirname, '..', 'copilot', 'tools.json');

function loadMap() {
  const cfg = JSON.parse(fs.readFileSync(TOOLS, 'utf8'));
  const ev = { type: 'tool_call', nameField: 'name', inputField: 'rawInput', ...(cfg.event || {}) };
  const tools = new Map();
  for (const [name, m] of Object.entries(cfg.tools || {})) tools.set(name.toLowerCase(), typeof m === 'string' ? { as: m } : m);
  return { ev, tools };
}

// The Claude shape of one tool_call event: { name, input }. A name tools.json maps takes the Claude name, and its key is
// filled from the first source field that holds a string; any other name and its input stay as they are. run-trace.js and
// mcp-use-check.js read Copilot runs through it.
function claudeCall(e, { ev, tools }) {
  const name = String(e[ev.nameField] || e.name || '');
  const raw = e[ev.inputField] && typeof e[ev.inputField] === 'object' ? e[ev.inputField] : {};
  const m = tools.get(name.toLowerCase());
  if (!m) return { name, input: raw };
  const input = { ...raw };
  if (m.key && !(typeof input[m.key] === 'string' && input[m.key])) {
    const src = (m.from || [m.key]).find(k => typeof raw[k] === 'string' && raw[k]);
    if (src) input[m.key] = raw[src];
  }
  return { name: m.as, input };
}

const cut = (s, n) => (s.length > n ? [s.slice(0, n), true] : [s, false]);

// { records: [...], names: Map<name, count>, calls }: one TOOL record per mapped tool call
function audit(text, runId, { ev, tools }) {
  const failed = new Set();
  const lines = [];
  for (const l of text.split('\n')) {
    let o;
    try { o = JSON.parse(l); } catch { continue; }
    if (o.type !== 'provider_event' || !o.event) continue;
    if (o.event.type === 'tool_call_update' && o.event.status === 'failed') failed.add(o.event.toolCallId);
    else if (o.event.type === ev.type) lines.push(o);
  }
  const names = new Map();
  const records = [];
  for (const o of lines) {
    const e = o.event;
    const name = String(e[ev.nameField] || '');
    names.set(name, (names.get(name) || 0) + 1);
    const m = tools.get(name.toLowerCase());
    if (!m) continue;
    const input = e[ev.inputField] && typeof e[ev.inputField] === 'object' ? e[ev.inputField] : {};
    let arg = input;
    if (m.key) {
      const src = (m.from || [m.key]).find(k => typeof input[k] === 'string' && input[k]);
      arg = src ? { [m.key]: input[src] } : {};
    }
    const [argText, argCut] = cut(JSON.stringify(arg), m.key === 'command' ? 200 : 1024);
    const t = Date.parse(o.ts || o.observedAt || e.observedAt || '');
    const rec = {
      type: 'TOOL', event: 'postToolUse', session: `copilot-${runId}`, agent: String(o.step || 'main'), ts: o.ts || '',
      loggedAt: t ? new Date(t).toISOString().replace(/\.\d+Z$/, 'Z') : '', tool: m.as, arg: argText,
    };
    if (argCut) rec.argCut = true;
    rec.ok = !failed.has(e.toolCallId);
    records.push(rec);
  }
  return { records, names, calls: lines.length, tools };
}

// true when a hook-written session file (not copilot-*.jsonl) holds a Skill TOOL record at or after the run's start
function hooksCover(dir, text) {
  let start = 0;
  for (const l of text.split('\n')) {
    try { const t = Date.parse(JSON.parse(l).ts || ''); if (t) { start = t; break; } } catch { /* garbled line */ }
  }
  let files = [];
  try { files = fs.readdirSync(dir).filter(f => f.endsWith('.jsonl') && !f.startsWith('copilot-')); } catch { return false; }
  for (const f of files) {
    for (const l of fs.readFileSync(path.join(dir, f), 'utf8').split('\n')) {
      if (!l.includes('"type":"TOOL"')) continue;
      try {
        const r = JSON.parse(l);
        const t = Date.parse(r.loggedAt || '');
        if (r.type === 'TOOL' && r.tool === 'Skill' && t && t >= start - 1000) return true;
      } catch { /* partial line */ }
    }
  }
  return false;
}

function main(argv) {
  const listNames = argv[0] === '--names';
  const runId = listNames ? argv[1] : argv[0];
  if (!runId) { console.error('usage: node copilot-audit.js [--names] <run-id>'); return 2; }
  let map;
  try { map = loadMap(); } catch (e) { console.error(`copilot-audit: cannot read ${TOOLS}: ${e.message}`); return 2; }
  const log = findLog(runId);
  if (!log) { console.error(`copilot-audit: no Archon log for run ${runId}; refusing to continue without an audit trail`); return 3; }
  const text = fs.readFileSync(log, 'utf8');
  const dir = path.join(process.cwd(), '.apm-audit', 'sessions');
  const target = path.join(dir, `copilot-${runId}.jsonl`);
  if (!listNames && hooksCover(dir, text)) {
    try { fs.unlinkSync(target); } catch { /* none written */ }
    return 0;
  }
  const r = audit(text, runId, map);
  if (listNames) {
    for (const [n, c] of r.names) console.log(`${n}\t${c}\t${map.tools.has(n.toLowerCase()) ? `-> ${map.tools.get(n.toLowerCase()).as}` : 'unmapped'}`);
    return 0;
  }
  if (!r.calls) { console.error(`copilot-audit: the log of run ${runId} holds no tool calls (event type ${map.ev.type}); check ${path.relative(process.cwd(), TOOLS)} against the provider events in ${log}`); return 3; }
  if (!r.records.length) {
    console.error(`copilot-audit: ${r.calls} tool calls in the log of run ${runId}, none maps through ${path.relative(process.cwd(), TOOLS)}; names seen: ${[...r.names.keys()].join(', ')}`);
    return 3;
  }
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(`${target}.tmp`, r.records.map(x => JSON.stringify(x)).join('\n') + '\n');
  fs.renameSync(`${target}.tmp`, target);
  return 0;
}

if (require.main === module) process.exit(main(process.argv.slice(2)));
module.exports = { audit, loadMap, claudeCall };
