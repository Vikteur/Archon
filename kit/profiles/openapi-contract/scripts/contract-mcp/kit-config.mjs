// The kit's project config for the contract MCP server: .archon/kit.yaml (optional), with env overrides and
// today's values as defaults, so a checkout with no kit.yaml behaves exactly as before. Keys are dotted
// (`contract.spec_path`); the env override of a key is KIT_ plus the key upper-cased with dots as underscores
// (KIT_CONTRACT_SPEC_PATH). Pure file read, no network.
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { parse } from 'yaml';

export const DEFAULTS = {
  'project_name': 'app',
  'contract.spec_path': 'contract/dist/openapi.yaml',
  'contract.repo': '@@KIT_CONTRACT_REPO@@',
  'contract.tag_key': '@@KIT_CONTRACT_TAG_KEY@@',
  'contract.generated_dir': 'shared-adapter/build/generated/openapi/src/gen/java/com/example/api',
  'contract.api_package': 'com.example.api',
  'contract.server_name': '@@KIT_CONTRACT_SERVER_NAME@@',
};

export function kitConfig(root, env = process.env) {
  let doc = {};
  try { doc = parse(readFileSync(env.KIT_CONFIG || path.join(root, '.archon', 'kit.yaml'), 'utf8')) ?? {}; } catch { /* no file: defaults */ }
  return (key) => {
    const fromEnv = env[`KIT_${key.toUpperCase().replace(/\./g, '_')}`];
    if (fromEnv) return fromEnv;
    const v = key.split('.').reduce((o, k) => (o && typeof o === 'object' ? o[k] : undefined), doc);
    return typeof v === 'string' && v !== '' ? v : DEFAULTS[key];
  };
}
