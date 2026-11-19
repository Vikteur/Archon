---
runtime: lazy
kind: worked-example
---

<!-- AI_DISCLAIMER v1.0 -->
# Code map — `resilience4j` (project: `shop-backend`)

> This file has been created (totally or partially) with the assistance of artificial intelligence tools.
> All content has been generated under the direct supervision of a named individual,
> and under the AI.Backbone Orchestrator Compliance framework

## This repo (<project>)
These are the real facts. Everything from "Where this pattern lives" down is the pseudonymized worked example
(`shop-backend`): follow its structure, not its names.

- **This repo uses Resilience4j** (`resilience4j-spring-boot3` plus `spring-boot-starter-aop`): per external
  dependency (`<dependency>`) its own named instance with a timeout (the client's connect/read timeout for a blocking
  client, `@TimeLimiter` only on an async return type), a `@Retry` for idempotent calls only, a `@CircuitBreaker` and
  a fallback.
- Credentials are read by key name from the gateway's `@ConfigurationProperties`, never logged. Tests use WireMock 3.

## Where this pattern lives (exemplars)
| Exemplar | What it shows | Layer / module |
|----------|---------------|----------------|
| [`DefaultRegistryGateway.java`](exemplars/default-registry-gateway.md#resilience4j) | Resilience4j circuit breaker with a degrade-to-empty fallback | adapter/gateway (`partner-gateway`) |

### Excerpts
Degrade-to-empty fallback (full source in the [registry exemplar](exemplars/default-registry-gateway.md#resilience4j)):
```java
@CircuitBreaker(name = "registry", fallbackMethod = "getRegistryLinksFallback")
public List<RegistryLink> getRegistryLinks(final String nid) {
    ...
}

private List<RegistryLink> getRegistryLinksFallback(final String nid, final Exception cause) {
    log.error("Circuit breaker: Failed to fetch registry links");
    return Collections.emptyList();
}
```

### Edge cases
Lookup failure on a non-critical enrichment call:
```java
when(registryPortType.getCustomerLinks(any())).thenThrow(new RuntimeException("timeout"));

assertThat(gateway.getRegistryLinks("00000000000")).isEmpty();
```
Expected: the fallback returns an empty list and the caller keeps moving. `gateway` must be the Spring bean (the AOP
proxy): a `new DefaultRegistryGateway(...)` or a call from inside the class bypasses the breaker and the fallback.

Fallback signature drifts from the guarded method:
```java
@CircuitBreaker(name = "registry", fallbackMethod = "brokenFallback")
public List<RegistryLink> getRegistryLinks(final String nid) { ... }
```
Expected: Resilience4j does not validate fallbacks at startup; the call through the proxy fails with a
`NoSuchMethodException` instead of degrading, so only a test through the Spring bean catches it. A fallback method
must have the guarded method's parameters plus one trailing exception parameter, and the same return type.

## Local conventions (the project facts the skill omits)
- Naming shape: `@CircuitBreaker(name = "<dependency>", fallbackMethod = "<method>Fallback")` — the breaker
  is identified by its instance `name`, one per dependency (here `registry`), which is also its config key;
  the fallback has the guarded method's parameters plus a trailing exception parameter.
- Required collaborators / base types: fallback is a private method in the same `@Component`
  gateway, never a separate bean or a programmatic `Decorators.ofSupplier(...)` wrapper.
- Config / wiring: per-integration overrides live in `application.yml` under
  `resilience4j.circuitbreaker.instances.<name>.*` (profile-specific in `application-<profile>.yml`).

## Frequency & coverage (why this earned a skill)
- Occurrences: 9 `@CircuitBreaker` matches across 5 files, 2 modules — `partner-gateway`,
  `fulfilment-gateway` (as of `abc1234`).

## Drift / exceptions
- **Fallback behavior follows integration criticality**: this non-critical enrichment lookup
  degrades to an empty list. Critical dependencies should surface failure rather than silently
  returning an empty result.

## Provenance
- Scanned at: `abc1234` · tool/query: `rg '@CircuitBreaker' --glob '*.java'`
