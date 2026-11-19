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

## How it uses the kit

- **No kit changes needed for resolution.** `scripts/scaffold.sh project/<layer>/<name>`, `scripts/scaffold.sh --for`,
  `scaffold-step.js` and the scaffold-check gate already resolve a template subpath.
- **Linking.** The consumer's `docs/code-maps/*.md` `## Scaffold` tables link only these, never the kit's worked
  examples.
- **Depends on this PR:** the unescaped renderer, the `###` memory entries and the planner prompt fix. Without the
  renderer fix, every value needs triple braces; these templates use them throughout.

## Candidates for the kit

Each must be made generic first:
- the smoke-check pattern (render every example, compile, test) as a java-profile script configured from `kit.yaml`;
- the wiring test, which is nearly generic already;
- the `<name>.example.json` + `_target` convention for templates.
