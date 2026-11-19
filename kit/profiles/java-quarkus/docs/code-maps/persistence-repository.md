---
runtime: lazy
kind: worked-example
---

<!-- AI_DISCLAIMER v1.0 -->
# Code map — `persistence-repository` (project: `shop-backend`)

> This file has been created (totally or partially) with the assistance of artificial intelligence tools.
> All content has been generated under the direct supervision of a named individual,
> and under the AI.Backbone Orchestrator Compliance framework

## This repo (wedding-portal)
These are the real facts. Everything from "Where this pattern lives" down is the pseudonymized worked example
(`shop-backend`): follow its structure, not its names. Decisions: [memory, 2026-10-17].

- **Per aggregate:** a separate `<X>Entity`, a package-private Panache `<X>EntityRepository`, a `Default<X>Repository`
  implementing the port, and an `EntityMapper`. Package `app.rekord.<context>.adapter.repository`.
- **Every query is filtered by organisation** (the port's first parameter, `OrganisationId`) and uses bound
  parameters. Each repository has a test with two organisations proving neither sees the other's rows.
- A unique or foreign-key violation is translated by constraint name into an `ErrorCode` result, never leaked as a
  persistence exception. `song_lists` has an optimistic lock.
- **Native SQL** for an `inet` column (`cast(:ip as inet)`) and an advisory lock
  (`pg_advisory_xact_lock(hashtext(:kind), :key)`, the int4 pair): `DefaultAuthAttemptRepository` is the exemplar; it is
  keyed on (kind, hash, client), not on an organisation.

## Where this pattern lives (exemplars)
| Exemplar | What it shows | Layer / module |
|----------|---------------|----------------|
| [`DefaultSalesRegionRepository.java`](exemplars/sales-region-jpa-repository.md#persistence-repository) | Port-implementing adapter delegating to a `PanacheRepository`, entity→domain mapping with a safe default | adapter (`account-adapter`) |

### Excerpts
Thin adapter over Hibernate ORM with Panache (full source in the [exemplar leaf](exemplars/sales-region-jpa-repository.md#persistence-repository)):
```java
public class DefaultSalesRegionRepository implements SalesRegionRepository {

    private final SalesRegionPanacheRepository panacheRepository;
```

Boundary mapping plus cache:
```java
@Override
@CacheResult(cacheName = "salesRegion")
public SalesRegion findByRegionCode(String regionCode) {
    return panacheRepository.findByRegionCode(regionCode)
            .map(entity -> SalesRegion.valueOf(entity.getRegion()))
            .orElse(SalesRegion.CENTRAL);
}
```

### Edge cases
No row found for the lookup key:
```java
when(panacheRepository.findByRegionCode("00000")).thenReturn(Optional.empty());
assertThat(repository.findByRegionCode("00000")).isEqualTo(SalesRegion.CENTRAL);
```
Expected: the adapter returns the agreed safe default instead of throwing.

Repeated lookup for the same code:
```java
repository.findByRegionCode("00000");
repository.findByRegionCode("00000");
```
Expected: Quarkus cache (`@CacheResult`) can satisfy the second read from cache because the port method is the cache boundary.

Unexpected enum value in persisted data:
```java
when(panacheRepository.findByRegionCode("00000"))
        .thenReturn(Optional.of(SalesRegionEntity.builder().region("UNKNOWN").regionCode("00000").build()));
```
Expected: any invalid persisted value fails at the adapter boundary rather than leaking a JPA entity downstream.

## Scaffold
Render the base case with `scripts/scaffold.sh <template> '<json on one line>' <target>` from the repo root. Each
template's header comment lists its exact variables; the script refuses to overwrite an existing file.

| Template | Target | Variables | Left to you |
|---|---|---|---|
| [adapter/panache-repository](../scaffold-templates/adapter/panache-repository.mustache) | `<capability>-adapter/src/main/java/<pkg>/adapter/repository/<Name>PanacheRepository.java` | `package` (base package, without `.adapter.repository`), `Name`, `Key` (leave out for the write path), `key`, `keyType`, `naturalKey` (`type`, `typedId`, for a domain key as `@Id`); lookups take the organisation's UUID first | other query methods |
| [adapter/default-repository](../scaffold-templates/adapter/default-repository.mustache) | `.../adapter/repository/Default<Name>Repository.java` | `package` (base package, without `.adapter.repository`), `basePackage`, `Name`, `Key`, `key`, `keyType`, `typedId`, `fields[name, pascal, typedId]` | writes (`persist`); other port methods; nested or collection mapping; a port that is not `Optional<Name> findBy<Key>` |
| [adapter/default-repository-crud](../scaffold-templates/adapter/default-repository-crud.mustache) | `.../adapter/repository/Default<Name>Repository.java` | `package` (base package, without `.adapter.repository`), `basePackage`, `Name`, `name`, `Key`, `key`, `keyType`, `typedId`; every query scoped by the organisation, `save` refuses a key of another organisation | other port methods; a serial id instead of a natural key (load and mutate the entity: `merge` would insert every time) |
| [adapter/entity-mapper](../scaffold-templates/adapter/entity-mapper.mustache) | `.../adapter/repository/<Name>EntityMapper.java` | `package` (base package, without `.adapter.repository`), `Name`, `naturalKey` (`name`, `pascal`, `typedId`), `fields[name, pascal]` | nested or collection mapping; `is<Pascal>()` getters for booleans |

The base case is one `findBy<Key>` lookup. The port comes from `usecase-orchestration` (repository-port), the entity
from `jpa-entity-mapping`, the test from `jvm-testing` (default-repository-test). The templates follow the skill's
Quarkus Panache shape.

A write by key uses default-repository-crud and entity-mapper instead of default-repository. It needs the domain key
as the JPA `@Id`: render panache-repository with `naturalKey` and no `Key`, and the entity with `naturalKey` and
`fromDomain` (`jpa-entity-mapping`). The port is repository-port-crud (`usecase-orchestration`), the test
default-repository-crud-test (`jvm-testing`).

## Local conventions (the project facts the skill omits)
- **Guarding a unique constraint** (TASK-5.5): (1) the adapter holds `static final ConstraintRefusals REFUSALS`
  (`app.rekord.common.adapter.repository`) mapping the constraint name to the domain check's refusal factory; (2) every
  write runs inside `REFUSALS.call/run`; (3) a race test in `application`, tagged `integration`, annotated
  `@ForcesConstraint` with the check's status and code. `ConstraintMapGuardTest` refuses a mapped name without one,
  and a map it cannot read (a field that is not static final, or `ConstraintRefusals.of` outside a static initializer).
  A deferred constraint is never mapped: it raises at commit, after the port call, and answers 500.
- **A per-key counter** is taken with a native `INSERT ... ON CONFLICT DO UPDATE ... RETURNING` inside the caller's
  transaction (TASK-48.8, `DefaultBillingNumberRepository`), never with a database sequence: a rollback gives the
  number back and the row lock serialises two issues.
- Package root: port interface (`*Repository`) in the `*-usecase` or `*-domain` module; the
  Panache adapter (`Default*Repository` implementing the port, plus a package-private
  `*PanacheRepository implements PanacheRepository<...>`) in the matching `*-adapter` module.
- Naming shape: port `<Thing>Repository`; adapter `Default<Thing>Repository`; the raw Panache
  repository `<Thing>PanacheRepository`.
- Required collaborators / base types: adapter converts the JPA entity to the domain value at the
  boundary — never returns a JPA entity from a port method.
- Config / wiring: `@ApplicationScoped` + Lombok `@RequiredArgsConstructor` on the adapter;
  `@ApplicationScoped` on the package-private Panache repository.

## Frequency & coverage (why this earned a skill)
- Occurrences: 50 `interface *Repository` files across 18 modules (as of `abc1234`).

## Drift / exceptions
- None observed in the sampled exemplar.

## Provenance
- Scanned at: `abc1234` · tool/query: `rg 'interface[[:space:]]+[A-Za-z]*Repository' --glob '*.java'`

[memory, 2026-10-17]: ../memory.md
