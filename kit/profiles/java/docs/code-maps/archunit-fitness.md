---
runtime: lazy
kind: worked-example
---

<!-- AI_DISCLAIMER v1.0 -->
# Code map — `archunit-fitness` (project: `shop-backend`)

> Thin by design: below the code-map frequency threshold on purpose — a single
> repo-wide suite, not one per module.

> This file has been created (totally or partially) with the assistance of artificial intelligence tools.
> All content has been generated under the direct supervision of a named individual,
> and under the AI.Backbone Orchestrator Compliance framework

## This repo (wedding-portal)
These are the real facts. Everything from "Where this pattern lives" down is the pseudonymized worked example
(`shop-backend`): follow its structure, not its names. Decisions: [memory, 2026-10-17].

- **Rules carried over** (numbers as in history, git bb1988a): A1 domain depends on the JDK only (Lombok allowed);
  A8 no `Instant`/`LocalDate`/`LocalDateTime`/`OffsetDateTime.now()`, `System.currentTimeMillis()`,
  `UUID.randomUUID()`, `new Random()`, `new SecureRandom()`, `Math.random()`, `Clock.systemUTC()` or `Clock.systemDefaultZone()` outside `app.rekord.application.config`,
  where the clock, id and token providers live (only these eleven calls: another time or random source is not caught); A9 no `@Inject` field (jakarta or javax); A10 no cycles between contexts; A12 configuration types
  (`org.eclipse.microprofile.config..`, `io.smallrye.config..`, `@ConfigProperty`, `@ConfigMapping`) only in
  `application` and gateways.
- **The usecase layer** may use `@Transactional` and `@ApplicationScoped`, nothing else from a framework.
- **A13, adapted:** errors travel as a `Notification` ([exception-to-http]), so the old exception-family rule shrinks to
  two: a domain or usecase `Throwable` extends `RekordException` (`app.rekord.common.domain.error.RekordException`,
  named by class name, empty allowed), and only the helper package throws a `WebApplicationException`.
- **In force today:** `application/src/test/java/app/rekord/application/architecture/AdapterPackageConventionTest.java`
  (ArchUnit 1.5.1, `libs.archunit.junit5`), one `@ArchTest` field per rule with `.because(...)`: no class in
  `app.rekord.adapter..`; `@Path` classes and `*Controller`s in `app.rekord.*.adapter.controller`; `@Entity` classes and
  `*Repository` implementations in `app.rekord.*.adapter.repository`; no controller → repository dependency; no
  context adapter → another context's adapter (only `app.rekord.common.adapter..` is shared). It runs in the fast
  `test` set.
- **The A1-A15 suite (TASK-3.1, A15 TASK-3.2)**, all in that package, one `static final ArchRule A<n>` per rule plus a
  `FreezingArchRule.freeze(...)` `@ArchTest` twin that runs against every main class:
  - `FrozenBaselineTest`: the empty store (`archunit.properties`); a new violation fails the build, the store refuses
    every addition and a refreeze;
  - `DomainConventionTest` A1; `LayerDirectionConventionTest` A2, A10; `UsecaseConventionTest` A3 (CT-11) and A15: no CDI `@Produces` method returns a type in
    `app.rekord.*.usecase..` or `app.rekord.*.repository..` (PIN-AC-0448), and the rule allows an empty set;
  - `AdapterBoundaryConventionTest` A4-A6 and A16 (A6 now names the persistence packages only; A16: only the common controller helper reads `io.quarkus.hibernate.validator..`); `CrossCuttingConventionTest` A7-A9, A12, A13;
  - `ResourceConventionTest` A11: a resource (an adapter class named `*Resource`/`*Controller`, annotated `@Path`, or
    implementing a `@Path` interface) implements a generated `app.rekord.api.*Api`, and no adapter class or interface
    carries a `@Path` of its own;
  - `StatusHelperConventionTest` A14: only `app.rekord.common.adapter.controller` sets a response status, through
    `jakarta.ws.rs.core.Response` or RESTEasy Reactive's `RestResponse` (status factories such as `created`,
    `notAcceptable`, `seeOther`, their builders' `status`/`create`), `@ResponseStatus`, `ContainerResponseContext.setStatus`/`setStatusInfo`
    or Vert.x `setStatusCode` (which code it sets is the helper's concern, not the rule's);
  - `ModulePackageConventionTest`: every class sits in its module's layer packages (`-domain`, `-usecase` with its
    `config`, `-adapter`, `-gateway`, `application`, `logging`), so the package rules A1, A3 and A11 see every class of
    a module; a module it cannot tell, or of an unknown kind, is a violation;
  - `Layers.java` holds the package patterns; `SuiteCoverageTest` pins that every module with main code is scanned,
    compiled at release 26.
- **Rule: breach test first.** Each rule has a `<X>RuleBreachTest` that feeds fixtures from `app.rekord.archfixture..`
  (never scanned: `DoNotIncludeTests`) to the plain rule constant and expects a violation naming the fixture. The
  suite runs the frozen twin, and the store refuses every addition.

## Where this pattern lives (exemplars)
| Exemplar | What it shows | Layer / module |
|----------|---------------|----------------|
| [`TransactionalConventionTest.java`](exemplars/transactional-convention-test.md#archunit-fitness) | One centralized `@AnalyzeClasses` suite scanning the whole `com.acme.shop` tree; `classes()`/`noClasses()` + `.because(...)` per rule | test (`application`) |

### Excerpts
Whole-repo scan from one test class (full source in the [exemplar leaf](exemplars/transactional-convention-test.md#archunit-fitness)):
```java
@AnalyzeClasses(packages = "com.acme.shop", importOptions = ImportOption.DoNotIncludeTests.class)
class TransactionalConventionTest {
```

Rule style: one assertion plus a reason:
```java
classes()
        .that().haveSimpleNameEndingWith("UseCase")
        .and().resideInAPackage("..usecase..")
        .should().beAnnotatedWith(jakarta.transaction.Transactional.class)
        .because("All use cases must be annotated with @jakarta.transaction.Transactional for transaction demarcation")
```

### Edge cases
Use-case class carrying `@Transactional` but no bean-defining annotation (wired from a `@Produces` method instead):
```java
@jakarta.transaction.Transactional
class SubmitOrderUseCase { }
```
Expected: the suite fails with the rule that requires `@ApplicationScoped` on use-cases — CDI interceptors
such as `@Transactional` do not apply to beans returned by producer methods.

Domain type annotated with Jakarta transactions:
```java
@jakarta.transaction.Transactional
record OrderCode(String value) { }
```
Expected: the suite fails because transaction boundaries belong outside the domain layer.

Controller annotated with any transaction marker:
```java
@jakarta.transaction.Transactional
class CustomerController { }
```
Expected: the suite fails because controllers are not the transaction boundary in this repo.

## Local conventions (the project facts the skill omits)
- Package root: `application/src/test/java/com/acme/shop/architecture/` — the one place fitness
  rules live; `application` is chosen because it already depends on every module, so
  `@AnalyzeClasses(packages = "com.acme.shop")` sees the whole codebase from one test source set.
- Naming shape: `*ConventionTest`, one `@ArchTest` method per rule, always with `.because("...")`.
- Rules currently enforced: `TransactionalConventionTest` (use-case classes carry
  `jakarta.transaction.Transactional` and `@ApplicationScoped`; domain classes carry neither `@Transactional`
  nor any `jakarta.enterprise` / `jakarta.ws.rs` / `io.quarkus` type; controllers carry no `@Transactional`) and
  `BatchJobLoggingConventionTest` (every `@Scheduled` method also carries `@BatchJob`, and vice versa).
- Config / wiring: none beyond the ArchUnit JUnit 5 extension already on the test classpath.

## Frequency & coverage (why this stays below the code-map threshold)
- `ArchRuleDefinition` occurs in exactly 2 files / 1 module (as of `abc1234`), matching the first
  harvest's count — deliberate, since the suite is centralized rather than per-module.

## Drift / exceptions
- **Candidate, not a rule yet:** a real module-dependency violation is currently parked —
  `storefront-domain/build.gradle.kts` declares `api(project(":account-domain"))`, i.e. `storefront-domain`
  depends on `account-domain`. The suite has no rule against cross-capability domain-module dependencies
  today, so this is not flagged. The natural home for such a rule is this same suite
  (`application/.../architecture/`) — e.g. a `noClasses().that().resideInAPackage("..storefront.domain..")
  .should().dependOnClassesThat().resideInAPackage("..account.domain..")` rule — but adding it is
  deliberately left for a future ticket, not this scan (this map only records the observation).

## Provenance
- Scanned at: `abc1234` · tool/query: `rg 'ArchRuleDefinition'` (2 files / 1 module); manual `grep 'account-domain' storefront-domain/build.gradle.kts` (1 match)

[memory, 2026-10-17]: ../memory.md
[exception-to-http]: exception-to-http.md
