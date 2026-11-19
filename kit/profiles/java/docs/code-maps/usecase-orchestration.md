---
runtime: lazy
kind: worked-example
---

<!-- AI_DISCLAIMER v1.0 -->
# Code map — `usecase-orchestration` (project: `shop-backend`)

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
| [`GetInvoicesUseCase.java`](exemplars/get-invoices-usecase.md#usecase-orchestration) | Plain `*UseCase` class, one `execute()` entry point, resolves the principal via `AuthenticationFacade` | usecase (`invoice-usecase`) |

### Excerpts
Single public orchestration entry point:
```java
public InvoiceInfo execute() {
    var invoiceInfo = invoicesRepository.getInvoices(authenticationFacade.getAuthentication());

    var invoiceSummaries = invoiceInfo.invoiceSummaries().stream()
            .filter(summary -> !EXCLUDED_DOCUMENT_TYPES.contains(summary.documentType()))
            .toList();
```

Feature-flagged enrichment stays inside the use case:
```java
return new InvoiceInfo(
        collectionsEnabled() ? invoiceCollectionEnricher.enrich(invoiceSummaries) : invoiceSummaries,
        invoiceInfo.customerArchived(),
        invoiceInfo.unavailableResultsFromPartners()
);
```

### Edge cases
Only excluded document types are returned from the repository:
```java
when(invoicesRepository.getInvoices(customer))
        .thenReturn(new InvoiceInfo(List.of(excludedInvoice), false, List.of()));
```
Expected: `execute()` returns an empty summary list instead of leaking filtered types past the use case.

Feature flag is disabled:
```java
when(featureFlagUseCase.execute()).thenReturn(List.of());
var result = getInvoicesUseCase.execute();
```
Expected: summaries are returned unchanged and `invoiceCollectionEnricher` is not called.

Partners report partial availability:
```java
new InvoiceInfo(List.of(invoice), false, List.of("Acme Springfield"));
```
Expected: `unavailableResultsFromPartners()` is preserved as-is while the use case still filters summaries.

## Scaffold
Render the base case with `scripts/scaffold.sh <template> '<json on one line>' <target>` from the repo root. Each
template's header comment lists its exact variables; the script refuses to overwrite an existing file.

| Template | Target | Variables | Left to you |
|---|---|---|---|
| [usecase/repository-port](../scaffold-templates/usecase/repository-port.mustache) | `<capability>-usecase/src/main/java/<pkg>/repository/<Name>Repository.java` | `package` (base package, without `.repository`), `basePackage`, `Name`, `method` + `Result` (a query; hand-write its adapter side), `Key` + `key` + `keyType` (a lookup); every method takes `OrganisationId` first | more methods; parameters; who the user is (a STOP item) |
| [usecase/usecase](../scaffold-templates/usecase/usecase.mustache) | `.../usecase/<Name>UseCase.java` | `package` (base package, without `.usecase`), `basePackage`, `Name`, `Result`, `Repository`, `repository`, `method`; `execute(OrganisationId)` | who the user is (a STOP item); a request input; creation through a factory and its Notification; several ports; events; writes |
| [usecase/repository-port-crud](../scaffold-templates/usecase/repository-port-crud.mustache) | `<capability>-usecase/src/main/java/<pkg>/repository/<Name>Repository.java` | `package` (base package, without `.repository`), `basePackage`, `Name`, `name`, `key`, `keyType`; every method takes `OrganisationId` first | query methods beyond the key |
| [usecase/domain-config](../scaffold-templates/usecase/domain-config.mustache) | `.../config/<Name>DomainConfig.java` | `package` (base package, without `.config`), `Name`, `name` | one `@Produces` method per further Factory of the context |
| [usecase/usecase-create-or-update](../scaffold-templates/usecase/usecase-create-or-update.mustache) | `.../usecase/CreateOrUpdate<Name>UseCase.java` | `package` (base package, without `.usecase`), `basePackage`, `Name`, `name`, `Key` | who the user is (a STOP item); events; other ports |
| [usecase/usecase-delete](../scaffold-templates/usecase/usecase-delete.mustache) | `.../usecase/Delete<Name>UseCase.java` | `package` (base package, without `.usecase`), `basePackage`, `Name`, `name`, `key`, `keyType`; an unknown key returns `NOT_FOUND` | who the user is (a STOP item); drop the key from the error message when it is a personal identifier |
| [usecase/command](../scaffold-templates/usecase/command.mustache) | `.../usecase/<Name>Command.java` | `package` (base package, without `.usecase`), `Name`, `imports`, `fields` (`type`, `name`, `last`), `redacted` (a `toString` that hides every value) | validation (the factory's Notification); compact-constructor checks |
| [usecase/outcome](../scaffold-templates/usecase/outcome.mustache) | `.../usecase/<Name>Outcome.java` | `package` (base package, without `.usecase`), `Name`, `imports`, `cases` (`Case`, and its `fields` with `type`, `name`, `last`; none for a case that carries nothing) | methods on a case |

The base case is a read: `execute()` returns one port call. Its test comes from `jvm-testing` (usecase-test).

A use case that takes input renders a command for it, and one that ends in more than one way (created, already
there, refused) an outcome, whose sealed cases the caller's switch must all cover: then hand-edit the rendered use
case to `execute(OrganisationId, <Name>Command)` returning the outcome. A command that carries a secret or a personal
identifier takes `redacted: true`, so its values never reach a log line or an exception message.

A write by key (create-or-update and delete) uses repository-port-crud instead of repository-port, plus
usecase-create-or-update and usecase-delete. They need the aggregate rendered with `upsert: true` (`domain-modeling`);
their tests come from `jvm-testing` (usecase-create-or-update-test, usecase-delete-test), the port's implementation
from `persistence-repository` (default-repository-crud).

## Local conventions (the project facts the skill omits)
- A use case that only ever runs inside another use case's transaction is `@Transactional(TxType.MANDATORY)`
  (TASK-48.8, `TakeBillingNumberUseCase`).
- Package root: `<capability>-usecase/src/main/java/com/acme/shop/<capability>/usecase/`.
- Naming shape: `*UseCase` — there is no `@UseCase` annotation in this codebase; the class-name
  suffix alone is the marker.
- Required collaborators / base types: no interface, no base class. `@ApplicationScoped` +
  `@Transactional` (`jakarta.transaction`) + `@RequiredArgsConstructor`. Entry point is always
  `execute(...)` (no-arg or with a request object).
- Config / wiring: CDI bean annotated directly (constructor injection), never returned from a
  `@Produces` method — CDI interceptors such as `@Transactional` do not apply to producer-method beans.

## Frequency & coverage (why this earned a skill)
- Occurrences: 180 files across 14 `*-usecase` modules (as of `abc1234`).
- Hotspots: every capability's `*-usecase` module.

## Drift / exceptions
- None observed — the `*UseCase` + `execute()` shape is uniform across all 14 modules.

## Provenance
- Scanned at: `abc1234` · tool/query: `rg 'class[[:space:]]+[A-Za-z]*UseCase\b' --glob '*.java'`

[memory, 2026-10-17]: ../memory.md
[validation-notification-result]: validation-notification-result.md
