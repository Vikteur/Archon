// The scaffold templates' targets, read from the `## Scaffold` tables of docs/code-maps/*.md: which template renders a
// file at a given path. Shared by scripts/scaffold.sh --for and the scaffold-check gate (.archon/scripts/), so the two
// can never disagree on what fits.
// A Target cell's placeholders: `<capability>` a module prefix, `<pkg>` one or more package directories, `<Name>` (any
// capitalised placeholder) a class name, `<NNN>` digits, any other `<x>` one path segment, `**` anything, `...` the
// previous row's target up to its package; a src/test target also matches src/testFixtures.
const fs = require('fs');
const path = require('path');

const esc = s => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
const cells = line => line.split(/(?<!\\)\|/).slice(1, -1).map(c => c.trim());

// [{ template, file, skill, target, variables, left, re }]: file is the template's path relative to the repo root;
// variables and left are the row's Variables and Left to you cells
function templateTargets(root) {
  const dir = path.join(root, 'docs', 'code-maps');
  let leaves = [];
  try { leaves = fs.readdirSync(dir).filter(f => f.endsWith('.md')); } catch { return []; }
  const rows = [];
  for (const f of leaves) {
    let prev = '';
    for (const line of fs.readFileSync(path.join(dir, f), 'utf8').split(/\r?\n/)) {
      const m = /^\| \[([^\]]+)\]\(\.\.\/(scaffold-templates\/[^)]+\.mustache)\) \| `([^`]+)`/.exec(line);
      if (!m) continue;
      let target = m[3];
      if (target.startsWith('...')) {
        const at = prev.search(/<(?:pkg|package path|pkg path)>/);
        const head = at < 0 ? '' : prev.slice(0, prev.indexOf('>', at) + 1);
        target = head ? head + target.slice(3) : '**' + target.slice(3);
      }
      prev = target;
      rows.push({
        template: m[1], file: path.posix.join('docs', decodeURIComponent(m[2])), skill: f.replace(/\.md$/, ''),
        target, variables: cells(line)[2] || '', left: cells(line)[3] || '', re: targetRegex(target),
      });
    }
  }
  return rows;
}

// The Target as a regex over a repo-relative path. With { capture: true } each `<capability>` and capitalised
// placeholder is a named group (a repeat must match the same text), for scaffold.sh --for to prefill the variables.
function targetRegex(target, { capture = false } = {}) {
  let re = '';
  const seen = new Set();
  const group = (part, body) => {
    const name = part.slice(1, -1).replace(/\W/g, '');
    if (!capture || !/^[A-Za-z]\w*$/.test(name)) return body;
    if (seen.has(name)) return `\\k<${name}>`;
    seen.add(name);
    return `(?<${name}>${body})`;
  };
  for (const part of target.split(/(<[^>]+>|\*\*)/)) {
    if (!part) continue;
    if (part === '**') re += '.+';
    else if (/^<(capability)>$/.test(part)) re += group(part, '[a-z0-9][a-z0-9-]*');
    else if (/^<(pkg|package path|pkg path)>$/.test(part)) re += '[a-z0-9_]+(?:/[a-z0-9_]+)*';
    else if (/^<N+>$/.test(part)) re += '[0-9]+';
    else if (/^<[A-Z]/.test(part)) re += group(part, '[A-Z][A-Za-z0-9]*');
    else if (/^<.+>$/.test(part)) re += '[^/]+';
    else re += esc(part);
  }
  re = re.replace(/\/src\/test\//g, '/src/test(?:Fixtures)?/');
  return new RegExp(`^(?:.+/)?${re}$`);
}

// the templates whose target matches the repo-relative path
function fitting(root, file) {
  const f = String(file).replace(/\\/g, '/').replace(/^\.\//, '');
  return templateTargets(root).filter(t => t.re.test(f));
}

module.exports = { templateTargets, targetRegex, fitting };
