---
runtime: lazy
kind: worked-example
---

<!-- AI_DISCLAIMER v1.0 -->
# Code map — `java` (project: `shop-backend`)

> Slim by design: this map records only the project-wide facts (toolchain, Lombok
> prevalence, package shape) — the individual idioms (records, `Optional`, factories) are covered by
> their own maps, cross-referenced below rather than repeated here.

> This file has been created (totally or partially) with the assistance of artificial intelligence tools.
> All content has been generated under the direct supervision of a named individual,
> and under the AI.Backbone Orchestrator Compliance framework

## This repo (wedding-portal)
These are the real facts. Everything from "Where this pattern lives" down is the pseudonymized worked example
(`shop-backend`): follow its structure, not its names. Decisions: [memory, 2026-10-17].

- **Toolchain:** Java 26; Gradle Kotlin DSL; every version in `gradle/libs.versions.toml`.
- **Modules:** one domain/usecase/adapter triad per context, plus `spotify-gateway`, `musicfolder-gateway`, `pdf-gateway`,
  `application` and `logging`. The Quarkus plugin builds the app in `application` only (`shared-adapter` applies it for
  `@QuarkusTest`, with `quarkusBuild` off); every usecase, adapter and gateway module ships a
  `META-INF/beans.xml`, so Quarkus indexes it (`build-shape-check.sh` checks the file). An adapter or gateway module without a real bean has a `*ModuleProbe` that `ModuleBeanDiscoveryTest`
  injects; the usecase modules have none until their first use case.
- **Packages:** `app.rekord.<context>.{domain,usecase,repository,adapter.controller,adapter.repository}`; shared code in
  `app.rekord.common.domain(.validation)` and `app.rekord.common.adapter.controller`. Ports (repository and gateway
  alike) live in `app.rekord.<context>.repository`. A gateway is `app.rekord.<context>.gateway.<system>` under the
  context whose port it implements; a generated client `app.rekord.<vendor>.gateway.client`.
- **Ids** are typed UUID records, `record GadgetId(UUID value)`.
- **Lombok** is allowed, the domain included.

## Where this pattern lives (exemplars)
| Exemplar | What it shows | Layer / module |
|----------|---------------|----------------|
| [`shop.java-conventions.gradle.kts`](exemplars/java-conventions-plugin.md#java) | Java 21 toolchain pinned once, inherited repo-wide | build-logic |

### Excerpts
Pinned toolchain, declared once (full source in the [exemplar leaf](exemplars/java-conventions-plugin.md#java)):
```kotlin
java {
    toolchain {
        languageVersion.set(JavaLanguageVersion.of(21))
    }
}
```

Release target and reflective parameter names:
```kotlin
tasks.withType<JavaCompile>().configureEach {
    options.release.set(21)
    options.compilerArgs.add("-parameters")
}
```

### Edge cases
Module attempts to compile with a different release:
```kotlin
tasks.withType<JavaCompile>().configureEach {
    options.release.set(17)
}
```
Expected: this is drift from the repo-wide Java 21 convention and should be removed unless the plugin changes centrally.

Jackson creator relying on inferred parameter names:
```java
@JsonCreator
public OrderLineDTO(String sku, int quantity) { ... }
```
Expected: `-parameters` stays enabled centrally so Jackson (records, creators) and CDI can resolve parameter names without repeating them in annotations.

Value object written as a record:
```java
public record CustomerAddress(String cityName, String postalCode) { }
```
Expected: simple immutable shapes use records; when construction needs validation, the repo switches to the validating-factory style documented in [domain-modeling].

## Local conventions (the project facts the skill omits)
- Java 21 toolchain, set once in `build-logic/src/main/kotlin/shop.java-conventions.gradle.kts`
  and applied by every module — never re-pinned per module.
- Package shape: `com.acme.shop.<capability>.<layer>` (e.g. `com.acme.shop.order.usecase`,
  `com.acme.shop.storefront.adapter.event`).
- Lombok is the default for boilerplate reduction (`@RequiredArgsConstructor`, `@Getter`, `@Slf4j`, ...) —
  prevalence under *Frequency* below.
- Records for simple value objects — the count and the record-vs-validating-factory decision tree
  live in [domain-modeling]; not duplicated here.

## Frequency & coverage (why this earned a skill)
- 855 production `.java` files repo-wide (as of `abc1234`); 534 of them (`rg -l 'import lombok'`)
  import Lombok; `record` prevalence → [domain-modeling].

## Drift / exceptions
- None observed — the toolchain and package-shape conventions are enforced structurally (one convention
  plugin, one package-naming habit), not by a lint rule.

## Provenance
- Scanned at: `abc1234` · tool/query: `rg -l --glob '*.java' '.'` excl. `build/`,`test/` (855 files); `rg -l 'import lombok' --glob '*.java'` excl. `build/`,`test/` (534 files); `rg -l '^\s*(public\s+)?record\s+[A-Za-z]+' --glob '*.java'` (105 files)

[domain-modeling]: domain-modeling.md

[memory, 2026-10-17]: ../memory.md
