---
runtime: lazy
kind: worked-example
---

<!-- AI_DISCLAIMER v1.0 -->
# Code map - `testcontainers` (project: `shop-backend`)

> This file has been created (totally or partially) with the assistance of artificial intelligence tools.
> All content has been generated under the direct supervision of a named individual,
> and under the AI.Backbone Orchestrator Compliance framework

> The skill says *how* to run a test against a real service in a container. This is *which* services,
> *which* images, and *which* base classes this repo actually uses.

## Services and images

| Service | Image | Started by | Properties it overrides |
|---|---|---|---|
| PostgreSQL | `postgres:13.18-alpine` | `PostgresContainerConfig`, a `@TestConfiguration` with a `@Bean @ServiceConnection PostgreSQLContainer` (two copies, see Drift) | `spring.datasource.url`, `spring.datasource.username`, `spring.datasource.password` (derived by `@ServiceConnection`) |
| Typesense | `typesense/typesense:30.0` | `TypesenseContainerConfig` | `typesense.api.base-path`, `typesense.api.key` |
| smtp4dev | `rnwood/smtp4dev:3.7.1` | `Smtp4devContainerConfig` | `spring.mail.host`, `spring.mail.port` |

Image tags are pinned exactly - never `latest`. A tag bump is a deliberate, reviewable change.

### Excerpts
PostgreSQL is a container bean whose connection details Spring Boot derives through `@ServiceConnection`:
```java
@TestConfiguration(proxyBeanMethods = false)
public class PostgresContainerConfig {

    @Bean
    @ServiceConnection
    PostgreSQLContainer<?> postgres() {
        return new PostgreSQLContainer<>("postgres:13.18-alpine")
                .withDatabaseName("shop")
                .withInitScript("init_postgres.sql");
    }
}
```

Typesense uses a generic container bean with explicit env and readiness wiring, its coordinates published by a `DynamicPropertyRegistrar`:
```java
@TestConfiguration(proxyBeanMethods = false)
public class TypesenseContainerConfig {

    @Bean
    GenericContainer<?> typesenseContainer() {
        return new GenericContainer<>(DockerImageName.parse("typesense/typesense:30.0"))
                .withExposedPorts(8108)
                .withEnv("TYPESENSE_API_KEY", "<test-key>")
                .withEnv("TYPESENSE_DATA_DIR", "/tmp")
                .withEnv("TYPESENSE_ENABLE_SEARCH_ANALYTICS", "TRUE")
                .waitingFor(new HttpWaitStrategy().forPath("/ready"));
    }

    @Bean
    DynamicPropertyRegistrar typesenseProperties(GenericContainer<?> typesenseContainer) {
        return registry -> {
            registry.add("typesense.api.base-path",
                    () -> "http://" + typesenseContainer.getHost() + ":" + typesenseContainer.getMappedPort(8108));
            registry.add("typesense.api.key", () -> "<test-key>");
        };
    }
}
```

Repository integration tests inherit a shared base that boots Spring against the container database:
```java
@SpringBootTest
@Import({PostgresContainerConfig.class, TypesenseContainerConfig.class, Smtp4devContainerConfig.class})
@Tag("integration")
public abstract class AbstractRepositoryTest { }
```

### Edge cases
A datasource URL set in the test configuration:
```properties
spring.datasource.url=jdbc:postgresql://localhost:5432/shop
```
Expected: `@ServiceConnection` details win over the property, so it is silently ignored where the container config is
imported, and silently used where it is not: that test hits whatever database runs locally, which defeats the point
of the container path. Keep datasource URLs out of test configuration.

No rollback between tests:
```java
@Test
@Transactional
void givenPage_whenPersist_thenFindByPath() { }
```
Expected: keep `@Transactional` on a `@SpringBootTest` test (a `@DataJpaTest` rolls back by default), or an equivalent
`TRUNCATE TABLE page CASCADE`. Without it, rows leak across tests and failures become order-dependent.

Forgotten config entry:
```java
return registry -> registry.add("spring.mail.host", smtp4devContainer::getHost);
```
Expected: also register the matching `spring.mail.port` (the mapped port, and any API key) or the test still points
at nowhere useful.

## Scaffold
Render the base case with `scripts/scaffold.sh --test <template> '<json on one line>' <target>` from the repo root.
The template's header comment lists its exact variables; the script refuses to overwrite an existing file.

| Template | Target | Variables | Left to you |
|---|---|---|---|
| [adapter/table-test](../scaffold-templates/adapter/table-test.mustache) | `application/src/test/java/<pkg>/persistence/<context>/<Name>TableTest.java` | `package` (the file's own package: an `application` test has no layer suffix), `Name`, `Rows`, `about`, `imports`, `parents` (`type`, `name`, `row`), `refusals` (`test`, `first`, `row`, `constraint`), `readBack` (`test`, `Entity`, `row`, `key`, `columns`) | the context's rows helper when it has none yet; a check, cascade or default-value test; a test that needs rows of two contexts |

One table test per new table, next to the migration that creates it (`flyway-migrations`, a STOP item). `Rows` is
the context's rows helper in the same test package: `insert(em, entity)` commits one row in its own transaction,
`constraintOf(thrown)` names the constraint that refused it, `deleteAll(em)` empties the context's tables for
`@AfterEach`. A refusal asserts the constraint by name, never only that something was thrown.

## Local conventions (the project facts the skill omits)
- **Mechanism: `@TestConfiguration` container beans + `@ServiceConnection`, not `@Testcontainers` / `@Container`.**
  PostgreSQL is a `@Bean @ServiceConnection` in `PostgresContainerConfig`. Every other container is a
  `GenericContainer` bean in its own `@TestConfiguration`, whose `DynamicPropertyRegistrar` bean overrides the
  application config. The configs are `@Import`ed by the test or its base class, so a container starts once per
  cached Spring test context and is shared by every test class with the same context configuration rather than
  being recycled per class. `compose.yaml` (`spring-boot-docker-compose`, `developmentOnly`) serves `bootRun`
  only; Spring Boot skips it in tests.
- **Wiring, per module:** `testImplementation("org.springframework.boot:spring-boot-testcontainers")` plus
  `org.testcontainers:postgresql` for the database, and `org.testcontainers:testcontainers` where a
  `GenericContainer` is used - declared in 5 modules: `application`, `authentication-adapter`,
  `storefront-adapter`, `account-adapter`, `attribute-mapping-adapter`. Versions come from the
  Spring Boot BOM, never pinned per module.
- **The repository base class** is `storefront-adapter/.../repository/support/AbstractRepositoryTest`:
  `@SpringBootTest` (so the container database is used) + the PostgreSQL, Typesense and smtp4dev container configs.
  Subclasses `@Autowired` the repository under test and mark each test `@Transactional` to roll it back. A
  `@DataJpaTest` slice imports `PostgresContainerConfig` with `@AutoConfigureTestDatabase(replace = NONE)` instead.
  New repository integration tests extend it; they do not re-declare containers.
- **Schema comes from the real migrations.** Flyway runs on context start; `authentication-adapter`'s test
  configuration points `spring.flyway.locations` at the application's migrations and keeps
  `spring.jpa.hibernate.ddl-auto=validate`, so the container runs the same Flyway DDL as
  production - `application/src/main/resources/db/migration/ddl/V1.{n}__{desc}.sql`. Never
  hand-create tables in a test.
- **Database bootstrap:** the container runs the shared `init_postgres.sql` from the test classpath via
  `withInitScript(...)`, and uses database name `shop` (`withDatabaseName`).
- **Wait strategies are explicit for the non-JDBC containers** - Typesense waits on an HTTP readiness
  endpoint, smtp4dev on `HTTP /api/messages` returning 200 on port 80. `PostgreSQLContainer` brings its own
  readiness check, so it declares none.

## Frequency & coverage
- 4 container setups (container configs) across 3 modules; 7 test sources
  import a container config or extend a base class that does (as of `abc1234`).
- Everything else in the suite is a plain unit test - the container path is the exception,
  not the default.

## Drift / exceptions
- **The PostgreSQL container config exists twice**, in `application/src/test/java/` and
  in `authentication-adapter/src/test/java/` `PostgresContainerConfig`, with the same image and
  near-identical bean methods. They are not identical: only the `authentication-adapter` copy
  runs Flyway against the application's migrations, and only the `application` copy sets `init_postgres.sql`. Treat
  the divergence as unintentional - a shared test-jar (the `shop.test-jar-producer` convention plugin already
  supports exactly this) is the natural home for shared test config. Not consolidated here;
  recorded as an observation.
- Container beans are stopped only when their cached test context closes (at JVM exit, or on eviction from the
  context cache), so a context variant per `@MockitoBean` set keeps one more container running until then; Ryuk
  reaps what a killed run leaves. Fine for CI, worth knowing when a local run leaves images resident.

## Provenance
- Scanned at: `abc1234` - tool/query: `rg -l 'testcontainers|Testcontainers|ServiceConnection'` over Java,
  properties and Gradle sources excluding `build/`, plus reads of the four container setups and
  `AbstractRepositoryTest`.
  Not yet scanner-harvested.
