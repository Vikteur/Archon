// kit-config.js — read one key of .archon/kit.yaml from a Node script, with an environment override and a default (the
// node twin of kit-config.sh, no dependencies). Only what the run tooling needs: top-level and one-level nested scalar
// keys (`build_workflow`, `contract.repo`), quotes and trailing comments stripped.
//   const { kitGet } = require('./kit-config');
//   kitGet('build_workflow', 'build-feature', 'BUILD_WORKFLOW')   // env BUILD_WORKFLOW, else kit.yaml, else the default
// The env name defaults to KIT_<KEY upper-cased, dots as underscores>. The file is $KIT_CONFIG, else
// <repo root>/.archon/kit.yaml (the root is this file's grandparent folder). A key it leaves out is read from
// kit.defaults.yaml beside it (the kit's shipped defaults), as kit-config.sh does.
const fs = require('fs');
const path = require('path');

function kitFile(root) {
  return process.env.KIT_CONFIG || path.join(root || path.resolve(__dirname, '..', '..'), '.archon', 'kit.yaml');
}

function readKey(text, key) {
  const [top, sub] = key.split('.');
  let inTop = false;
  for (const raw of text.split(/\r?\n/)) {
    if (!raw.trim() || /^\s*#/.test(raw)) continue;
    const m = /^(\s*)([A-Za-z0-9_-]+):\s*(.*)$/.exec(raw);
    if (!m) continue;
    const [, indent, name, rest] = m;
    const value = rest.replace(/\s+#.*$/, '').trim().replace(/^(["'])(.*)\1$/, '$2');
    if (indent.length === 0) {
      inTop = name === top;
      if (inTop && sub === undefined) return value === 'null' || value === '~' ? '' : value;
    } else if (inTop && sub !== undefined && name === sub) return value === 'null' || value === '~' ? '' : value;
  }
  return '';
}

// a boolean in any case (False, TRUE) is the lower-case word, as YAML and `archon kit add` read it
const bool = v => (/^(true|false)$/i.test(v) ? v.toLowerCase() : v);

function kitGet(key, def, envName, root) {
  const env = process.env[envName || `KIT_${key.toUpperCase().replace(/\./g, '_')}`];
  if (env) return bool(env);
  let v = '';
  const file = kitFile(root);
  for (const f of [file, path.join(path.dirname(file), 'kit.defaults.yaml')]) {
    try { v = readKey(fs.readFileSync(f, 'utf8'), key); } catch { v = ''; /* no file: the next one, then the default */ }
    if (v) break;
  }
  return bool(v || def);
}

module.exports = { kitGet, readKey };
