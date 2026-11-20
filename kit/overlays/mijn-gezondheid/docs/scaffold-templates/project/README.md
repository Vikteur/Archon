# Project scaffold templates

Mustache templates that render the **first version** of a new file in this repo's own shape. There are
59 templates over five layers. The output of every one compiles, passes its own generated test, and
keeps the ArchUnit rules (`TransactionalConventionTest`, `BatchJobLoggingConventionTest`).
`scripts/scaffold/smoke.sh` proves it.

## Why a `project/` folder

The templates one level up (`docs/scaffold-templates/{domain,usecase,adapter}/`) belong to the Archon kit
(hashed in `.archon/kit.lock.json`) and were written for another project. They assume `OrganisationId`,
`ErrorCode`, `CurrentOrganisation`, Spring's `@Transactional` with `@Service`, and Boot 3 test imports, so
their output does not compile here. A kit update would also overwrite any local fix.

The templates in this folder are project-owned and **canonical**. Only they are linked from the `## Scaffold` tables
in `docs/code-maps/`, so only they are what `scripts/scaffold.sh --for` and the `scaffold-check` gate pick. The kit
templates stay untouched and unlinked. The decision is recorded in [memory].

## Using them

```sh
scripts/scaffold.sh --for <new file>        # which template fits, with the command prefilled
scripts/scaffold.sh [--test] project/<layer>/<name> '<json>' <new file>
```

Every template's header comment holds:
- the exemplar it follows;
- the Target path;
- its Vars;
- what is left to you.

`<name>.example.json` next to each template is a complete, working set of variables. Its `_target` is
where the smoke test renders it. `<name>.<variant>.example.json` is a second shape of the same
template, e.g. `adapter/controller.admin`: a command controller over `OauthAdminApi`.

**Shared variable conventions**
- `package` is the file's **full** package; no layer suffix is appended. `scaffold.sh` still refuses a
  target outside that package's directory.
- `Name` / `name` are the aggregate in PascalCase and camelCase.
- `fields[]` items: `type`, `name`, `Cap` (`name` capitalised), `example` (a Java expression), and
  optionally:
  - `notBlank`: use `StringValidator.notBlank` instead of `notNull`;
  - `primitive`: no null check;
  - `column`, `sqlType`, `nullable`, `unique`: the persistence templates;
  - `last`: the record components of `gateway-dto`.
- Mustache cannot reach an outer variable that a list item shadows, so items use `Cap`, never `Name`.
- `keyType` / `keyName` / `KeyCap` add `findBy<Key>` and `deleteBy<Key>`. Leave them out for no key.
- `imports[]` adds imports, e.g. `java.util.UUID`, `java.time.LocalDate`.
- **Every variable is written `{{{triple}}}`.** mustache.js HTML-escapes `{{double}}` output, which
  turns `/gadgets` into `&#x2F;gadgets` and `"x"` into `&quot;x&quot;`. Keep new templates unescaped as
  well.

## A new bounded context

```sh
scripts/scaffold/new-context.sh [--gateway] <capability> <Ctx> <basePackage> <apis> <models>
```

This renders the module build files, `<Ctx>BeanConfig`, the adapter's `AbstractRepositoryTest` and test
`application.properties`, plus a copy of `init_postgres.sql`. `--gateway` also adds a
`<capability>-gateway` module, with its build file and WireMock `TestConfig`, that the adapter depends
on. The script registers the modules in `settings.gradle.kts` and `application/build.gradle.kts`. Then
render the aggregate's files layer by layer:

1. **domain:** create-request, entity, factory, mother, factory-test, entity-test; value-object, id,
   coded-enum and exception as needed;
2. **usecase:** repository-port, request, then the create / query / delete / presenter use cases and
   their tests;
3. **gateway:** gateway-dto, gateway-port, rest-gateway (+ test), gateway-dto-mother;
4. **adapter:** flyway-migration, jpa-entity, jpa-repository, default-repository (+ test), the mappers,
   controller (+ test).

## Templates

| Layer | Templates |
|-------|-----------|
| module | `domain-build`, `usecase-build`, `adapter-build`, `gateway-build`, `abstract-repository-test`, `test-application-properties`, `gateway-test-config` |
| domain | `entity` (+ `entity-test`), `create-request`, `factory` (+ `-test`), `mother`, `fixed-mother`, `value-object` (+ `-test`), `id`, `coded-enum` (+ `-test`), `exception` |
| usecase | `repository-port`, `query-repository-port`, `facade-port`, `request`, `projection`, `domain-event`, `create-usecase` / `query-usecase` / `delete-usecase` / `presenter-usecase` (each + `-test`) |
| gateway | `gateway-port`, `rest-gateway` (+ `-test`), `gateway-dto`, `gateway-dto-mother` |
| adapter | `bean-config`, `jpa-entity`, `jpa-repository`, `default-repository` (+ `-test`), `flyway-migration`, `attribute-converter` (+ `-test`), `cache-refresh` (+ `-test`), `controller` (+ `-test`), `domain-to-dto-mapper`, `request-dto-to-domain-mapper`, `gateway-to-domain-mapper`, `code-enum-mapper` (each + `-test`) |

**Conventions encoded**
- Use cases: jakarta `@Transactional`, no `@Service`, registered by `<Ctx>BeanConfig`.
- Caller: `AuthenticationFacade`, not an organisation id.
- Tests: JUnit 5, AssertJ and Mockito, `givenX_whenY_thenZ`, `// Given / When / Then`, fixed fixture
  values.
- Test data: Mothers shared through `test-jar-producer`.
- Spring Boot 4 test packages.
- `@Scheduled` always with `@BatchJob`.

**Authorization**
- The controller template never decides authorization. `preAuthorize` comes from the ticket and the
  access matrix.
- Leave it out only for `/api/admin/**` operations, which the admin `SecurityFilterChain` guards.

**Controller tests** list their beans (`@ContextConfiguration(classes = {Controller, mappers})`)
instead of scanning the controller package. Each controller's test is then independent of the module's
other controllers.

**Not templated** (too rare or too specific to pay for itself):
- CXF SOAP `WebServiceConfig` (3 modules);
- FHIR resource builders;
- abstract polymorphic aggregates;
- a gateway-backed `Default<Name>Repository`: compose `gateway-port` and `gateway-to-domain-mapper` by
  hand.

## Scaffold

What `scripts/scaffold.sh --for`, the build's scaffold step and the scaffold-check gate offer for a path (read by
`scripts/scaffold/targets.js`; links relative to this folder). With `"projectOnly": true` in `scaffold.json` these rows
are the only ones offered: the kit's own worked-example rows are dropped. A new template gets its row here;
`scripts/test/scaffold-wiring.test.sh` fails a template without one.

| Template | Target | Variables | Left to you |
|---|---|---|---|
| [project/module/abstract-repository-test](module/abstract-repository-test.mustache) | `<capability>-adapter/src/test/java/<pkg>/adapter/repository/AbstractRepositoryTest.java` | package | - |
| [project/module/adapter-build](module/adapter-build.mustache) | `<capability>-adapter/build.gradle.kts` | capability, apiPackage, apis, models, gateway | - |
| [project/module/domain-build](module/domain-build.mustache) | `<capability>-domain/build.gradle.kts` | capability | - |
| [project/module/gateway-build](module/gateway-build.mustache) | `<capability>-gateway/build.gradle.kts` | capability, authentication | - |
| [project/module/gateway-test-config](module/gateway-test-config.mustache) | `<capability>-gateway/src/test/java/<pkg>/gateway/TestConfig.java` | package, gatewayPackage, restClient | - |
| [project/module/test-application-properties](module/test-application-properties.mustache) | `<capability>-adapter/src/test/resources/application.properties` | - | - |
| [project/module/usecase-build](module/usecase-build.mustache) | `<capability>-usecase/build.gradle.kts` | capability, authentication | - |
| [project/domain/coded-enum](domain/coded-enum.mustache) | `<capability>-domain/src/main/java/<pkg>/domain/<aggregate>/<Name>.java` | package, Name, constants | - |
| [project/domain/coded-enum](domain/coded-enum.mustache) | `<capability>-adapter/src/main/java/<pkg>/adapter/gateway/<Name>.java` | package, Name, constants | - |
| [project/domain/coded-enum-test](domain/coded-enum-test.mustache) | `<capability>-domain/src/test/java/<pkg>/domain/<aggregate>/<Name>Test.java` | package, Name | - |
| [project/domain/create-request](domain/create-request.mustache) | `<capability>-domain/src/main/java/<pkg>/domain/<aggregate>/Create<Name>DomainRequest.java` | package, Name, name, domainPackage, portPackage, usecasePackage, fixture, imports, fields | - |
| [project/domain/entity](domain/entity.mustache) | `<capability>-domain/src/main/java/<pkg>/domain/<aggregate>/<Name>.java` | package, Name, name, domainPackage, portPackage, usecasePackage, fixture, imports, fields | - |
| [project/domain/entity-test](domain/entity-test.mustache) | `<capability>-domain/src/test/java/<pkg>/domain/<aggregate>/<Name>Test.java` | package, Name, name, domainPackage, portPackage, usecasePackage, fixture, fixtures | - |
| [project/domain/exception](domain/exception.mustache) | `<capability>-domain/src/main/java/<pkg>/domain/<aggregate>/<Name>Exception.java` | package, Name | - |
| [project/domain/exception](domain/exception.mustache) | `<capability>-gateway/src/main/java/<pkg>/gateway/<Name>Exception.java` | package, Name | - |
| [project/domain/factory](domain/factory.mustache) | `<capability>-domain/src/main/java/<pkg>/domain/<aggregate>/<Name>Factory.java` | package, Name, name, domainPackage, portPackage, usecasePackage, fixture | - |
| [project/domain/factory-test](domain/factory-test.mustache) | `<capability>-domain/src/test/java/<pkg>/domain/<aggregate>/<Name>FactoryTest.java` | package, Name, name, domainPackage, portPackage, usecasePackage, fixture, imports, fields | - |
| [project/domain/fixed-mother](domain/fixed-mother.mustache) | `<capability>-domain/src/test/java/<pkg>/domain/<aggregate>/<Name>FixedMother.java` | package, Name, Mother, imports, constants, fixtures | - |
| [project/domain/id](domain/id.mustache) | `<capability>-domain/src/main/java/<pkg>/domain/<aggregate>/<Name>Id.java` | package, Name | - |
| [project/domain/mother](domain/mother.mustache) | `<capability>-domain/src/test/java/<pkg>/domain/<aggregate>/<Name>Mother.java` | package, Name, name, domainPackage, portPackage, usecasePackage, fixture, imports, fields, fixtures | - |
| [project/domain/value-object](domain/value-object.mustache) | `<capability>-domain/src/main/java/<pkg>/domain/<aggregate>/<Name>.java` | package, Name, type, notBlank, maxLength | - |
| [project/domain/value-object-test](domain/value-object-test.mustache) | `<capability>-domain/src/test/java/<pkg>/domain/<aggregate>/<Name>Test.java` | package, Name, example, notBlank, maxLength | - |
| [project/usecase/create-usecase](usecase/create-usecase.mustache) | `<capability>-usecase/src/main/java/<pkg>/usecase/<aggregate>/Create<Name>UseCase.java` | package, Name, name, domainPackage, portPackage, usecasePackage, fixture, fields | - |
| [project/usecase/create-usecase-test](usecase/create-usecase-test.mustache) | `<capability>-usecase/src/test/java/<pkg>/usecase/<aggregate>/Create<Name>UseCaseTest.java` | package, Name, name, domainPackage, portPackage, usecasePackage, fixture, imports, fields | - |
| [project/usecase/delete-usecase](usecase/delete-usecase.mustache) | `<capability>-usecase/src/main/java/<pkg>/usecase/<aggregate>/Delete<Name>UseCase.java` | package, Name, name, domainPackage, portPackage, usecasePackage, fixture, keyType, keyName, KeyCap, keyNotBlank, imports | - |
| [project/usecase/delete-usecase-test](usecase/delete-usecase-test.mustache) | `<capability>-usecase/src/test/java/<pkg>/usecase/<aggregate>/Delete<Name>UseCaseTest.java` | package, Name, name, domainPackage, portPackage, usecasePackage, fixture, keyType, keyName, KeyCap, keyExample, imports | - |
| [project/usecase/domain-event](usecase/domain-event.mustache) | `<capability>-usecase/src/main/java/<pkg>/usecase/<aggregate>/events/<Name>Event.java` | package, Name, domainPackage, Aggregate, aggregate | - |
| [project/usecase/facade-port](usecase/facade-port.mustache) | `<capability>-usecase/src/main/java/<pkg>/usecase/<aggregate>/repository/<Name>Facade.java` | package, Name, imports, methods | - |
| [project/usecase/presenter-usecase](usecase/presenter-usecase.mustache) | `<capability>-usecase/src/main/java/<pkg>/usecase/<aggregate>/Get<Name>UseCase.java` | package, Name, name, domainPackage, portPackage, imports, keyType, keyName, KeyCap | - |
| [project/usecase/presenter-usecase-test](usecase/presenter-usecase-test.mustache) | `<capability>-usecase/src/test/java/<pkg>/usecase/<aggregate>/Get<Name>UseCaseTest.java` | package, Name, name, domainPackage, portPackage, usecasePackage, fixture, imports, KeyCap, keyExample | - |
| [project/usecase/projection](usecase/projection.mustache) | `<capability>-usecase/src/main/java/<pkg>/usecase/<aggregate>/<Name>Projection.java` | package, Name, fields | - |
| [project/usecase/query-repository-port](usecase/query-repository-port.mustache) | `<capability>-usecase/src/main/java/<pkg>/usecase/<aggregate>/repository/<Name>QueryRepository.java` | package, Name, imports, queries | - |
| [project/usecase/query-usecase](usecase/query-usecase.mustache) | `<capability>-usecase/src/main/java/<pkg>/usecase/<aggregate>/Get<Name>sUseCase.java` | package, Name, name, domainPackage, portPackage, usecasePackage, fixture | - |
| [project/usecase/query-usecase-test](usecase/query-usecase-test.mustache) | `<capability>-usecase/src/test/java/<pkg>/usecase/<aggregate>/Get<Name>sUseCaseTest.java` | package, Name, name, domainPackage, portPackage, usecasePackage, fixture | - |
| [project/usecase/repository-port](usecase/repository-port.mustache) | `<capability>-usecase/src/main/java/<pkg>/usecase/<aggregate>/repository/<Name>Repository.java` | package, Name, name, domainPackage, portPackage, usecasePackage, fixture, keyType, keyName, KeyCap, imports | - |
| [project/usecase/request](usecase/request.mustache) | `<capability>-usecase/src/main/java/<pkg>/usecase/<aggregate>/<Request>Request.java` | package, Request, imports, fields | - |
| [project/gateway/gateway-dto](gateway/gateway-dto.mustache) | `<capability>-gateway/src/main/java/<pkg>/gateway/dto/Gateway<Name>.java` | package, Name, fields | - |
| [project/gateway/gateway-dto-mother](gateway/gateway-dto-mother.mustache) | `<capability>-gateway/src/test/java/<pkg>/gateway/dto/Gateway<Name>Mother.java` | package, Name, fixtures | - |
| [project/gateway/gateway-port](gateway/gateway-port.mustache) | `<capability>-gateway/src/main/java/<pkg>/gateway/<Name>Gateway.java` | package, Name, name, dtoPackage, bearer | - |
| [project/gateway/rest-gateway](gateway/rest-gateway.mustache) | `<capability>-gateway/src/main/java/<pkg>/gateway/Default<Name>Gateway.java` | package, Name, name, dtoPackage, bearer, restClient, property, path, exceptionClass | - |
| [project/gateway/rest-gateway-test](gateway/rest-gateway-test.mustache) | `<capability>-gateway/src/test/java/<pkg>/gateway/Default<Name>GatewayTest.java` | package, configPackage, Name, name, dtoPackage, bearer, restClient, property, path, exceptionClass, responseBody, firstField, firstValue | - |
| [project/adapter/attribute-converter](adapter/attribute-converter.mustache) | `<capability>-adapter/src/main/java/<pkg>/adapter/repository/<Name>Converter.java` | package, Name, separator | - |
| [project/adapter/attribute-converter-test](adapter/attribute-converter-test.mustache) | `<capability>-adapter/src/test/java/<pkg>/adapter/repository/<Name>ConverterTest.java` | package, Name, separator | - |
| [project/adapter/bean-config](adapter/bean-config.mustache) | `<capability>-adapter/src/main/java/<pkg>/adapter/config/<Ctx>BeanConfig.java` | package, Ctx, ctx, usecaseBasePackage, domainBasePackage | - |
| [project/adapter/cache-refresh](adapter/cache-refresh.mustache) | `<capability>-adapter/src/main/java/<pkg>/adapter/config/<Name>CacheConfig.java` | package, Name, name, domainPackage, portPackage, cache, key, delay, unit, jobName | - |
| [project/adapter/cache-refresh-test](adapter/cache-refresh-test.mustache) | `<capability>-adapter/src/test/java/<pkg>/adapter/config/<Name>CacheConfigTest.java` | package, Name, name, domainPackage, portPackage, cache, key, fixture | - |
| [project/adapter/code-enum-mapper](adapter/code-enum-mapper.mustache) | `<capability>-adapter/src/main/java/<pkg>/adapter/gateway/<Name>Mapper.java` | package, Name, Domain, External, imports, pairs | - |
| [project/adapter/code-enum-mapper-test](adapter/code-enum-mapper-test.mustache) | `<capability>-adapter/src/test/java/<pkg>/adapter/gateway/<Name>MapperTest.java` | package, Name, Domain, External, imports, pairs | - |
| [project/adapter/controller](adapter/controller.mustache) | `<capability>-adapter/src/main/java/<pkg>/adapter/controller/<Name>Controller.java` | package, Name, Api, imports, useCases, operations, mapper | - |
| [project/adapter/controller-test](adapter/controller-test.mustache) | `<capability>-adapter/src/test/java/<pkg>/adapter/controller/<Name>ControllerTest.java` | package, Name, imports, useCases, cases, beans | - |
| [project/adapter/default-repository](adapter/default-repository.mustache) | `<capability>-adapter/src/main/java/<pkg>/adapter/repository/Default<Name>Repository.java` | package, Name, name, domainPackage, portPackage, usecasePackage, fixture, keyType, keyName, KeyCap, imports | - |
| [project/adapter/default-repository-test](adapter/default-repository-test.mustache) | `<capability>-adapter/src/test/java/<pkg>/adapter/repository/Default<Name>RepositoryTest.java` | package, Name, name, domainPackage, portPackage, usecasePackage, fixture, keyType, keyName, KeyCap | - |
| [project/adapter/domain-to-dto-mapper](adapter/domain-to-dto-mapper.mustache) | `<capability>-adapter/src/main/java/<pkg>/adapter/controller/<Name>DomainToDTOMapper.java` | package, Name, name, domainPackage, portPackage, usecasePackage, fixture, Dto, mappings | - |
| [project/adapter/domain-to-dto-mapper-test](adapter/domain-to-dto-mapper-test.mustache) | `<capability>-adapter/src/test/java/<pkg>/adapter/controller/<Name>DomainToDTOMapperTest.java` | package, Name, name, domainPackage, portPackage, usecasePackage, fixture, mappings | - |
| [project/adapter/flyway-migration](adapter/flyway-migration.mustache) | `<capability>-adapter/src/main/resources/db/migration/ddl/V<N>.<NNN>__create_<table>.sql` | table, fields | - |
| [project/adapter/gateway-to-domain-mapper](adapter/gateway-to-domain-mapper.mustache) | `<capability>-adapter/src/main/java/<pkg>/adapter/gateway/Gateway<Name>ToDomainMapper.java` | package, Name, domainPackage, dtoPackage, imports, mappings | - |
| [project/adapter/gateway-to-domain-mapper-test](adapter/gateway-to-domain-mapper-test.mustache) | `<capability>-adapter/src/test/java/<pkg>/adapter/gateway/Gateway<Name>ToDomainMapperTest.java` | package, Name, domainPackage, dtoPackage, gatewayFixture, fixture | - |
| [project/adapter/jpa-entity](adapter/jpa-entity.mustache) | `<capability>-adapter/src/main/java/<pkg>/adapter/repository/<Name>JpaEntity.java` | package, Name, name, domainPackage, portPackage, usecasePackage, fixture, table, imports, fields | - |
| [project/adapter/jpa-repository](adapter/jpa-repository.mustache) | `<capability>-adapter/src/main/java/<pkg>/adapter/repository/<Name>JpaRepository.java` | package, Name, name, domainPackage, portPackage, usecasePackage, fixture, keyType, keyName, KeyCap, imports | - |
| [project/adapter/request-dto-to-domain-mapper](adapter/request-dto-to-domain-mapper.mustache) | `<capability>-adapter/src/main/java/<pkg>/adapter/controller/<Name>RequestDTOToDomainMapper.java` | package, Name, Dto, Request, imports, mappings | - |
| [project/adapter/request-dto-to-domain-mapper-test](adapter/request-dto-to-domain-mapper-test.mustache) | `<capability>-adapter/src/test/java/<pkg>/adapter/controller/<Name>RequestDTOToDomainMapperTest.java` | package, Name, Dto, dtoValues, checks | - |

## Checking a change to a template

```sh
scripts/scaffold/smoke.sh                 # render all, then compile and test zzsmoke-* + the architecture tests
scripts/scaffold/smoke.sh --render-only   # render only (seconds)
scripts/scaffold/smoke.sh --keep          # keep the throwaway copy to look at the generated code
bash scripts/test/scaffold.test.sh        # the wiring, in seconds: every template linked, --for, scaffold-step
```

`scripts/test/scaffold.test.sh` checks that the templates stay wired into the existing scaffold scripts. Every
template must be linked from a code-map row whose Target matches its example's `_target`, and no row may link a kit
template. It also checks that `scripts/scaffold.sh --for` offers the project template, and that the build workflow's
`.archon/scripts/scaffold-step.js` renders `Scaffold: project/...` plan lines, filling `package` and `Name` from the
path and writing the `SCAFFOLD` record the `scaffold-check` gate counts. `affected-check` runs it whenever
`scripts/scaffold/` changes.

The script works in a throwaway copy: `HEAD` plus your uncommitted changes. It never touches the
checkout. It needs Docker for the Testcontainers repository test, and network access for the OpenAPI
spec. A new template must ship with its `.example.json`, or the smoke test fails. Link it from the
owning code-map's `## Scaffold` table.

[memory]: ../../memory.md
