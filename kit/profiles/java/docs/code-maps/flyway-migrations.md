---
runtime: lazy
kind: worked-example
---

<!-- AI_DISCLAIMER v1.0 -->
# Code map — `flyway-migrations` (project: `shop-backend`)

> This file has been created (totally or partially) with the assistance of artificial intelligence tools.
> All content has been generated under the direct supervision of a named individual,
> and under the AI.Backbone Orchestrator Compliance framework

## This repo (wedding-portal)
These are the real facts. Everything from "Where this pattern lives" down is the pseudonymized worked example
(`shop-backend`): follow its structure, not its names, tree or version shape. Decision: [memory, 2026-10-14].
- **One tree:** `application/src/main/resources/db/migration/`, for the whole app. No `ddl/` folder, no tree per
  adapter: Quarkus scans `db/migration` on every jar of the classpath, so an adapter's own `V…` would collide with or
  interleave into this sequence.
- **Baseline:** `V1__baseline.sql` is `schema.sql` of report 44 (`docs/rewrite/analysis/44-target-data-model/`) without the
  song list kind seed; the seed is the repeatable `R__seed_song_list_kinds.sql` (TASK-4.1).
- **Later migrations:** `V1.<NNN>__<snake_case_description>.sql`, three digits from `V1.001`, then `V1.002`, …;
  never `V2__`. Flyway compares each version part as an integer (`1 < 1.001 < 1.002`), so `V1.1__` and `V1.001__`
  are the same version and Flyway refuses the duplicate: always type the three digits. The template's header has the
  command that prints the next one. Branches from before the TASK-47 restart still hold a dead `V2__identity.sql`:
  ignore them.
- **LF only:** `.gitattributes` has `*.sql text eol=lf`; the Flyway checksum is over the bytes.
- **Verified with:** Flyway 11.20.3 on PostgreSQL 18.6 (migrate twice, the second a no-op; validate). Which Flyway
  version Quarkus pins is set by TASK-4.1's build.
- **A schema test per migration:** every `V*.sql` has a schema test
  `app.rekord.application.persistence.migration.V<version, dots as _>MigrationTest` declaring its tables, columns
  (type, nullability) and constraints (`src/test/resources/migration-schema/V<version, dots as _>.txt`); `MigrationTestCoverageTest`
  fails the `test` task without it. Repeatables need none.

## Where this pattern lives (exemplars)
| Exemplar | What it shows | Layer / module |
|----------|---------------|----------------|
| [`V1.098__add_household_delegation_to_topics.sql`](exemplars/topics-delegation-migration.md#flyway-migrations) | Idempotent data-backfill migration with an explanatory leading comment | adapter (`account-adapter`) |

### Excerpts
Idempotent append for existing rows (full source in the [exemplar leaf](exemplars/topics-delegation-migration.md#flyway-migrations)):
```sql
UPDATE topic_delegation
SET delegation_types = delegation_types || ',HOUSEHOLD'
WHERE delegation_types IS NOT NULL
  AND delegation_types <> ''
  AND delegation_types NOT LIKE '%HOUSEHOLD%';
```

Separate handling for null and empty-string rows:
```sql
UPDATE topic_delegation
SET delegation_types = 'HOUSEHOLD'
WHERE delegation_types IS NULL;

UPDATE topic_delegation
SET delegation_types = 'HOUSEHOLD'
WHERE delegation_types = '';
```

### Edge cases
Existing multi-value row:
```sql
delegation_types = 'SELF,TEAM'
```
Expected: the migration appends `,HOUSEHOLD` exactly once.

Null column value:
```sql
delegation_types = NULL
```
Expected: the migration sets the column to `HOUSEHOLD` instead of leaving it blank.

Already migrated row:
```sql
delegation_types = 'SELF,HOUSEHOLD'
```
Expected: the first update skips the row because the value already contains `HOUSEHOLD`.

## Scaffold
Render the base case with `scripts/scaffold.sh <template> '<json on one line>' <target>` from the repo root. The
template's header comment lists its exact variables and the commands that find the next version; the script refuses
to overwrite an existing file. The rendered SQL is what you post for approval: do not commit it before a human said yes.

| Template | Target | Variables | Left to you |
|---|---|---|---|
| [adapter/flyway-migration](../scaffold-templates/adapter/flyway-migration.mustache) | `application/src/main/resources/db/migration/V1.<NNN>__<snake_case_description>.sql` | `purpose`, and any of `createTable` (`table`, `columns[name, sqlType, primaryKey, notNull, default, references, last]`), `addColumns` (`table`, `columns[name, sqlType, notNull, default, last]`), `statements` (raw SQL) | the version number; indexes and constraints beyond the key, `NOT NULL` and `REFERENCES`; idempotent backfills; staging a destructive change across releases |

The columns match the entity from `jpa-entity-mapping` (`table`, `column`).

## Local conventions (worked example, `shop-backend`; this repo's are in "This repo" above)
- Package root: `<module>/src/main/resources/db/migration/ddl/` — one `ddl/` tree **per module**
  that owns a schema, each with its own version sequence, not one repo-wide migration tree.
- Naming shape: `V<major>.<minor>__<snake_case_description>.sql` (two-part version, e.g. `V1.098`,
  not `V1__` / timestamp-based).
- Required collaborators / base types: none — plain SQL, no Java migration classes observed.
- Config / wiring: applied automatically on startup by `quarkus-flyway`
  (`quarkus.flyway.migrate-at-start=true`; the default `db/migration` location is scanned
  recursively, so `ddl/` is picked up). Hibernate never touches the schema:
  `quarkus.hibernate-orm.database.generation=none`.

## Frequency & coverage (why this earned a skill)
- Occurrences: 99 migration files across 5 modules — `application`, `authentication-adapter`,
  `storefront-adapter`, `account-adapter`, `attribute-mapping-adapter` (as of `abc1234`).

## Drift / exceptions
- None observed — version numbering and idempotent-update style are consistent across the sampled
  migrations.

## Provenance
- Scanned at: `abc1234` · tool/query: `Get-ChildItem -Recurse -Filter "V*__*.sql"` excluding `build/target/bin`

[memory, 2026-10-14]: ../memory.md
