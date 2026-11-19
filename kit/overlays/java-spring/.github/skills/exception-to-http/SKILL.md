---
name: exception-to-http
description: Map a domain exception hierarchy to HTTP status via one @RestControllerAdvice. Use when surfacing REST errors.
---
# Exception-to-HTTP mapping

## When to use
Turning typed domain/gateway exceptions into consistent HTTP responses (status + error body) without
try/catch scattered through controllers.

## How
- Define a small exception hierarchy (not-found, validation/conflict, upstream-unavailable, forbidden);
  throw the typed exception from the inner layers — controllers don't catch.
- Centralize translation in one `@RestControllerAdvice` class of `@ExceptionHandler` methods; each
  method maps an exception (family) to a `ResponseEntity` with a status + a uniform error body. Map
  the **base** types, with overrides for specifics. Don't scatter `@ExceptionHandler` methods across
  controllers or add several advice classes.
- Keep the error body shape consistent (code, message, optional details; `ProblemDetail` if the
  contract uses RFC 9457); never leak stack traces or internal identifiers
  (`server.error.include-stacktrace=never`).
- Default unmapped exceptions to 500 with a generic body, and log the detail server-side only.

## Pattern signals (discovery cues)
A `@RestControllerAdvice` class with `@ExceptionHandler` methods (or a `ResponseEntityExceptionHandler`
subclass); a domain exception base class hierarchy; `ResponseEntity` / `ProblemDetail` error bodies.

## Project specifics → see docs
- Code map (the exception hierarchy → status table, mapper exemplar) → `docs/code-maps/exception-to-http.md` *(per-repo map; if marked `kind: worked-example`, follow its structure and map its pseudonymized names to this repo's own)*

## Guardrails (what NOT to do)
- Don't catch exceptions in controllers — let the advice handle them.
- Don't leak stack traces, internal ids, or upstream messages to clients.
- Don't return 200 with an error payload — use the right status.

## Definition of done
- [ ] Typed exceptions thrown inward; one central advice class maps families → status + uniform body; unmapped → 500 logged server-side; a test asserts the mapping.
