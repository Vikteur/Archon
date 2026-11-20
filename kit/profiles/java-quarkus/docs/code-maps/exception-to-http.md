---
runtime: lazy
kind: worked-example
---

<!-- AI_DISCLAIMER v1.0 -->
# Code map — `exception-to-http` (project: `shop-backend`)

> This file has been created (totally or partially) with the assistance of artificial intelligence tools.
> All content has been generated under the direct supervision of a named individual,
> and under the AI.Backbone Orchestrator Compliance framework

## This repo (the Quarkus original)
These are the real facts. Everything from "Where this pattern lives" down is the pseudonymized worked example
(`shop-backend`): follow its structure, not its names. Decisions: [memory, 2026-10-17].

- **A use case returns a `Notification`** (see [validation-notification-result]); the controller calls
  `NotificationResponses.throwOnErrors(notification)` from `app.rekord.common.adapter.controller`. The sealed
  `RekordException` (`app.rekord.common.domain.error`) with `NotFoundException`, `RejectedException`,
  `NotPermittedException` and `UpstreamUnavailableException` is the only type a domain/usecase throwable may have
  (rule A13).
- **A persistence failure crosses the port only as the mapped domain refusal or `PersistenceFailedException`** (500 by
  the catch-all): `ConstraintRefusals` in `app.rekord.common.adapter.repository` translates inside the port call. A
  violation raised at commit is answered by the catch-all.
- **One mapper class answers every refusal:** `ErrorMappers` in `app.rekord.common.adapter.controller` (module
  `shared-adapter`), one `@ServerExceptionMapper` method per type: `RekordException` (status from `ErrorStatusTable`,
  its code), `AuthenticationFailedException` and `UnauthorizedException` (401 `NOT_SIGNED_IN`), the JAX-RS
  `ForbiddenException` (403 `FORBIDDEN`), `ConstraintViolationException` (a request violation answers 422
  `VALIDATION_FAILED`, one distinct `<full path> <message>` string per violation, built by `ViolationPaths`; any other
  one is the logged 500), `MismatchedInputException` (422, the field path and what format it expects, never the sent
  value), `WebApplicationException` and the `Throwable` catch-all.
  `io.quarkus.security.ForbiddenException` (a `@RolesAllowed` denial) has no mapper in phase 0: Quarkus' built-in
  mapper answers 403 with no body, as rekord-api does (TASK-6.2, fixture
  `application/src/test/resources/fixtures/role-denied-403.json`); P1-E09-T01 adds the notification-body mapper
  (UD-19.i4, RISK-18). A
  `WebApplicationException` with a body or a status below 400 passes through (`SuccessStatus`, `NotificationResponses`);
  400-499 without a body keeps its status and headers, with the code of 401/403/404/429 and none otherwise; 500 and up is
  the catch-all. The catch-all answers 500 without a code and logs once at ERROR with `RedactedCause` (class names and
  frames, no messages; `NoSecretInLogsTest` shows a thrown's message, an address and a token, reaches neither that line nor its stack trace). `ErrorBody` is the one builder of the body.
- **`ValidationFailedException`** (a `RejectedException` a use case throws after it evaluated every rule) answers 422
  `VALIDATION_FAILED` with one string per violation, in rule order and unsorted: `<property> <message>`, or the message
  alone for a rule that names no property. The request-violation path above keeps its own sort.
- **`ThrottledException`** (a `RejectedException`, the `ValidationFailedException` subclass precedent: `permits` stays
  unchanged) answers 429 `TOO_MANY_REQUESTS` with the fixed text and a `Retry-After` header of whole seconds (at least 1).
- **Unknown routes** (`/api/no-such-route`, `/api/q/metrics`) answer 404 `NOT_FOUND` through the same mapper. A body
  Jackson cannot read answers 422: a type mismatch or missing property names its field path and the expected format
  (`BodyMismatch`), broken JSON answers "the request body is not valid JSON"; neither echoes the sent value. A
  `ConstraintViolationException` that is not about the request (method, return value, commit) answers the logged 500.
  `StrictJsonTypes` (`application/config`) makes Jackson refuse a scalar of the wrong JSON type instead of coercing it:
  a string for a number or a boolean, a number for a string, a boolean, an enum or a date, and `""` for a number, a
  boolean or a date (TASK-5.6). jackson-datatype-jsr310 still reads a date-time sent as a number and a date sent as an
  array of numbers. The customizer changes the one shared `ObjectMapper`, so a REST client reading upstream JSON
  refuses the same coercions.
- **`ErrorStatusTable` is the only code-to-status mapping**, one row per `ErrorCode` (the 44 codes of rekord-contract
  v6.1.3). An error without a code answers 422 `VALIDATION_FAILED`.
- **Body:** `{"errors":[...],"code":...}`.
- **Body over the size limit:** 413 without a body at the explicit 10240K limit (see [api-first-controller]);
  `FILE_TOO_LARGE` is its code in the contract.

## Where this pattern lives (exemplars)
| Exemplar | What it shows | Layer / module |
|----------|---------------|----------------|
| [`RestExceptionHandler.java`](exemplars/rest-exception-handler.md#exception-to-http) | One central class, one `@ServerExceptionMapper` method per exception type, `{"errors": [...]}` body shape | application |

### Excerpts
Central translation to the repo-wide error body (full source in the [exemplar leaf](exemplars/rest-exception-handler.md#exception-to-http)):
```java
@ServerExceptionMapper
public RestResponse<Map<String, List<String>>> handleJsonProcessing(final JsonProcessingException ex) {
    LOGGER.warn("A message not readable exception occurred", ex);
    return RestResponse.status(Status.BAD_REQUEST, Map.of("errors", List.of("Request body could not be read")));
}
```

Catch-all that preserves explicit Quarkus semantics:
```java
@ServerExceptionMapper
public Response handleDefault(final Exception ex) {
    if (ex instanceof WebApplicationException wae) {
        LOGGER.error("An exception occurred", ex);
        return wae.getResponse();
    }
```

### Edge cases
Framework validation exception:
```java
given().contentType(JSON).body("{\"customerName\": \"\"}")
        .when().post("api/delegation")
        .then().statusCode(400).body("violations", notNullValue());
```
Expected: `ConstraintViolationException` is left to Quarkus's own mapper so its validation-error response format is kept.

Authorization failure with the stock access-denied message:
```java
var response = handler.handleForbiddenException(new ForbiddenException("Access Denied"));
assertThat(response.getStatus()).isEqualTo(403);
assertThat(response.getEntity().get("errors")).containsExactly("Access Denied");
```
Expected: the handler returns the normalized stock message instead of echoing extra framework detail.

Exception that is a `WebApplicationException` carrying its own status:
```java
var response = handler.handleDefault(new NotFoundException());
assertThat(response.getStatus()).isEqualTo(404);
```
Expected: the mapper gets out of the way and keeps the exception's declared HTTP status.

## Local conventions (the project facts the skill omits)
- Package root: `application/src/main/java/com/acme/shop/exceptionhandling/`.
- Naming shape: `RestExceptionHandler` (primary), a narrower
  `RestResponseEntityExceptionHandler` sibling in the same package, plus one capability-local
  `@ServerExceptionMapper` class in `vendor-relation-adapter` for relation-specific exceptions.
- Required collaborators / base types: response body is always
  `RestResponse<Map<String, List<String>>>` with key `"errors"` — no problem-details/RFC-7807
  shape in this codebase.
- Config / wiring: `@ServerExceptionMapper` methods on a plain class outside any resource class —
  global, applies repo-wide.

## Frequency & coverage (why this earned a skill)
- Occurrences: 3 `@ServerExceptionMapper` classes across 2 modules (`application`,
  `vendor-relation-adapter`); 11 `@ServerExceptionMapper` matches across those 3 files (as of
  `abc1234`).

## Drift / exceptions
- `jakarta.validation.ConstraintViolationException` is deliberately not mapped to the
  `{"errors": [...]}` shape — Quarkus's own validation-error response format is kept. Not a gap;
  intentional.
- Quarkus ships a built-in mapper for Jackson's `MismatchedInputException`, which beats the
  `JsonProcessingException` mapper for that subtype; disable it with
  `quarkus.rest.exception-mapping.disable-mapper-for` if the `{"errors": [...]}` shape is wanted there too.

## Provenance
- Scanned at: `abc1234` · tool/query: `rg -l '@ServerExceptionMapper'`, `rg '@ServerExceptionMapper'` (both `--glob '*.java'`)

[memory, 2026-10-17]: ../memory.md
[validation-notification-result]: validation-notification-result.md
[api-first-controller]: api-first-controller.md
