# Contributed: a consumer's project scaffold templates (Spring Boot 4, hexagonal)

A snapshot of the project-owned scaffold templates and their tooling from a consumer of this kit:
`ssg-Belux/mijn-gezondheid-portal`, PR #898, branch `feature/project-scaffold-templates`.

**The templates ship.** They moved to `kit/overlays/mijn-gezondheid/docs/scaffold-templates/project/`, the hand-written
source of the project profile `mijn-gezondheid` (`kit/SPEC.md`, Profiles), with a `## Scaffold` table in their
`README.md` and the `scaffold.json` the kit's generic scripts read. A fresh install has the profile by default; an
install from before adds it once with `archon-kit-update --add-profile mijn-gezondheid`. They carry that project's
nouns (`be.mijngezondheid`, its exemplar classes), which is why they are a project profile of their own: no generic
profile, script or skill carries one, and kit-sync's verify fails a generic profile's file in that folder.

What stays here is the consumer's own copy of its three scripts (`scripts/`), as reference for the generic ones.

## What is here

| Path | What |
|---|---|
| `kit/overlays/mijn-gezondheid/docs/scaffold-templates/project/{module,domain,usecase,gateway,adapter}/` | 59 templates, each with a working `<name>.example.json`; `<name>.<variant>.example.json` is a second shape of the same template |
| `kit/overlays/mijn-gezondheid/docs/scaffold-templates/project/README.md` | the conventions (full `package`, `{{{triple}}}` variables, shared field names, the controller authorization rule) and the `## Scaffold` table, one row per template target |
| `scripts/scaffold/new-context.sh` | scaffolds a bounded context (domain / usecase / adapter, optional gateway) and registers it in Gradle |
| `scripts/scaffold/smoke.sh` | renders every template into a throwaway copy, then compiles and runs the generated tests plus the ArchUnit tests. In the consumer: 53 tests over 20 classes, green |
| `scripts/test/scaffold.test.sh` | the wiring check: every template linked from a code-map `## Scaffold` row, `--for`, `scaffold-step.js` on `Scaffold: project/...` lines |
| `kit/overlays/mijn-gezondheid/docs/scaffold-templates/project/scaffold.json` | added here, not in PR #898: what the kit's generic scripts need to do what the three above do in that repo (its module set, its smoke context and Gradle tasks, `projectOnly`) |

## How it uses the kit

- **No kit changes needed for resolution.** `scripts/scaffold.sh project/<layer>/<name>`, `scripts/scaffold.sh --for`,
  `scaffold-step.js` and the scaffold-check gate already resolve a template subpath.
- **Linking.** The consumer's `docs/code-maps/*.md` `## Scaffold` tables link only these, never the kit's worked
  examples. In a fresh install the README's `## Scaffold` table links them, and `"projectOnly": true` makes
  `scripts/scaffold/targets.js` drop the kit leaves' rows that link a kit template, so `--for`, the scaffold step and the
  gate offer only these without an edit to a kit-owned leaf.
- **Depends on this PR:** the unescaped renderer, the `###` memory entries and the planner prompt fix. Without the
  renderer fix, every value needs triple braces; these templates use them throughout.

## Taken into the kit

The three scripts ship generic in the java profile (`kit/overlays/java/scripts/`, `kit/SPEC.md`, Scaffold scripts):
`scripts/scaffold/new-context.sh` (with `new-context.js`), `scripts/scaffold/smoke.sh` and
`scripts/test/scaffold-wiring.test.sh`. The project nouns moved to `scaffold.json`. With this snapshot's
`scaffold.json`, the generic `new-context.sh` writes the same files as the consumer's, byte for byte, with and without
`--gateway`, and the generic `smoke.sh --render-only` renders the same 55 files with the same SCAFFOLD records.

To switch, the consumer installs the profile (`archon-kit-update --add-profile mijn-gezondheid`). `kit add` keeps a
file the repo already has and that differs from the kit's ("kept (differs)"), so its own edited templates stay; it also
keeps a script it did not write, so the consumer deletes its own `new-context.sh` and `smoke.sh` before the next `kit add` to get the kit's
(`--force` would take the kit's version of every kept file, not only these). Its own `scripts/test/scaffold.test.sh` can stay: it sits where the kit's renderer check sits, and the agents may
run both.

Still open: the `<name>.example.json` + `_target` convention is now read by the kit's scripts, but no kit template has an
example yet.
