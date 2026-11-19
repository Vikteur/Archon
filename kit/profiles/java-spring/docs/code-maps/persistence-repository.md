---
runtime: lazy
kind: worked-example
---

<!-- AI_DISCLAIMER v1.0 -->
# Code map — `persistence-repository` (project: `shop-backend`)

> This file has been created (totally or partially) with the assistance of artificial intelligence tools.
> All content has been generated under the direct supervision of a named individual,
> and under the AI.Backbone Orchestrator Compliance framework

## This repo (<project>)
These are the real facts. Everything from "Where this pattern lives" down is the pseudonymized worked example
(`shop-backend`): follow its structure, not its names.

- **Per aggregate:** a separate `<Name>Entity`, a package-private Spring Data `<Name>JpaRepository extends
  JpaRepository<<Name>Entity, UUID>`, a `Default<Name>Repository` (`@Repository`) implementing the port, and an
  `EntityMapper`. Package `<base-package>.<context>.adapter.repository`.
- **Every query is filtered by organisation** (the port's first parameter, `OrganisationId`): a derived query
  `findByOrganisationIdAnd<Key>(UUID organisationId, ...)` or a `@Query` with named bound parameters, never string
  concatenation. Each repository has a `@DataJpaTest` with two organisations proving neither sees the other's rows.
- A unique or foreign-key violation (Spring's `DataIntegrityViolationException`) is translated by constraint name
  into an `ErrorCode` result, never leaked as a persistence exception. An aggregate edited concurrently carries an
  optimistic lock (`@Version`; `ObjectOptimisticLockingFailureException` is translated the same way).
- **Native SQL** (`@Query(nativeQuery = true)`) for an `inet` column (`cast(:ip as inet)`) and an advisory lock
  (`pg_advisory_xact_lock(hashtext(:kind), :key)`, the int4 pair): the login-attempt `Default<Name>Repository` is
  the exemplar; it is keyed on (kind, hash, client), not on an organisation.

## Where this pattern lives (exemplars)
| Exemplar | What it shows | Layer / module |
|----------|---------------|----------------|
| [`DefaultSalesRegionRepository.java`](exemplars/sales-region-jpa-repository.md#persistence-repository) | Port-implementing adapter delegating to a Spring Data `JpaRepository`, entity→domain mapping with a safe default | adapter (`account-adapter`) |

### Excerpts
Thin adapter over Spring Data JPA (full source in the [exemplar leaf](exemplars/sales-region-jpa-repository.md#persistence-repository)):
```java
@Repository
@RequiredArgsConstructor
public class DefaultSalesRegionRepository implements SalesRegionRepository {

    private final SalesRegionJpaRepository jpaRepository;
```

Boundary mapping plus cache:
```java
@Override
@Cacheable(cacheNames = "salesRegion")
public SalesRegion findByRegionCode(String regionCode) {
    return jpaRepository.findByRegionCode(regionCode)
            .map(entity -> SalesRegion.valueOf(entity.getRegion()))
            .orElse(SalesRegion.CENTRAL);
}
```

### Edge cases
No row found for the lookup key:
```java
when(jpaRepository.findByRegionCode("00000")).thenReturn(Optional.empty());
assertThat(repository.findByRegionCode("00000")).isEqualTo(SalesRegion.CENTRAL);
```
Expected: the adapter returns the agreed safe default instead of throwing.

Repeated lookup for the same code:
```java
repository.findByRegionCode("00000");
repository.findByRegionCode("00000");
```
Expected: Spring's cache abstraction (`@Cacheable`, with `@EnableCaching` and a cache manager) can satisfy the second
read from cache because the port method on the proxied bean is the cache boundary; a call from inside the class
bypasses the proxy and the cache.

Unexpected enum value in persisted data:
```java
when(jpaRepository.findByRegionCode("00000"))
        .thenReturn(Optional.of(SalesRegionEntity.builder().region("UNKNOWN").regionCode("00000").build()));
```
Expected: any invalid persisted value fails at the adapter boundary (`IllegalArgumentException` from `valueOf`)
rather than leaking a JPA entity downstream.

## Scaffold
Render the base case with `scripts/scaffold.sh <template> '<json on one line>' <target>` from the repo root. Each
template's header comment lists its exact variables; the script refuses to overwrite an existing file.

| Template | Target | Variables | Left to you |
|---|---|---|---|
| [adapter/panache-repository](../scaffold-templates/adapter/panache-repository.mustache) | `<capability>-adapter/src/main/java/<pkg>/adapter/repository/<Name>JpaRepository.java` | `package` (base package, without `.adapter.repository`), `Name`, `Key` (leave out for the write path), `key`, `keyType`, `naturalKey` (`type`, `typedId`, for a domain key as `@Id`); lookups take the organisation's UUID first | other query methods (derived or `@Query`) |
| [adapter/default-repository](../scaffold-templates/adapter/default-repository.mustache) | `.../adapter/repository/Default<Name>Repository.java` | `package` (base package, without `.adapter.repository`), `basePackage`, `Name`, `Key`, `key`, `keyType`, `typedId`, `fields[name, pascal, typedId]` | writes (`saveAndFlush`); other port methods; nested or collection mapping; a port that is not `Optional<Name> findBy<Key>` |
| [adapter/default-repository-crud](../scaffold-templates/adapter/default-repository-crud.mustache) | `.../adapter/repository/Default<Name>Repository.java` | `package` (base package, without `.adapter.repository`), `basePackage`, `Name`, `name`, `Key`, `key`, `keyType`, `typedId`; every query scoped by the organisation, `save` refuses a key of another organisation | other port methods; a serial id instead of a natural key (load and mutate the entity: a new entity would insert on every `save`) |
| [adapter/entity-mapper](../scaffold-templates/adapter/entity-mapper.mustache) | `.../adapter/repository/<Name>EntityMapper.java` | `package` (base package, without `.adapter.repository`), `Name`, `naturalKey` (`name`, `pascal`, `typedId`), `fields[name, pascal]` | nested or collection mapping; `is<Pascal>()` getters for booleans |

The base case is one `findBy<Key>` lookup. The port comes from `usecase-orchestration` (repository-port), the entity
from `jpa-entity-mapping`, the test from `jvm-testing` (default-repository-test). The templates follow the skill's
Spring Data JPA shape; `adapter/panache-repository` keeps its old file name and renders the `JpaRepository` interface.

A write by key uses default-repository-crud and entity-mapper instead of default-repository. It needs the domain key
as the JPA `@Id`: render panache-repository with `naturalKey` and no `Key`, and the entity with `naturalKey` and
`fromDomain` (`jpa-entity-mapping`). The port is repository-port-crud (`usecase-orchestration`), the test
default-repository-crud-test (`jvm-testing`).

## Local conventions (the project facts the skill omits)
- **Guarding a unique constraint**: (1) the adapter holds `static final ConstraintRefusals REFUSALS`
  (`com.acme.shop.common.adapter.repository`) mapping the constraint name to the domain check's refusal factory; (2)
  every write runs inside `REFUSALS.call/run` and uses `saveAndFlush`, so the `DataIntegrityViolationException` is
  raised inside the call and not at commit; (3) a race test in `application`, tagged `integration`, annotated
  `@ForcesConstraint` with the check's status and code. `ConstraintMapGuardTest` refuses a mapped name without one,
  and a map it cannot read (a field that is not static final, or `ConstraintRefusals.of` outside a static initializer).
  A deferred constraint is never mapped: it raises at commit, after the port call, and answers 500.
- **A per-key counter** is taken with a native `INSERT ... ON CONFLICT DO UPDATE ... RETURNING` (a native `@Query`
  on the `JpaRepository`, read as a result, so no `@Modifying`) inside the caller's transaction
  (`@Transactional(propagation = Propagation.MANDATORY)` on `DefaultInvoiceNumberRepository`), never with a database
  sequence: a rollback gives the number back and the row lock serialises two issues.
- Package root: port interface (`*Repository`) in the `*-usecase` or `*-domain` module; the
  Spring Data adapter (`Default*Repository` implementing the port, plus a package-private
  `*JpaRepository extends JpaRepository<...>`) in the matching `*-adapter` module.
- Naming shape: port `<Thing>Repository`; adapter `Default<Thing>Repository`; the raw Spring Data
  repository `<Thing>JpaRepository`.
- Required collaborators / base types: adapter converts the JPA entity to the domain value at the
  boundary — never returns a JPA entity from a port method.
- Config / wiring: `@Repository` + Lombok `@RequiredArgsConstructor` on the adapter; the package-private
  Spring Data interface carries no annotation (Spring Boot's JPA repository scanning creates its bean).

## Frequency & coverage (why this earned a skill)
- Occurrences: 50 `interface *Repository` files across 18 modules (as of `abc1234`).

## Drift / exceptions
- None observed in the sampled exemplar.

## Provenance
- Scanned at: `abc1234` · tool/query: `rg 'interface[[:space:]]+[A-Za-z]*Repository' --glob '*.java'`
