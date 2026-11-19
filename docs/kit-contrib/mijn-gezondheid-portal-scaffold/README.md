# Contributed: a consumer's project scaffold templates (Spring Boot 4, hexagonal)

A snapshot of the project-owned scaffold templates and their tooling from a consumer of this kit:
`ssg-Belux/mijn-gezondheid-portal`, PR #898, branch `feature/project-scaffold-templates`.

They are here as reference material for the kit and are **not wired into it**:
- `kit-sync` does not read this directory;
- nothing ships from here to consumers;
- the paths are the consumer's own, as they sit in that repo.

They carry that project's nouns (`be.mijngezondheid`, its exemplar classes). P3 keeps those out of `kit/profiles`, so
anything taken from here into a profile must be made generic first.

## What is here

| Path | What |
|---|---|
| `docs/scaffold-templates/project/{module,domain,usecase,gateway,adapter}/` | 59 templates, each with a working `<name>.example.json`; `<name>.<variant>.example.json` is a second shape of the same template |
| `docs/scaffold-templates/project/README.md` | the conventions: full `package`, `{{{triple}}}` variables, shared field names, the controller authorization rule |
| `scripts/scaffold/new-context.sh` | scaffolds a bounded context (domain / usecase / adapter, optional gateway) and registers it in Gradle |
| `scripts/scaffold/smoke.sh` | renders every template into a throwaway copy, then compiles and runs the generated tests plus the ArchUnit tests. In the consumer: 53 tests over 20 classes, green |
| `scripts/test/scaffold.test.sh` | the wiring check: every template linked from a code-map `## Scaffold` row, `--for`, `scaffold-step.js` on `Scaffold: project/...` lines |
| `docs/scaffold-templates/project/scaffold.json` | added here, not in PR #898: what the kit's generic scripts need to do what the three above do in that repo (its module set, its smoke context and Gradle tasks, `projectOnly`) |

## How it uses the kit

- **No kit changes needed for resolution.** `scripts/scaffold.sh project/<layer>/<name>`, `scripts/scaffold.sh --for`,
  `scaffold-step.js` and the scaffold-check gate already resolve a template subpath.
- **Linking.** The consumer's `docs/code-maps/*.md` `## Scaffold` tables link only these, never the kit's worked
  examples.
- **Depends on this PR:** the unescaped renderer, the `###` memory entries and the planner prompt fix. Without the
  renderer fix, every value needs triple braces; these templates use them throughout.

## Taken into the kit

The three scripts ship generic in the java profile (`kit/overlays/java/scripts/`, `kit/SPEC.md`, Scaffold scripts):
`scripts/scaffold/new-context.sh` (with `new-context.js`), `scripts/scaffold/smoke.sh` and
`scripts/test/scaffold-wiring.test.sh`. The project nouns moved to `scaffold.json`. With this snapshot's
`scaffold.json`, the generic `new-context.sh` writes the same files as the consumer's, byte for byte, with and without
`--gateway`, and the generic `smoke.sh --render-only` renders the same 55 files with the same SCAFFOLD records.

To switch, the consumer copies `scaffold.json` into its `docs/scaffold-templates/project/`. `kit add` keeps a project file it did
not write, so the consumer deletes its own `new-context.sh` and `smoke.sh` before the next `kit add` to get the kit's
(`--force` would take the kit's version of every kept file, not only these). Its own `scripts/test/scaffold.test.sh` can stay: it sits where the kit's renderer check sits, and the agents may
run both.

Still open: the `<name>.example.json` + `_target` convention is now read by the kit's scripts, but no kit template has an
example yet.
