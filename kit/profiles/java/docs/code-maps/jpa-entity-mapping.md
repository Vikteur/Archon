---
runtime: lazy
kind: worked-example
---

<!-- AI_DISCLAIMER v1.0 -->
# Code map — `jpa-entity-mapping` (project: `shop-backend`)

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
| [`SalesRegionEntity.java`](exemplars/sales-region-entity.md#jpa-entity-mapping) | Plain `@Entity` (not `PanacheEntity`) kept out of the domain, Lombok-built, explicit `@UniqueConstraint` matching a Flyway migration | adapter (`account-adapter`) |

### Excerpts
Minimal entity with explicit uniqueness (full source in the [exemplar leaf](exemplars/sales-region-entity.md#jpa-entity-mapping)):
```java
@Entity
@Table(
        name = "sales_region",
        uniqueConstraints = @UniqueConstraint(
                name = "unique_region_region_code",
                columnNames = {"region", "region_code"}
        )
)
```

JPA-only construction surface:
```java
@NoArgsConstructor(access = AccessLevel.PROTECTED)
@AllArgsConstructor(access = AccessLevel.PACKAGE)
public class SalesRegionEntity {
```

### Edge cases
Attempt to create a duplicate `(region, region_code)` row:
```java
salesRegionPanacheRepository.persistAndFlush(SalesRegionEntity.builder().region("CENTRAL").regionCode("00000").build());
salesRegionPanacheRepository.persistAndFlush(SalesRegionEntity.builder().region("CENTRAL").regionCode("00000").build());
```
Expected: the database-level unique constraint rejects the duplicate pair.

JPA instantiation path:
```java
var entity = SalesRegionEntity.builder().region("CENTRAL").regionCode("00000").build();
assertThat(entity.getId()).isNull();
```
Expected: application code uses the builder; JPA fills the identifier on persistence.

Reflective framework construction:
```java
var constructor = SalesRegionEntity.class.getDeclaredConstructor();
assertThat(Modifier.isProtected(constructor.getModifiers())).isTrue();
```
Expected: Hibernate can still instantiate the entity, while callers outside the package cannot use a public no-args constructor.

## Scaffold
Render the base case with `scripts/scaffold.sh <template> '<json on one line>' <target>` from the repo root. The
template's header comment lists its exact variables; the script refuses to overwrite an existing file.

| Template | Target | Variables | Left to you |
|---|---|---|---|
| [adapter/jpa-entity](../scaffold-templates/adapter/jpa-entity.mustache) | `<capability>-adapter/src/main/java/<pkg>/adapter/repository/<Name>Entity.java` | `package` (base package, without `.adapter.repository`), `basePackage`, `Name`, `table`, `fromDomain`, `organisationColumn` (`org_id`, `organisation_id`; mapped to the field `organisationId`; left out for a table without one), a key: none (serial `Long` id), `naturalKey` (`type`, `name`, `pascal`, `column`, `typedId`: the domain id type, then `type` is `UUID`; a caller-assigned `UUID` id is `{type: UUID, name: id, column: id}`) or `compositeKey[type, name, pascal, column, last]` (`@IdClass` with a nested record `Key`), `fields[type, name, pascal, column, nullable, readOnly]` (non-key columns, `NOT NULL` unless `nullable`; `readOnly` for a column the database fills) | relations and element collections; fetch types; enums (`@Enumerated`); `@JdbcTypeCode` for `char(n)`; a `toString` that leaves personal data out; the migration (`flyway-migrations` has its template; a STOP item: get a human decision first) |

For a write by key (`persistence-repository`: default-repository-crud) set `naturalKey`, `fromDomain` and
`organisationColumn`; without a key, every save of a rebuilt entity inserts a new row.

## Local conventions (the project facts the skill omits)
- Package root: `<module>/.../repository/<subpackage>/` — entities live alongside the repository
  that maps them, not in a separate `entity` package.
- Naming shape: `*Entity` suffix, separate from both the `*PanacheRepository` and the
  domain type it is converted to at the boundary.
- Base type: plain `jakarta.persistence` `@Entity`, never `PanacheEntity` — repository pattern, not
  active record.
- Required collaborators / base types: Lombok `@Getter @Builder @NoArgsConstructor(PROTECTED)
  @AllArgsConstructor(PACKAGE)` — no public constructor.
- Config / wiring: `@GeneratedValue(strategy = IDENTITY)` paired with a Postgres `serial` column
  (`columnDefinition = "serial"`).

## Frequency & coverage (why this earned a skill)
- Occurrences: 18 files across 5 modules — `application`, `authentication-adapter`,
  `storefront-adapter`, `account-adapter`, `attribute-mapping-adapter` (as of `abc1234`).

## Drift / exceptions
- None observed in the sampled exemplar.

## Provenance
- Scanned at: `abc1234` · tool/query: `rg '@Entity' --glob '*.java'`

[memory, 2026-10-17]: ../memory.md
[flyway-migrations]: flyway-migrations.md
