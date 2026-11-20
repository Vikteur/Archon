// The scaffold templates' targets, read from the `## Scaffold` tables of docs/code-maps/*.md: which template renders a
// file at a given path. Shared by scripts/scaffold.sh --for, the scaffold step and the scaffold-check gate
// (.archon/scripts/), so they can never disagree on what fits.
// The repo's own templates live in docs/scaffold-templates/project/, a folder only a project profile of the kit
// writes (kit/SPEC.md, Project profiles), and the repo then owns:
//   - project/<layer>/<name>.mustache beside a kit template <layer>/<name> takes over that template's rows (its Target,
//     Variables and Left to you stay), so a fix to a kit template needs no edit to a kit-owned leaf;
//   - a new template gets its row in the `## Scaffold` table of docs/scaffold-templates/project/README.md, linked
//     relative to that folder: | [project/<layer>/<name>](<layer>/<name>.mustache) | `<Target>` | <Variables> | <Left> |
// The repo's rows come first, so where two Targets are as specific, --for lists the repo's template first.
// "projectOnly": true in docs/scaffold-templates/project/scaffold.json drops every other row: the repo renders only its
// own templates, without editing the kit's leaves.
// A Target cell's placeholders: `<capability>` a module prefix, `<pkg>` one or more package directories, `<Name>` (any
// capitalised placeholder) a class name, `<NNN>` digits, any other `<x>` one path segment, `**` anything, `...` the
// previous row's target up to its package; a src/test target also matches src/testFixtures.
const fs = require('fs');
const path = require('path');

const esc = s => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
const cells = line =>
  line
    .split(/(?<!\\)\|/)
    .slice(1, -1)
    .map(c => c.trim());

const PROJECT = path.posix.join('docs', 'scaffold-templates', 'project');
const ROW = /^\| \[([^\]]+)\]\(([^)]+\.mustache)\) \| `([^`]+)`/;

// The rows of one `## Scaffold` table text; link(href) is the template's path relative to the repo root, or null for a
// link that is not one of the table's templates
function tableRows(text, skill, link) {
  const rows = [];
  let prev = '';
  for (const line of text.split(/\r?\n/)) {
    const m = ROW.exec(line);
    const file = m && link(decodeURIComponent(m[2]));
    if (!file) continue;
    let target = m[3];
    if (target.startsWith('...')) {
      const at = prev.search(/<(?:pkg|package path|pkg path)>/);
      const head = at < 0 ? '' : prev.slice(0, prev.indexOf('>', at) + 1);
      target = head ? head + target.slice(3) : '**' + target.slice(3);
    }
    prev = target;
    rows.push({
      template: m[1],
      file,
      skill,
      target,
      variables: cells(line)[2] || '',
      left: cells(line)[3] || '',
      re: targetRegex(target),
    });
  }
  return rows;
}

const read = file => {
  try {
    return fs.readFileSync(file, 'utf8');
  } catch {
    return null;
  }
};
const exists = (root, file) => fs.existsSync(path.join(root, file));

// [{ template, file, skill, target, variables, left, re }]: file is the template's path relative to the repo root;
// variables and left are the row's Variables and Left to you cells. A row the repo's own template took over also has
// `replaces`, the kit template's name.
function templateTargets(root) {
  const dir = path.join(root, 'docs', 'code-maps');
  let leaves = [];
  try {
    leaves = fs
      .readdirSync(dir)
      .filter(f => f.endsWith('.md'))
      .sort();
  } catch {
    leaves = [];
  }
  const kit = [];
  for (const f of leaves) {
    const href = h =>
      /^\.\.\/scaffold-templates\//.test(h) ? path.posix.join('docs', h.slice(3)) : null;
    kit.push(...tableRows(read(path.join(dir, f)) || '', f.replace(/\.md$/, ''), href));
  }
  const own = [];
  const rest = [];
  for (const r of kit) {
    const name = r.file.slice('docs/scaffold-templates/'.length).replace(/\.mustache$/, '');
    const mine = path.posix.join(PROJECT, `${name}.mustache`);
    if (!name.startsWith('project/') && exists(root, mine))
      own.push({ ...r, template: `project/${name}`, file: mine, replaces: r.template });
    else rest.push(r);
  }
  const readme = read(path.join(root, PROJECT, 'README.md'));
  if (readme !== null) {
    const href = h =>
      /^(\/|[A-Za-z]:)|(^|\/)\.\.(\/|$)/.test(h) ? null : path.posix.join(PROJECT, h);
    for (const r of tableRows(readme, 'project', href)) {
      const template = r.file.slice('docs/scaffold-templates/'.length).replace(/\.mustache$/, '');
      if (!own.some(o => o.template === template && o.target === r.target))
        own.push({ ...r, template });
    }
  }
  return projectOnly(root) ? own : [...own, ...rest];
}

// "projectOnly": true in the repo's scaffold.json (an unreadable file counts as false: the wiring test reports it)
function projectOnly(root) {
  try {
    const c = JSON.parse(read(path.join(root, PROJECT, 'scaffold.json')) || '{}');
    return c !== null && c.projectOnly === true;
  } catch {
    return false;
  }
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
