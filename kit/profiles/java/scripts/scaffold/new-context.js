// scripts/scaffold/new-context.sh: scaffold a new bounded context, the module set the repo's own templates describe.
//   node new-context.js <repo root> [--<flag>]... <capability> <Ctx> <basePackage> [<arg>]...
// What a context is comes from the `context` object of docs/scaffold-templates/project/scaffold.json, a file of the
// repo's own (a project profile of the kit may ship it, kept once the repo edits it):
//   "modules": ["domain", ...]          the modules every context gets, each <capability>-<module>
//   "flags": {"gateway": ["gateway"]}   each --<flag> and the modules it adds; the flag is a true/false variable
//   "args": ["apis", ...]               the positional arguments after <basePackage>, each a variable
//   "help": ["e.g. ...", ...]           lines printed under the usage
//   "files": [...]                      in order, each {"template", "target", "vars"} rendered with scripts/scaffold.sh
//                                       (--test when the target is in a test tree), or {"copy": <repo file>, "target"};
//                                       "when": "<flag>" or "!<flag>" renders it only with (without) that flag
//   "register": {"settings": "settings.gradle.kts", "dependents": {"<build file>": ["<module>", ...]}}
//                                       each module in the settings' include( ... ) block, one per line, and
//                                       `implementation(project(":<capability>-<module>"))` after a build file's last
//                                       implementation(project(...)) line
// Variables: capability, Ctx, ctx (Ctx with a lower first letter), basePackage, path (basePackage as directories),
// each arg and each flag. In a target, a vars value or a copy source, {{name}} is replaced by the value; a vars string
// that is nothing but one {{name}} takes the value itself, so a flag stays a boolean for a {{#section}}.
// Everything is checked before the first file is written: the arguments, the config, each template and copy source,
// that no module and no target exists and that the build files can be registered in. Exit 0, 1 on a refusal, 2 on bad
// usage.
const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

const CONFIG = 'docs/scaffold-templates/project/scaffold.json';
// the trees scripts/scaffold.sh --test accepts
const TEST_TREE = /(^|\/)(src\/test|src\/testFixtures|test)\//;
const fail = msg => {
  console.error(`[new-context] ${msg}`);
  process.exit(1);
};

function loadContext(root) {
  const file = path.join(root, CONFIG);
  if (!fs.existsSync(file))
    fail(
      `no ${CONFIG}: its "context" object says which modules and files a context gets (kit/SPEC.md, Scaffold scripts)`
    );
  let cfg;
  try {
    cfg = JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (e) {
    fail(`${CONFIG} is not valid JSON: ${e.message}`);
  }
  const c = cfg && cfg.context;
  if (!c || typeof c !== 'object') fail(`${CONFIG} has no "context" object`);
  const list = (v, name) => {
    if (v === undefined) return [];
    if (!Array.isArray(v) || v.some(x => typeof x !== 'string'))
      fail(`${CONFIG}: context.${name} must be a list of names`);
    return v;
  };
  const modules = list(c.modules, 'modules');
  if (!modules.length) fail(`${CONFIG}: context.modules names no module`);
  const flags = c.flags === undefined ? {} : c.flags;
  if (typeof flags !== 'object' || Array.isArray(flags))
    fail(`${CONFIG}: context.flags must be an object`);
  for (const [f, mods] of Object.entries(flags)) {
    if (!/^[a-z][a-z0-9-]*$/.test(f)) fail(`${CONFIG}: flag "${f}" must be kebab-case`);
    list(mods, `flags.${f}`);
  }
  if (!Array.isArray(c.files) || !c.files.length) fail(`${CONFIG}: context.files names no file`);
  return {
    modules,
    flags,
    args: list(c.args, 'args'),
    help: list(c.help, 'help'),
    files: c.files,
    register: c.register || {},
  };
}

function usage(ctx) {
  const flags = Object.keys(ctx.flags).map(f => `[--${f}]`);
  const line = [
    'scripts/scaffold/new-context.sh',
    ...flags,
    '<capability>',
    '<Ctx>',
    '<basePackage>',
    ...ctx.args.map(a => `<${a}>`),
  ];
  console.error(`Usage: ${line.join(' ')}`);
  for (const h of ctx.help) console.error(`  ${h}`);
  process.exit(2);
}

// {{name}} in a string; a string that is one {{name}} keeps the value's own type
function fill(value, vars, where) {
  if (typeof value === 'string') {
    const whole = /^\{\{\s*([A-Za-z][\w-]*)\s*\}\}$/.exec(value);
    const get = name => {
      if (!(name in vars))
        fail(
          `${CONFIG}: ${where} names {{${name}}}, which is no variable (${Object.keys(vars).join(', ')})`
        );
      return vars[name];
    };
    if (whole) return get(whole[1]);
    return value.replace(/\{\{\s*([A-Za-z][\w-]*)\s*\}\}/g, (_, n) => String(get(n)));
  }
  if (Array.isArray(value)) return value.map((v, i) => fill(v, vars, `${where}[${i}]`));
  if (value && typeof value === 'object')
    return Object.fromEntries(
      Object.entries(value).map(([k, v]) => [k, fill(v, vars, `${where}.${k}`)])
    );
  return value;
}

const safe = t => !/^(\/|[A-Za-z]:)/.test(t) && !t.split('/').includes('..');

function main() {
  const [root, ...argv] = process.argv.slice(2);
  const ctx = loadContext(root);
  const on = {};
  for (const f of Object.keys(ctx.flags)) on[f] = false;
  const pos = [];
  for (const a of argv) {
    const m = /^--([a-z][a-z0-9-]*)$/.exec(a);
    if (m && m[1] in ctx.flags) on[m[1]] = true;
    else if (a.startsWith('--')) usage(ctx);
    else pos.push(a);
  }
  if (pos.length !== 3 + ctx.args.length) usage(ctx);
  const [cap, Ctx, base, ...rest] = pos;
  if (!/^[a-z][a-z0-9-]*$/.test(cap)) fail(`capability must be kebab-case: ${cap}`);
  if (!/^[A-Z][A-Za-z0-9]*$/.test(Ctx)) fail(`Ctx must be PascalCase: ${Ctx}`);
  if (!/^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)*$/.test(base)) fail(`invalid base package: ${base}`);
  const vars = {
    capability: cap,
    Ctx,
    ctx: Ctx[0].toLowerCase() + Ctx.slice(1),
    basePackage: base,
    path: base.replace(/\./g, '/'),
    ...Object.fromEntries(ctx.args.map((a, i) => [a, rest[i]])),
    ...on,
  };

  const modules = [...ctx.modules];
  for (const [f, mods] of Object.entries(ctx.flags))
    if (on[f]) modules.push(...mods.filter(m => !modules.includes(m)));
  for (const m of modules)
    if (fs.existsSync(path.join(root, `${cap}-${m}`))) fail(`module exists, refusing: ${cap}-${m}`);

  // the files, checked before any is written
  const jobs = [];
  ctx.files.forEach((f, i) => {
    const where = `context.files[${i}]`;
    if (!f || typeof f !== 'object' || typeof f.target !== 'string')
      fail(`${CONFIG}: ${where} needs a "target"`);
    if (f.when !== undefined) {
      const w = /^(!?)([a-z][a-z0-9-]*)$/.exec(String(f.when));
      if (!w || !(w[2] in ctx.flags))
        fail(`${CONFIG}: ${where}.when must name a flag, or ! and a flag: ${f.when}`);
      if (on[w[2]] === (w[1] === '!')) return;
    }
    const target = fill(f.target, vars, `${where}.target`);
    if (!safe(target))
      fail(`${CONFIG}: ${where}.target must be a relative path inside the repo: ${target}`);
    if (fs.existsSync(path.join(root, target))) fail(`target exists, refusing: ${target}`);
    if (typeof f.copy === 'string') {
      const from = fill(f.copy, vars, `${where}.copy`);
      if (!safe(from) || !fs.existsSync(path.join(root, from)))
        fail(`${CONFIG}: ${where}.copy names no file of the repo: ${from}`);
      jobs.push({ copy: from, target });
    } else if (typeof f.template === 'string') {
      const tpl = path.join(root, 'docs/scaffold-templates', `${f.template}.mustache`);
      if (!fs.existsSync(tpl)) fail(`${CONFIG}: ${where} names no template: ${f.template}`);
      jobs.push({ template: f.template, target, vars: fill(f.vars || {}, vars, `${where}.vars`) });
    } else fail(`${CONFIG}: ${where} needs a "template" or a "copy"`);
  });

  // the registration, checked before any file is written
  const reg = ctx.register;
  const edits = [];
  if (reg.settings !== undefined) {
    const file = String(reg.settings);
    const text = fs.existsSync(path.join(root, file))
      ? fs.readFileSync(path.join(root, file), 'utf8')
      : null;
    const m = text === null ? null : /include\(\n([\s\S]*?)\n\)/.exec(text);
    if (!m) fail(`no include( ... ) block in ${file}`);
    const items = m[1]
      .split('\n')
      .map(l => l.trim().replace(/,$/, ''))
      .filter(Boolean);
    for (const mod of modules)
      if (!items.includes(`"${cap}-${mod}"`)) items.push(`"${cap}-${mod}"`);
    edits.push({
      file,
      text: text.replace(m[0], `include(\n${items.map(i => `    ${i}`).join(',\n')}\n)`),
    });
  }
  for (const [file, mods] of Object.entries(reg.dependents || {})) {
    const full = path.join(root, file);
    if (!fs.existsSync(full)) fail(`no ${file} to register the context in`);
    const lines = fs.readFileSync(full, 'utf8').split('\n');
    for (const mod of mods) {
      if (!modules.includes(mod))
        fail(`${CONFIG}: register.dependents names "${mod}", which is no module of this context`);
      const dep = `    implementation(project(":${cap}-${mod}"))`;
      if (lines.includes(dep)) continue;
      const last = lines
        .map((l, i) => (/^\s*implementation\(project\(":/.test(l) ? i : -1))
        .filter(i => i >= 0)
        .pop();
      if (last === undefined) fail(`no implementation(project(...)) line in ${file}`);
      lines.splice(last + 1, 0, dep);
    }
    edits.push({ file, text: lines.join('\n') });
  }

  for (const j of jobs) {
    if (j.copy) {
      fs.mkdirSync(path.dirname(path.join(root, j.target)), { recursive: true });
      fs.copyFileSync(path.join(root, j.copy), path.join(root, j.target));
      console.log(`[new-context] ${j.target} (copy of ${j.copy})`);
      continue;
    }
    const args = [path.join(root, 'scripts/scaffold.sh')];
    if (TEST_TREE.test(j.target)) args.push('--test');
    args.push(j.template, JSON.stringify(j.vars), j.target);
    const r = spawnSync('bash', args, { cwd: root, stdio: 'inherit' });
    if (r.status !== 0)
      fail(
        `scripts/scaffold.sh refused ${j.target}; the files above it are written, the build files not yet registered`
      );
  }
  for (const e of edits) fs.writeFileSync(path.join(root, e.file), e.text);
  if (edits.length)
    console.log(
      `[new-context] registered ${modules.map(m => `${cap}-${m}`).join(', ')} in ${edits.map(e => e.file).join(' and ')}`
    );
}

main();
