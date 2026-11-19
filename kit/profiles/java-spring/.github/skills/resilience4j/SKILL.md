---
name: resilience4j
description: Resilience4j timeouts, retries, circuit breakers and fallbacks on outbound calls. Use for any gateway or remote call.
---
# Fault tolerance — timeouts, retries, circuit breakers, fallbacks

## When to use
Adding fault tolerance to an outbound call (HTTP/SOAP/FHIR client) so a slow or failing dependency
degrades gracefully instead of cascading: timeout, retry, circuit breaker, fallback.

## How
- Annotate the gateway method with the Resilience4j annotations (`resilience4j-spring-boot3` plus
  `spring-boot-starter-aop`): `@TimeLimiter`, `@Retry`, `@CircuitBreaker(name = "<instance>",
  fallbackMethod = "<fallback>")`. The fallback shares the method signature plus a trailing
  exception parameter. A time limiter needs an async return type; for a blocking client, set the
  client's own connect/read timeouts instead.
- Configure each named instance per gateway (failure rate threshold, sliding window, minimum number
  of calls, wait duration in open state, retry attempts and wait). One instance per dependency, not one global.
- Override values per environment through configuration properties
  (`resilience4j.circuitbreaker.instances.<instance>.wait-duration-in-open-state`), not by editing code.
- Make the fallback meaningful: a cached/empty/typed-degraded result, or a domain exception that maps
  to a clear HTTP status — never swallow the error silently.
- Expose the breaker state through the actuator health and metrics endpoints
  (`register-health-indicator: true`); keep those endpoints authenticated.

## Pattern signals (discovery cues)
`resilience4j-spring-boot3` on the classpath; `@TimeLimiter` / `@Retry` / `@CircuitBreaker` /
`@Bulkhead` annotations on gateway/client classes; `fallbackMethod = ` references;
`resilience4j.*.instances.*` keys in the configuration.

## Project specifics → see docs
- Code map (configured instances, thresholds, fallbacks, exemplars) → `docs/code-maps/resilience4j.md` *(per-repo map; if marked `kind: worked-example`, follow its structure and map its pseudonymized names to this repo's own)*

## Guardrails (what NOT to do)
- Don't share one breaker configuration across unrelated dependencies — tune per integration.
- Don't let a fallback hide a bug: log it, and don't return success-shaped data for a hard failure.
- Don't put a circuit breaker on a fast in-process call — it's for remote/IO boundaries.
- Don't call the annotated method from inside its own class — the proxy is bypassed and nothing applies.

## Definition of done
- [ ] Each outbound dependency has its own timeout, retry and breaker instance + a typed fallback; thresholds configured; health
  exposed; a test proves the fallback path fires when the breaker is open.
