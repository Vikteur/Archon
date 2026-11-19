---
runtime: lazy
kind: worked-example
---

<!-- AI_DISCLAIMER v1.0 -->
# Code map — `domain-modeling` (project: `shop-backend`)

> This file has been created (totally or partially) with the assistance of artificial intelligence tools.
> All content has been generated under the direct supervision of a named individual,
> and under the AI.Backbone Orchestrator Compliance framework

## This repo (wedding-portal)
These are the real facts. Everything from "Where this pattern lives" down is the pseudonymized worked example
(`shop-backend`): follow its structure, not its names. Decisions: [memory, 2026-10-17].

- **Ids** are typed UUID records (`record GadgetId(UUID value)`); aggregates refer to each other by id only.
- **No tenancy field** on an aggregate: the organisation is a repository-port parameter ([usecase-orchestration]).
- Final fields; state changes through named methods (state machines); enums are mapped to contract values in the web
  mappers, not in the domain.
- Derived ids are pure functions with characterization tests. The domain never reads the clock or makes randomness.
- Factories return `Creation<T>` ([validation-notification-result]). Lombok is allowed.

## Where this pattern lives (exemplars)
| Exemplar | What it shows | Layer / module |
|----------|---------------|----------------|
| [`OrderCode.java`](exemplars/order-code.md#domain-modeling) | Package-private constructor + static factory, `Objects.requireNonNull` invariants, Lombok value semantics | domain (`order-domain`) |

### Excerpts
Hand-written value object (full source in the [exemplar leaf](exemplars/order-code.md#domain-modeling)):
```java
OrderCode(String code, OrderCodeType type) {
    this.code = Objects.requireNonNull(code);
    this.type = Objects.requireNonNull(type);
}

public static OrderCode of(final String value, final OrderCodeType type) {
    return new OrderCode(value, type);
}
```

Plain `record` shape, used when no custom validation is needed (`account-domain`):
```java
@Builder
public record CustomerAddress(
         SalesRegion region,
         String regionCode,
         String cityName,
         String postalCode
) implements Serializable { }
```

### Edge cases
Record with a `null` component (records do not null-check by themselves):
```java
var address = CustomerAddress.builder().cityName("Springfield").build();
assertThat(address.region()).isNull();
assertThat(address.postalCode()).isNull();
```
Expected: construction succeeds; null checks, if needed, belong in a validating factory (see [validation-notification-result]).

Value equality on records:
```java
var a = CustomerAddress.builder().cityName("Springfield").postalCode("00000").build();
var b = CustomerAddress.builder().cityName("Springfield").postalCode("00000").build();
assertThat(a).isEqualTo(b).hasSameHashCodeAs(b);
```
Expected: equal by component values; no `@EqualsAndHashCode` needed on a record.

Hand-written value object with an invalid argument:
```java
assertThatThrownBy(() -> OrderCode.of(null, OrderCodeType.SKU))
        .isInstanceOf(NullPointerException.class);
```
Expected: fails fast at construction — no half-built instance exists.

## Scaffold
Render the base case with `scripts/scaffold.sh <template> '<json on one line>' <target>` from the repo root. Each
template's header comment lists its exact variables. Fill them from the ticket's data model; the script refuses to
overwrite an existing file.

| Template | Target | Variables | Left to you |
|---|---|---|---|
| [domain/create-request](../scaffold-templates/domain/create-request.mustache) | `<capability>-domain/src/main/java/<pkg>/domain/Create<Name>Request.java` | `package` (base package, without `.domain`), `basePackage`, `Name`, `fields[type, name]`; `organisationId` is always the first field | imports for field types; an update-request variant |
| [domain/create-or-update-request](../scaffold-templates/domain/create-or-update-request.mustache) | `.../domain/CreateOrUpdate<Name>Request.java` | `package` (base package, without `.domain`), `basePackage`, `Name`, `fields[type, name]` (include the key field); `organisationId` is always the first field | imports for field types |
| [domain/entity](../scaffold-templates/domain/entity.mustache) | `.../domain/<Name>.java` | `package` (base package, without `.domain`), `basePackage`, `Name`, `upsert`, `fields[type, name, pascal, identity]` (`identity` marks the key field) | `StringValidator.notBlank` for String fields; drop `notNull` on optional fields; cross-field rules; state-change methods other than `update()`; imports |
| [domain/factory](../scaffold-templates/domain/factory.mustache) | `.../domain/<Name>Factory.java` | `package` (base package, without `.domain`), `basePackage`, `Name`, `name`, `upsert` | nothing for the base case |
| [domain/id](../scaffold-templates/domain/id.mustache) | `.../domain/<Name>Id.java` | `package` (base package, without `.domain`), `Name` | nothing: every aggregate key is a typed UUID id |
| [domain/record](../scaffold-templates/domain/record.mustache) | `.../domain/<Name>.java` | `package` (base package, without `.domain`), `Name`, `fields[type, name, last]` | imports |
| [domain/value-object](../scaffold-templates/domain/value-object.mustache) | `.../domain/<Name>.java` | `package` (base package, without `.domain`), `Name`, `fields[type, name, last]` | format or range checks beyond null; imports |

An aggregate is create-request + entity + factory, rendered together. Its tests come from `jvm-testing`
(factory-test) and `object-mother-builders` (mother).

An aggregate that is written by its key (create-or-update) uses create-or-update-request instead of create-request,
and entity, factory, mother and factory-test are all rendered with `upsert: true`; `update()` gets its test from
`jvm-testing` (entity-test). The rest of that write path is in `usecase-orchestration`.

## Local conventions (the project facts the skill omits)
- Package root: `<capability>-domain/src/main/java/.../domain/`.
- Naming shape: two coexisting shapes — a plain `record` for value objects with no custom
  validation (for example `CustomerAddress` in `account-domain`), and a Lombok class with a
  package-private constructor + static `of(...)`/factory method when construction needs to validate
  or Lombok's generated equality is preferred (for example `OrderCode`).
- Required collaborators / base types: `Objects.requireNonNull` for fail-fast invariant checks;
  `@Getter @EqualsAndHashCode @ToString` when not using a `record`.
- Config / wiring: none.

## Frequency & coverage (why this earned a skill)
- Occurrences: 105 `record` declarations across 21 modules (as of `abc1234`) — the more common
  shape; the hand-written value-object shape (like `OrderCode`) is used specifically when a factory
  needs to run validation logic.

## Drift / exceptions
- Two value-object shapes coexist by design (record vs. Lombok class + factory) — not drift, pick
  based on whether construction needs validation beyond what a canonical record constructor
  expresses tersely.

## Provenance
- Scanned at: `abc1234` · tool/query: `rg '^\s*(public\s+)?record\s+[A-Za-z]+' --glob '*.java'`

[validation-notification-result]: validation-notification-result.md

[memory, 2026-10-17]: ../memory.md
[usecase-orchestration]: usecase-orchestration.md
