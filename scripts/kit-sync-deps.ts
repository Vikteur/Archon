/**
 * kit-sync's dependency check (kit/SPEC.md, Dependency check): every profile set `archon kit add` can install must
 * hold the files its shipped scripts read. scripts/kit-sync.ts runs it in --verify (it fails) and in a sync (it
 * reports).
 */
import { CONTRACT_CLI, CONTRACT_CLI_PATH } from './kit-sync-convert';
import { EXCLUSIVE, PROFILE_META, PROFILES, type Profile } from './kit-sync-lists';

export interface DepFile {
  profile: string;
  path: string;
  content: string;
}

/** A set with java builds the project, so it must hold what the CI scripts read; core alone brings its own CI. */
const BUILDS = (set: Profile[]) => set.includes('java');

/** Files a shipped script reads from the project, in every set that builds. */
export const STACK_NEEDS: { script: string; needs: string[] }[] = [
  { script: '.claude/scripts/ci-local.sh', needs: ['.github/workflows/ci.yml'] },
  {
    script: '.claude/scripts/ci-plan.sh',
    needs: ['.github/workflows/ci.yml', '.github/ci-inputs.yml'],
  },
];

/** Every set `archon kit add` accepts: core, closed under `requires`, with at most one profile of an EXCLUSIVE group. */
export function installableSets(): Profile[][] {
  const optional = PROFILES.filter(p => p !== 'core');
  const sets: Profile[][] = [];
  for (let mask = 0; mask < 1 << optional.length; mask++) {
    const set: Profile[] = ['core', ...optional.filter((_, i) => mask & (1 << i))];
    const closed = set.every(p => PROFILE_META[p].requires.every(r => set.includes(r)));
    const exclusive = EXCLUSIVE.every(group => group.filter(p => set.includes(p)).length <= 1);
    if (closed && exclusive) sets.push(set);
  }
  return sets;
}

// A `## Scaffold` row of a code-map leaf, as scripts/scaffold/targets.js reads it.
const SCAFFOLD_ROW = /^\| \[[^\]]+\]\(\.\.\/(scaffold-templates\/[^)]+\.mustache)\) \| `/gm;
// An inline MCP server of a converted agent that runs a project script.
const AGENT_SERVER_ARG = /^ {4}args: \["((?:scripts|\.archon)\/[^"]+)"/gm;
// A test suite a CI workflow runs by name (a glob is no dependency).
const CI_SUITE = /(?<![\w/.-])((?:\.archon\/)?scripts\/test\/[\w.-]+\.test\.sh)\b/g;
// A script a CI step runs (`bash .claude/scripts/x.sh`): the measured run of 2026-11-20 failed on a contract-pin.sh
// that a set without openapi-contract does not ship.
const CI_SCRIPT = /(?<![\w/.-])bash ((?:\.claude|\.archon)\/scripts\/[\w./-]+\.sh)\b/g;

function needsOf(f: DepFile): { needs: string; why: string }[] {
  const out: { needs: string; why: string }[] = [];
  if (/^docs\/code-maps\/[^/]+\.md$/.test(f.path))
    for (const m of f.content.matchAll(SCAFFOLD_ROW))
      out.push({
        needs: `docs/${decodeURIComponent(m[1] ?? '')}`,
        why: 'its ## Scaffold table (targets.js)',
      });
  if (/^\.github\/agents\/[^/]+\.agent\.md$/.test(f.path))
    for (const m of f.content.matchAll(AGENT_SERVER_ARG))
      out.push({ needs: m[1] ?? '', why: 'its mcp-servers entry' });
  if (
    /^\.github\/agents\/[^/]+\.agent\.md$/.test(f.path) &&
    f.content.includes(`\`${CONTRACT_CLI} *\``)
  )
    out.push({ needs: CONTRACT_CLI_PATH, why: 'its MCP fallback' });
  if (f.path === '.github/workflows/ci.yml') {
    for (const m of f.content.matchAll(CI_SUITE))
      out.push({ needs: m[1] ?? '', why: 'a CI step runs it' });
    for (const m of f.content.matchAll(CI_SCRIPT))
      out.push({ needs: m[1] ?? '', why: 'a CI step runs it' });
  }
  return out;
}

/**
 * Gaps known and accepted, each with its reason: a matching line is reported, not failed. A sync reports an entry
 * that matches no line, so it goes once its gap is closed.
 */
export const KNOWN_GAPS: { match: RegExp; reason: string }[] = [
  {
    match:
      /^core,java(,openapi-contract)?: \S+ needs (\.github\/workflows\/ci\.yml|\.github\/ci-inputs\.yml|docs\/scaffold-templates\/)/,
    reason:
      'no framework profile: the CI workflow and the framework templates ship with java-quarkus or java-spring',
  },
  {
    match:
      /^core,java(,java-quarkus|,java-spring)?: \.github\/agents\/\S+ needs scripts\/contract-mcp\/(server|cli)\.mjs/,
    reason:
      'the java agents name the contract server inline and its CLI as their MCP fallback; without openapi-contract neither runs, install that profile',
  },
  {
    match:
      /^core,openapi-contract: \.github\/workflows\/ci\.yml needs \.claude\/scripts\/\S+ \(a CI step runs it\)/,
    reason:
      "no java profile: openapi-contract's ci.yml is the Spring build's workflow with the contract steps, which wins over java-spring's; without java there is no Gradle build for it to run",
  },
  {
    match:
      /^core,java,java-quarkus(,openapi-contract)?: \.github\/workflows\/ci\.yml needs (\.archon\/)?scripts\/test\/\S+ \(a CI step runs it\)|^core,java,java-quarkus: \.github\/workflows\/ci\.yml needs \.claude\/scripts\/\S+ \(a CI step runs it\)/,
    reason:
      "the java-quarkus ci.yml is still the source's own, which names the source's suites and the contract steps; it needs an overlay like java-spring's",
  },
];

/** The known gaps split off: failures are the unknown gaps, unused the KNOWN_GAPS entries that match nothing. */
export function judgeDeps(lines: string[]): {
  failures: string[];
  known: string[];
  unused: string[];
} {
  const failures: string[] = [];
  const known: string[] = [];
  const used = new Set<number>();
  for (const line of lines) {
    const i = KNOWN_GAPS.findIndex(g => g.match.test(line));
    if (i < 0) failures.push(line);
    else {
      used.add(i);
      known.push(`${line}: ${KNOWN_GAPS[i]?.reason}`);
    }
  }
  const unused = KNOWN_GAPS.filter((_, i) => !used.has(i)).map(g => `${g.match}`);
  return { failures, known, unused };
}

/** What one set's files need, deduplicated: `[file, needs, why]`. */
function needsInSet(
  set: Profile[],
  inSet: DepFile[],
  paths: Set<string>
): [string, string, string][] {
  const out = new Map<string, [string, string, string]>();
  if (BUILDS(set))
    for (const { script, needs } of STACK_NEEDS.filter(s => paths.has(s.script)))
      for (const n of needs) out.set(`${script}\0${n}`, [script, n, 'it reads it']);
  for (const f of inSet)
    for (const { needs, why } of needsOf(f)) out.set(`${f.path}\0${needs}`, [f.path, needs, why]);
  return [...out.values()];
}

/** One line per set and missing file: `<set>: <file> needs <path> (<why>)`. */
export function depsCheck(files: DepFile[]): string[] {
  const problems: string[] = [];
  for (const set of installableSets()) {
    const inSet = files.filter(f => set.includes(f.profile as Profile));
    const paths = new Set(inSet.map(f => f.path));
    for (const [file, needs, why] of needsInSet(set, inSet, paths))
      if (!paths.has(needs)) problems.push(`${set.join(',')}: ${file} needs ${needs} (${why})`);
  }
  return problems;
}
