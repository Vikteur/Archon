---
runtime: lazy
kind: worked-example
---

<!-- AI_DISCLAIMER v1.0 -->
# Code map — `code-generation` (project: `shop-backend`)

> This file has been created (totally or partially) with the assistance of artificial intelligence tools.
> All content has been generated under the direct supervision of a named individual,
> and under the AI.Backbone Orchestrator Compliance framework

## This repo
Fill in this project's own facts for the pattern here: its modules, packages and the rules in force. Until then,
everything from "Where this pattern lives" down is the pseudonymized worked example: follow its structure, not its
names.

## Where this pattern lives (exemplars)
| Exemplar | What it shows | Layer / module |
|----------|---------------|----------------|
| [`shop.java-conventions.gradle.kts`](exemplars/java-conventions-plugin.md#code-generation) | The convention plugin applied to 60 of 62 modules, replacing per-module build boilerplate | `build-logic` |

### Excerpts
Convention plugin applied repo-wide (full source in the [exemplar leaf](exemplars/java-conventions-plugin.md#code-generation)):
```kotlin
plugins {
    `java-library`
    jacoco
}

group = "com.acme.shop"
version = rootProject.version
```

Centralized compiler and test wiring:
```kotlin
tasks.withType<JavaCompile>().configureEach {
    options.encoding = "UTF-8"
    options.release.set(21)
    options.compilerArgs.add("-parameters")
}
```

### Edge cases
Module with no convention plugin:
```kotlin
plugins {
    id("java")
}
```
Expected: this is a drift candidate unless the module is one of the known exceptions (root project or another non-standard build-only module).

Module that only declares `junit-jupiter-api`:
```kotlin
dependencies {
    testImplementation("org.junit.jupiter:junit-jupiter-api")
}
```
Expected: the shared plugin still supplies the runtime launcher and engine so tests run consistently.

Module exporting Mothers for reuse:
```kotlin
plugins {
    id("shop.test-jar-producer")
}
```
Expected: the module publishes its test helpers once, and consumers depend on the produced `testArtifacts` configuration.

## Scaffold templates (this repo)
Besides build-time codegen, this repo keeps mustache templates for the base case of hand-maintained code in
[docs/scaffold-templates/](../scaffold-templates/), rendered once by `scripts/scaffold.sh` with `mustache@4.2.0`
pinned by `scripts/scaffold/package-lock.json`. Unlike contract
codegen, the output is committed and then edited for edge cases, so the script never overwrites an existing file.
A wrong base case is fixed in the template. Each skill's leaf lists its templates in a `## Scaffold` section, and
`scripts/test/scaffold.test.sh` fails when a template is in none.

The `package` variable of a Java template is the **base** package: the template appends its layer's suffix itself
(`.domain`, `.usecase`, `.config`, `.repository`, `.adapter.controller`, `.adapter.repository`; each template header
and table row names it). So a domain file for `com/example/orders/domain/` takes `"package": "com.example.orders"`.
The one exception is adapter/table-test: the `application` module has no layer suffix, so its `package` is the
file's own package.
The script refuses a `.java` target whose directory under `src/<set>/java/` is not the package the file would declare,
names both, and writes nothing. Each file it writes adds a `SCAFFOLD` line (template, target, time; no variables) to
`.apm-audit/scaffold.jsonl`, which the run's scaffold report reads.

The templates come in two sets, picked by what the capability does, plus a few that go with either:
- **Read by key:** create-request, entity, factory, mother, factory-test; repository-port, usecase, usecase-test;
  jpa-entity, panache-repository (with `Key`), default-repository, default-repository-test; to-dto-mapper,
  to-dto-mapper-test, controller, controller-test.
- **Write by key (create-or-update and delete):** create-or-update-request, and entity, factory, mother and
  factory-test with `upsert: true`, plus entity-test; repository-port-crud, usecase-create-or-update(-test),
  usecase-delete(-test); jpa-entity (`naturalKey`, `fromDomain`), panache-repository (`naturalKey`, no `Key`),
  entity-mapper, default-repository-crud(-test); request-dto-to-domain-mapper, controller-command(-test);
  flyway-migration for a new table or column (a STOP item).
- **In either set, when the capability needs it:** command for a use case's input and outcome for a use case that
  ends in more than one way; table-test for each new table.

A capability that both reads and writes renders both, sharing the aggregate and its entity.

## Local conventions (the project facts the skill omits)
- Package root: `build-logic/src/main/kotlin/shop.<name>-conventions.gradle.kts` (4
  convention plugins: `java-conventions`, `bom-conventions`, `openapi-conventions`,
  `test-jar-producer`).
- Naming shape: `shop.<name>-conventions`, applied via
  `plugins { id("shop.<name>-conventions") }` in each module's `build.gradle.kts`.
- Required collaborators / base types: `shop.openapi-conventions` generates the `*Api`
  interfaces controllers implement (see [api-first-controller]);
  `shop.test-jar-producer` is what lets a domain module export an object mother as a
  reusable test-jar (see [object-mother-builders]).
- Config / wiring: applied per-module, not via `allprojects`/`subprojects` in the root
  `build.gradle.kts`.

## Frequency & coverage (why this earned a skill)
- Occurrences: convention-plugin `id(...)` references found in 60 of 62 module `build.gradle.kts`
  files (as of `abc1234`); `openapi-conventions` specifically in 15 modules (the ones with a
  generated REST API — matches the `api-first-controller` module list).

## Drift / exceptions
- 2 of 62 `build.gradle.kts` files (root + one non-standard module) do not apply a convention
  plugin — expected (root project has no source to compile).

## Provenance
- Scanned at: `abc1234` · tool/query: manual `Get-ChildItem build.gradle.kts` + content match on `shop\.(java|openapi|bom|test-jar)`

[api-first-controller]: api-first-controller.md
[object-mother-builders]: object-mother-builders.md

[memory, 2026-10-17]: ../memory.md
