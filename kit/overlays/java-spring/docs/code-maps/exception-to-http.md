---
runtime: lazy
kind: worked-example
---

<!-- AI_DISCLAIMER v1.0 -->
# Code map — `exception-to-http` (project: `shop-backend`)

> This file has been created (totally or partially) with the assistance of artificial intelligence tools.
> All content has been generated under the direct supervision of a named individual,
> and under the AI.Backbone Orchestrator Compliance framework

## This repo (<project>)
These are the real facts. Everything from "Where this pattern lives" down is the pseudonymized worked example
(`shop-backend`): follow its structure, not its names.

- **A use case returns a `Notification`** (see [validation-notification-result]); the controller calls
  `NotificationResponses.throwOnErrors(notification)` from `<base-package>.common.adapter.controller`. A sealed
  `<Project>Exception` (`<base-package>.common.domain.error`) with `NotFoundException`, `RejectedException`,
  `NotPermittedException` and `UpstreamUnavailableException` is the only type a domain/usecase throwable may have
  (an ArchUnit rule).
- **A persistence failure crosses the port only as the mapped domain refusal or `PersistenceFailedException`** (500 by
  the catch-all): `ConstraintRefusals` in `<base-package>.common.adapter.repository` translates Spring's
  `DataIntegrityViolationException` inside the port call. A violation raised at commit is answered by the catch-all.
- **One advice class answers every refusal:** `ErrorMappers` (`@RestControllerAdvice`) in
  `<base-package>.common.adapter.controller` (module `shared-adapter`), one `@ExceptionHandler` method per type:
  `<Project>Exception` (status from `ErrorStatusTable`, its code), Spring Security's `AuthenticationException` (401
  `NOT_SIGNED_IN`), `AccessDeniedException` (403 `FORBIDDEN`), `MethodArgumentNotValidException` and
  `HandlerMethodValidationException` (a request violation answers 422 `VALIDATION_FAILED`, one distinct
  `<full path> <message>` string per violation, built by `ViolationPaths`), `ConstraintViolationException` (not about
  the request: the logged 500), `HttpMessageNotReadableException` whose cause is a `MismatchedInputException` (422, the
  field path and what format it expects, never the sent value), `ErrorResponse` and the `Exception` catch-all.
  A `@PreAuthorize` denial raises `AccessDeniedException` inside the handler call and reaches the advice; a denial in
  the filter chain (`authorizeHttpRequests`) never does: the `AccessDeniedHandler`/`AuthenticationEntryPoint` of the
  `SecurityFilterChain` answer it. An `ErrorResponse` (`ResponseStatusException`, `ErrorResponseException`,
  `NoResourceFoundException`) at 400-499 keeps its status and headers, with the code of 401/403/404/429 and none
  otherwise; 500 and up is the catch-all. The catch-all answers 500 without a code and logs once at ERROR with
  `RedactedCause` (class names and frames, no messages; `NoSecretInLogsTest` shows a thrown's message, an address and a
  token reach neither that line nor its stack trace), and `server.error.include-stacktrace=never` covers what
  reaches Spring Boot's `/error`. `ErrorBody` is the one builder of the body.
- **`ValidationFailedException`** (a `RejectedException` a use case throws after it evaluated every rule) answers 422
  `VALIDATION_FAILED` with one string per violation, in rule order and unsorted: `<property> <message>`, or the message
  alone for a rule that names no property. The request-violation path above keeps its own sort.
- **`ThrottledException`** (a `RejectedException`, the `ValidationFailedException` subclass precedent: `permits` stays
  unchanged) answers 429 `TOO_MANY_REQUESTS` with the fixed text and a `Retry-After` header of whole seconds (at least 1),
  set with `ResponseEntity.status(429).header(HttpHeaders.RETRY_AFTER, ...)`.
- **Unknown routes** (`/api/no-such-route`) answer 404 `NOT_FOUND` through the same advice (Spring Boot 3.2+ raises
  `NoResourceFoundException`). A body Jackson cannot read answers 422: a type mismatch or missing property names its
  field path and the expected format (`BodyMismatch`), broken JSON answers "the request body is not valid JSON";
  neither echoes the sent value. `StrictJsonTypes` (`application/config`, a `Jackson2ObjectMapperBuilderCustomizer`
  setting `coercionConfigDefaults()` and `MapperFeature.ALLOW_COERCION_OF_SCALARS` off) makes Jackson refuse a scalar
  of the wrong JSON type instead of coercing it: a string for a number or a boolean, a number for a string, a boolean,
  an enum or a date, and `""` for a number, a boolean or a date. jackson-datatype-jsr310 still reads a date-time sent
  as a number and a date sent as an array of numbers. The customizer changes the one auto-configured `ObjectMapper`,
  so a `RestClient` built from the auto-configured `RestClient.Builder` refuses the same coercions on upstream JSON.
- **`ErrorStatusTable` is the only code-to-status mapping**, one row per `ErrorCode` (every error code of the
  contract). An error without a code answers 422 `VALIDATION_FAILED`.
- **Body:** `{"errors":[...],"code":...}`.
- **Body over the size limit:** `MaxUploadSizeExceededException` answers 413 without a body at the explicit 10240KB
  limit (see [api-first-controller]); `FILE_TOO_LARGE` is its code in the contract.

## Where this pattern lives (exemplars)
| Exemplar | What it shows | Layer / module |
|----------|---------------|----------------|
| [`RestExceptionHandler.java`](exemplars/rest-exception-handler.md#exception-to-http) | One central `@RestControllerAdvice` class, one `@ExceptionHandler` method per exception type, `{"errors": [...]}` body shape | application |

### Excerpts
Central translation to the repo-wide error body (full source in the [exemplar leaf](exemplars/rest-exception-handler.md#exception-to-http)):
```java
@ExceptionHandler(HttpMessageNotReadableException.class)
public ResponseEntity<Map<String, List<String>>> handleMessageNotReadable(final HttpMessageNotReadableException ex) {
    LOGGER.warn("A message not readable exception occurred", ex);
    return ResponseEntity.status(HttpStatus.BAD_REQUEST).body(Map.of("errors", List.of("Request body could not be read")));
}
```

Catch-all that preserves Spring's own status-carrying exceptions:
```java
@ExceptionHandler(Exception.class)
public ResponseEntity<Object> handleDefault(final Exception ex) {
    if (ex instanceof ErrorResponse errorResponse) {
        LOGGER.error("An exception occurred", ex);
        return ResponseEntity.status(errorResponse.getStatusCode())
                .headers(errorResponse.getHeaders()).body(errorResponse.getBody());
    }
```

### Edge cases
Framework validation exception:
```java
mockMvc.perform(post("/api/delegation").contentType(APPLICATION_JSON).content("{\"customerName\": \"\"}"))
        .andExpect(status().isBadRequest())
        .andExpect(jsonPath("$.detail").value("Invalid request content."));
```
Expected: `MethodArgumentNotValidException` has no handler of its own; it is an `ErrorResponse`, so the catch-all passes Spring's own `ProblemDetail` validation response through unchanged.

Authorization failure with the stock access-denied message:
```java
var response = handler.handleForbiddenException(new AccessDeniedException("Access Denied"));
assertThat(response.getStatusCode().value()).isEqualTo(403);
assertThat(response.getBody().get("errors")).containsExactly("Access Denied");
```
Expected: the handler returns the normalized stock message instead of echoing extra framework detail.

Exception that is an `ErrorResponse` carrying its own status:
```java
var response = handler.handleDefault(new ResponseStatusException(HttpStatus.NOT_FOUND));
assertThat(response.getStatusCode().value()).isEqualTo(404);
```
Expected: the advice gets out of the way and keeps the exception's declared HTTP status.

## Local conventions (the project facts the skill omits)
- Package root: `application/src/main/java/com/acme/shop/exceptionhandling/`.
- Naming shape: `RestExceptionHandler` (primary), a narrower
  `RestResponseEntityExceptionHandler` sibling in the same package, plus one capability-local
  `@RestControllerAdvice` class in `vendor-relation-adapter` for relation-specific exceptions.
- Required collaborators / base types: response body is always
  `ResponseEntity<Map<String, List<String>>>` with key `"errors"` — no `ProblemDetail`/RFC 9457
  shape of its own in this codebase (only Spring's passed-through `ErrorResponse` bodies carry one).
- Config / wiring: `@ExceptionHandler` methods on a `@RestControllerAdvice` class outside any controller —
  global, applies repo-wide; `server.error.include-stacktrace=never`.

## Frequency & coverage (why this earned a skill)
- Occurrences: 3 `@RestControllerAdvice` classes across 2 modules (`application`,
  `vendor-relation-adapter`); 12 `@ExceptionHandler` matches across those 3 files (as of
  `abc1234`).

## Drift / exceptions
- `MethodArgumentNotValidException` and `HandlerMethodValidationException` are deliberately not mapped to the
  `{"errors": [...]}` shape — Spring's own `ProblemDetail` validation-error response is kept. Not a gap;
  intentional.
- Spring asks the advice classes in `@Order` and the first one with any matching handler wins, so a catch-all in an
  earlier advice shadows a more specific handler in a later one. The narrower classes carry
  `@Order(Ordered.HIGHEST_PRECEDENCE)`; `RestExceptionHandler`, which holds the catch-all, stays last. Jackson's
  `MismatchedInputException` arrives wrapped in `HttpMessageNotReadableException`; inspect `ex.getMostSpecificCause()`
  if the `{"errors": [...]}` text should differ for that subtype.

## Provenance
- Scanned at: `abc1234` · tool/query: `rg -l '@RestControllerAdvice'`, `rg '@ExceptionHandler'` (both `--glob '*.java'`)

[validation-notification-result]: validation-notification-result.md
[api-first-controller]: api-first-controller.md
