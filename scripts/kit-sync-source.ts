/**
 * kit-sync's inputs: the source repo read from its HEAD commit (git-tracked files only), and the hand-written overlays
 * under kit/overlays (kit/SPEC.md, Generator). scripts/kit-sync.ts builds the kit from them.
 */
import { createHash } from 'node:crypto';
import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs';
import { basename, join, relative } from 'node:path';
import { PROFILES, type Profile, SCANNED_ROOTS } from './kit-sync-lists';
// ---------------------------------------------------------------------------------------------------------------
// Reading the source
// ---------------------------------------------------------------------------------------------------------------

export interface SourceFile {
  path: string;
  gitMode: string;
  content: Buffer;
}

export interface Source {
  dir: string;
  name: string;
  commit: string;
  files: Map<string, SourceFile>;
}

function git(dir: string, args: string[], input?: string): Buffer {
  const r = Bun.spawnSync(['git', '-C', dir, ...args], {
    stdin: input === undefined ? 'ignore' : Buffer.from(input),
    stdout: 'pipe',
    stderr: 'pipe',
  });
  if (r.exitCode !== 0)
    throw new Error(`git ${args.join(' ')} failed in ${dir}: ${r.stderr.toString().trim()}`);
  return r.stdout;
}

function repoName(dir: string): string {
  let name = '';
  try {
    name = basename(git(dir, ['config', '--get', 'remote.origin.url']).toString().trim());
  } catch {
    name = '';
  }
  name = name.replace(/\.git$/, '');
  return name || basename(git(dir, ['rev-parse', '--show-toplevel']).toString().trim());
}

interface TreeEntry {
  path: string;
  gitMode: string;
  sha: string;
}

/** The blobs of HEAD under the scanned roots. */
function treeEntries(dir: string): TreeEntry[] {
  const entries: TreeEntry[] = [];
  for (const rec of git(dir, ['ls-tree', '-r', '-z', 'HEAD']).toString().split('\0')) {
    const tab = rec.indexOf('\t');
    if (tab < 0) continue;
    const [mode, type, sha] = rec.slice(0, tab).split(' ');
    const path = rec.slice(tab + 1);
    if (type === 'blob' && SCANNED_ROOTS.some(r => path.startsWith(r)))
      entries.push({ path, gitMode: mode ?? '', sha: sha ?? '' });
  }
  return entries;
}

/** One `git cat-file --batch` for every entry, in order. */
function readBlobs(dir: string, entries: TreeEntry[]): Map<string, SourceFile> {
  const files = new Map<string, SourceFile>();
  if (!entries.length) return files;
  const out = git(dir, ['cat-file', '--batch'], `${entries.map(e => e.sha).join('\n')}\n`);
  let pos = 0;
  for (const e of entries) {
    const nl = out.indexOf(10, pos);
    const header = out.subarray(pos, nl).toString();
    const size = Number(header.split(' ')[2]);
    if (!Number.isFinite(size)) throw new Error(`git cat-file: bad header ${header}`);
    const content = Buffer.from(out.subarray(nl + 1, nl + 1 + size));
    files.set(e.path, { path: e.path, gitMode: e.gitMode, content });
    pos = nl + 1 + size + 1;
  }
  return files;
}

export function readSource(dir: string): Source {
  const commit = git(dir, ['rev-parse', 'HEAD']).toString().trim();
  return { dir, name: repoName(dir), commit, files: readBlobs(dir, treeEntries(dir)) };
}

/** Source paths that differ between the work tree and HEAD (kit-sync reads HEAD, so these are not in the kit). */
export function uncommitted(dir: string): string[] {
  return git(dir, ['status', '--porcelain', '--', ...SCANNED_ROOTS])
    .toString()
    .split('\n')
    .filter(Boolean)
    .map(l => l.slice(3));
}

export const sha256 = (s: string | Buffer): string => createHash('sha256').update(s).digest('hex');

export interface OverlayEntry {
  derivedFrom: string | null;
  sourceSha256: string | null;
  /** `kit add` writes the file only when the project has none, even with --force (kit/SPEC.md, manifest.json). */
  createOnly?: boolean;
}

export function walk(dir: string, base = dir): string[] {
  if (!existsSync(dir)) return [];
  const out: string[] = [];
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    const full = join(dir, e.name);
    if (e.isDirectory()) out.push(...walk(full, base));
    else if (e.isFile()) out.push(relative(base, full).split('\\').join('/'));
  }
  return out.sort();
}

export interface OverlayFile {
  profile: Profile;
  path: string;
  content: string;
  executable: boolean;
  entry: OverlayEntry;
}

function readOverlayList(dir: string): Record<string, OverlayEntry> {
  const listFile = join(dir, 'overlay.json');
  if (!existsSync(listFile)) return {};
  return JSON.parse(readFileSync(listFile, 'utf8')) as Record<string, OverlayEntry>;
}

function readOverlayProfile(overlaysDir: string, profile: string): OverlayFile[] {
  const dir = join(overlaysDir, profile);
  if (!(PROFILES as readonly string[]).includes(profile))
    throw new Error(`kit/overlays/${profile}: not a profile`);
  const list = readOverlayList(dir);
  const files = walk(dir).filter(p => p !== 'overlay.json');
  const missing = Object.keys(list).find(p => !files.includes(p));
  if (missing)
    throw new Error(`kit/overlays/${profile}/overlay.json lists ${missing}, which is missing`);
  return files.map(p => {
    const entry = list[p];
    if (!entry) throw new Error(`kit/overlays/${profile}/${p}: not listed in overlay.json`);
    const full = join(dir, p);
    const executable = (statSync(full).mode & 0o111) !== 0;
    return {
      profile: profile as Profile,
      path: p,
      content: readFileSync(full, 'utf8'),
      executable,
      entry,
    };
  });
}

/** `kit/overlays/<profile>/**`: every file (but overlay.json) listed in overlay.json, and every entry present. */
export function readOverlays(overlaysDir: string): OverlayFile[] {
  if (!existsSync(overlaysDir)) return [];
  return readdirSync(overlaysDir)
    .sort()
    .filter(profile => statSync(join(overlaysDir, profile)).isDirectory())
    .flatMap(profile => readOverlayProfile(overlaysDir, profile));
}

/** Overlays whose derivedFrom source file changed since the overlay was written. */
export function staleOverlays(overlays: OverlayFile[], src: Source): string[] {
  const out: string[] = [];
  for (const o of overlays) {
    if (!o.entry.derivedFrom) continue;
    const f = src.files.get(o.entry.derivedFrom);
    const now = f ? sha256(f.content) : null;
    if (now !== o.entry.sourceSha256)
      out.push(
        `${o.profile}/${o.path}: derivedFrom ${o.entry.derivedFrom} ${now ? `is now ${now}` : 'is gone'} (overlay records ${o.entry.sourceSha256})`
      );
  }
  return out;
}
