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
