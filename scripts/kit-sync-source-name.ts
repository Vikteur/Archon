/**
 * The kit's source repo name (kit/SPEC.md, Source name): the one value kit-sync derives the source's own names from,
 * so no list or rule names the source repo. A sync reads it from KIT_SOURCE, and scripts/kit-sync.ts refuses to sync
 * without it; `--verify` and the tests need none and get the neutral placeholder.
 *
 * From the name `shop-portal` it derives: the repo and its checkout folder (`shop-portal`), its database name
 * (`shop_portal`), its first word, the domain noun its names start with (`shop`, `Shop`, `SHOP_`), its former umbrella
 * repo (`shopapp`) and its run skill (`run-shop-portal`, which ships as `run-app`).
 */

/** The kit's name in kit/manifest.json (`source.name`) and a project's kit.lock.json: never the source repo's. */
export const KIT_NAME = 'archon-kit';

/** The name the tests and `--verify` run under: no real repo's. */
export const SOURCE_PLACEHOLDER = 'sample-app';

/** KIT_SOURCE as given, or empty: a sync needs it. */
export const SOURCE_FROM_ENV = (process.env.KIT_SOURCE ?? '').trim();

const name = SOURCE_FROM_ENV || SOURCE_PLACEHOLDER;
if (!/^[a-z][a-z0-9]*(-[a-z0-9]+)*$/.test(name))
  throw new Error(`KIT_SOURCE=${name}: a repo name in kebab case, e.g. shop-portal`);

const word = name.split('-')[0] ?? name;

export const SRC = {
  /** The repo and its checkout folder. */
  repo: name,
  /** Its database name. */
  snake: name.replace(/-/g, '_'),
  /** The domain noun its names start with, lower case. */
  word,
  /** The same, capitalised (`ShopId`). */
  Word: word.charAt(0).toUpperCase() + word.slice(1),
  /** The same, upper case: its env var prefix without the underscore. */
  WORD: word.toUpperCase(),
  /** Its former umbrella repo. */
  umbrella: `${word}app`,
  /** Its run skill, which ships as run-app. */
  runSkill: `run-${name}`,
} as const;

/** A literal for a RegExp source. */
export const reEsc = (s: string): string => s.replace(/[.*+?^${}()|[\]\\/]/g, '\\$&');
