---
runtime: lazy
kind: worked-example
---

<!-- AI_DISCLAIMER v1.0 -->
# Code map — `domain-dto-mapper` (project: `shop-backend`)

> This file has been created (totally or partially) with the assistance of artificial intelligence tools.
> All content has been generated under the direct supervision of a named individual,
> and under the AI.Backbone Orchestrator Compliance framework

## Where this pattern lives (exemplars)
| Exemplar | What it shows | Layer / module |
|----------|---------------|----------------|
| [`RegistryMapper.java`](exemplars/registry-mapper.md#domain-dto-mapper) | Wire-to-domain mapper, static lookup table built in `@PostConstruct`, null/unknown-safe | gateway (`partner-gateway`) |

### Excerpts
Lookup table initialized once:
```java
@PostConstruct
protected void init() {
    this.registries = new HashMap<>();
    this.registries.put("1000000002", Registry.LOYALTY);
    this.registries.put("1000000003", Registry.PAYMENTS);
}
```

Mapping pipeline keeps unknown values out of the domain:
```java
return registryList.stream()
        .map(partnerRecordType -> partnerRecordType.getIds().isEmpty()
                || partnerRecordType.getIds().get(0) == null
                || partnerRecordType.getIds().get(0).getValue() == null ? null : partnerRecordType.getIds().get(0).getValue())
        .filter(Objects::nonNull)
        .map(id -> registries.get(id))
        .filter(Objects::nonNull)
        .toList();
```

### Edge cases
First identifier list is empty:
```java
input.get(0).getIds().clear();
var result = registryMapper.mapRegistries(input);
```
Expected: the unmappable entry is dropped; remaining mapped entries keep their order.

First identifier object exists but its value is `null`:
```java
input.get(0).getIds().get(0).setValue(null);
var result = registryMapper.mapRegistries(input);
```
Expected: the mapper returns only the mapped registries and never throws.

Unknown partner id comes in from the wire payload:
```java
unknownRegistry.setValue("unknown-registry");
input.get(0).getIds().add(unknownRegistry);
```
Expected: unknown ids are ignored instead of leaking a placeholder into the domain.

## Scaffold
Render the base case with `scripts/scaffold.sh <template> '<json on one line>' <target>` from the repo root. The
template's header comment lists its exact variables; the script refuses to overwrite an existing file.

| Template | Target | Variables | Left to you |
|---|---|---|---|
| [adapter/to-dto-mapper](../scaffold-templates/adapter/to-dto-mapper.mustache) | `<capability>-adapter/src/main/java/<pkg>/adapter/controller/<Domain>ToDTOMapper.java` | `package` (base package, without `.adapter.controller`), `modelPackage`, `Domain`, `domain`, `record` (true when the domain type is a record), `fields[name, pascal]` | enum translation; nested and collection fields; null handling; a `toDomain` direction |
| [adapter/request-dto-to-domain-mapper](../scaffold-templates/adapter/request-dto-to-domain-mapper.mustache) | `.../adapter/controller/<Name>RequestDTOToDomainMapper.java` | `package` (base package, without `.adapter.controller`), `basePackage`, `Name`, `Dto`, `modelPackage`, `fields[name, pascal, enumType, typedId]` (`enumType` only for a domain enum mapped by name, `typedId` only for a domain id type wrapping a UUID); `map` takes the caller's `OrganisationId` first | collections of enums (a stream map); nested DTOs; its test |

## Local conventions (the project facts the skill omits)
- Package root: alongside the type it converts (gateway package for wire → domain, adapter/controller
  package for domain → DTO).
- Naming shape: `*Mapper` (wire/DTO ↔ domain, for example `RegistryMapper`) or `*ToDTOMapper`
  (domain → DTO specifically). Some are static-method utility classes; others are CDI
  `@ApplicationScoped` beans when they need lifecycle callbacks or collaborators.
- Required collaborators / base types: field-explicit mapping, no reflection-based or generic mapping
  library.
- Config / wiring: none for static mappers; `@ApplicationScoped` + `@PostConstruct` only when needed.

## Frequency & coverage (why this earned a skill)
- Occurrences: 172 matches across 171 files, 15 modules (as of `abc1234`).

## Drift / exceptions
- Two shapes coexist (instance `@ApplicationScoped` mapper vs. static-method mapper) depending on whether
  the mapper needs injected state — not drift, a deliberate choice per mapper's needs.

## Provenance
- Scanned at: `abc1234` · tool/query: `rg 'class[[:space:]]+[A-Za-z]*Mapper\b' --glob '*.java'`
