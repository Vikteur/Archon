/**
 * Install a locally built provider plugin binary the way `archon provider add`
 * would: binary plus a receipt under `<ARCHON_HOME>/plugins`. Used by
 * scripts/install-local.sh, because a fork build has no release to download.
 *
 * Usage (from the repo root, ARCHON_HOME set by the caller):
 *   bun scripts/install-local-provider.ts <provider-id> <binary-path>
 */
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { getPluginsPath } from '../packages/paths/src/env-loader';
import {
  maintainedProviderPluginId,
  pluginManifestSchema,
} from '../packages/plugin-manifest/src/index';
import { scanReceipts } from '../packages/plugin-manifest/src/store';
import { MAINTAINED_PROVIDER_IDS } from '../packages/provider-contract/src/registration';
import { installBinaryPlugin } from '../packages/cli/src/commands/plugin-binary';
import {
  parsePluginRef,
  type ResolvedBinarySource,
} from '../packages/cli/src/commands/plugin-source';
import packageJson from '../package.json';

const [id, binaryPath] = Bun.argv.slice(2);
if (!id || !binaryPath || !(MAINTAINED_PROVIDER_IDS as readonly string[]).includes(id)) {
  throw new Error(
    `Usage: install-local-provider.ts <${MAINTAINED_PROVIDER_IDS.join('|')}> <binary>`
  );
}
const providerId = id as (typeof MAINTAINED_PROVIDER_IDS)[number];
const version = packageJson.version;
const ref = parsePluginRef(`${maintainedProviderPluginId(providerId)}@v${version}`);
const manifest = pluginManifestSchema.parse(
  JSON.parse(readFileSync(join('plugins', `provider-${id}`, 'archon-plugin.json'), 'utf8'))
);
if (manifest.kind === 'workflow-pack') throw new Error('not a binary plugin');
const commit = execFileSync('git', ['rev-parse', 'HEAD'], { encoding: 'utf8' }).trim();
const source: ResolvedBinarySource = { kind: manifest.kind, tag: `v${version}`, commit, manifest };

const bytes = new Uint8Array(readFileSync(resolve(binaryPath)));
const pluginsDir = getPluginsPath();
const { receipts, broken } = await scanReceipts(pluginsDir);
const previous = receipts.find(receipt => receipt.id === ref.id);
await installBinaryPlugin(
  ref,
  source,
  receipts,
  broken,
  previous,
  { pluginsDir, archonVersion: version, projectDir: process.cwd() },
  () =>
    Promise.resolve({
      bytes,
      sha256: createHash('sha256').update(bytes).digest('hex'),
      label: binaryPath,
      digestSource: 'the local build',
    })
);
