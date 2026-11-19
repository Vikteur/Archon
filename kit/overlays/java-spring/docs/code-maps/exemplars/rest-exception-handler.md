---
runtime: lazy
source: application/src/main/java/com/acme/shop/exceptionhandling/RestExceptionHandler.java
serves: [exception-to-http]
kind: worked-example
---

<!-- AI_DISCLAIMER v1.0 -->
# Exemplar — `application/.../exceptionhandling/RestExceptionHandler.java` (project: `shop-backend`)

> This file has been created (totally or partially) with the assistance of artificial intelligence tools.
> All content has been generated under the direct supervision of a named individual,
> and under the AI.Backbone Orchestrator Compliance framework

## What this artifact is
The single central `@RestControllerAdvice` class of global `@ExceptionHandler` methods in the `application` module
that all capability adapters' controllers fall back to (there is a second, narrower one — `RestResponseEntityExceptionHandler` in
the same package — plus one capability-local advice class in `vendor-relation-adapter`).

## Domain exception → HTTP status mapping {#exception-to-http}
**Serves:** [`exception-to-http`](../exception-to-http.md)

One `@ExceptionHandler` method per exception type, each returning
`ResponseEntity<Map<String, List<String>>>` with body shape `{"errors": [...]}` and an explicit
`HttpStatus` — domain exceptions (`ConsentTransitionException`, `InvoiceCollectionAlreadyExistsException`) map to
`409`, authorization failures (Spring Security's `AccessDeniedException`) map to `403`, framework exceptions
(`HttpMessageNotReadableException`, which wraps Jackson's errors, and `MethodArgumentTypeMismatchException`) map to
`400`, `RequestNotPermitted` (Resilience4j `@RateLimiter`) maps to `429`, and a controller's `NotificationException`
maps to `400` with the generated `NotificationDTO`. The catch-all `Exception` handler returns an `ErrorResponse`'s own
status, headers and body unchanged (`ResponseStatusException`, `NoResourceFoundException`, Spring MVC's validation
exceptions) and otherwise returns `500`. `MethodArgumentNotValidException` deliberately has no handler here — it is
an `ErrorResponse`, so the catch-all passes Spring's own `ProblemDetail` validation-error body through as-is.

### Source (pseudonymized)
```java
package com.acme.shop.exceptionhandling;

import com.acme.shop.api.model.NotificationDTO;
import com.acme.shop.common.adapter.controller.NotificationException;
import com.acme.shop.consent.domain.ConsentTransitionException;
import com.acme.shop.consent.domain.ConsentTypeUnavailableException;
import com.acme.shop.invoice.adapter.exception.InvoiceException;
import com.acme.shop.invoice.adapter.exception.InvoiceForbiddenException;
import com.acme.shop.invoice.domain.collection.InvoiceCollectionAlreadyExistsException;
import com.acme.shop.invoice.domain.collection.InvoiceCollectionNotFoundException;
import com.acme.shop.partner.exception.PartnerBadRequestException;
import io.github.resilience4j.ratelimiter.RequestNotPermitted;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.http.converter.HttpMessageNotReadableException;
import org.springframework.security.access.AccessDeniedException;
import org.springframework.web.ErrorResponse;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.RestControllerAdvice;
import org.springframework.web.method.annotation.MethodArgumentTypeMismatchException;

import java.util.List;
import java.util.Map;

@RestControllerAdvice
public class RestExceptionHandler {

    private static final Logger LOGGER = LoggerFactory.getLogger(RestExceptionHandler.class);

    @ExceptionHandler(HttpMessageNotReadableException.class)
    public ResponseEntity<Map<String, List<String>>> handleMessageNotReadable(final HttpMessageNotReadableException ex) {
        LOGGER.warn("A message not readable exception occurred", ex);
        return ResponseEntity.status(HttpStatus.BAD_REQUEST).body(Map.of("errors", List.of("Request body could not be read")));
    }

    @ExceptionHandler(MethodArgumentTypeMismatchException.class)
    public ResponseEntity<Map<String, List<String>>> handleBadRequest(final MethodArgumentTypeMismatchException ex) {
        return ResponseEntity.status(HttpStatus.BAD_REQUEST).body(Map.of("errors", List.of("Request parameter does not match required type")));
    }

    @ExceptionHandler(RequestNotPermitted.class)
    public ResponseEntity<Map<String, List<String>>> handleRateLimit(final RequestNotPermitted ex) {
        LOGGER.warn("A rate limit exception occurred", ex);
        return ResponseEntity.status(HttpStatus.TOO_MANY_REQUESTS).body(Map.of("errors", List.of("Rate limit exceeded, please try again later")));
    }

    @ExceptionHandler(AccessDeniedException.class)
    public ResponseEntity<Map<String, List<String>>> handleForbiddenException(final AccessDeniedException ex) {
        LOGGER.warn("An authorization exception occurred", ex);
        if (ex.getMessage() == null || ex.getMessage().contains("Access Denied")) {
            return ResponseEntity.status(HttpStatus.FORBIDDEN).body(Map.of("errors", List.of("Access Denied")));
        }
        return ResponseEntity.status(HttpStatus.FORBIDDEN).body(Map.of("errors", List.of(ex.getMessage())));
    }

    @ExceptionHandler(NotificationException.class)
    public ResponseEntity<NotificationDTO> handleNotification(final NotificationException ex) {
        return ResponseEntity.status(HttpStatus.BAD_REQUEST).body(NotificationDTO.builder().errors(ex.getErrors()).build());
    }

    @ExceptionHandler(PartnerBadRequestException.class)
    public ResponseEntity<Map<String, List<String>>> handlePartnerBadRequest(final PartnerBadRequestException ex) {
        LOGGER.warn("Partner platform returned bad request", ex);
        return ResponseEntity.status(HttpStatus.BAD_REQUEST).body(Map.of("errors", List.of("Partner platform returned bad request")));
    }

    @ExceptionHandler(ConsentTransitionException.class)
    public ResponseEntity<Map<String, List<String>>> handleConsentTransition(final ConsentTransitionException ex) {
        LOGGER.warn("A consent transition exception occurred", ex);
        return ResponseEntity.status(HttpStatus.CONFLICT).body(Map.of("errors", List.of(ex.getMessage())));
    }

    @ExceptionHandler(ConsentTypeUnavailableException.class)
    public ResponseEntity<Map<String, List<String>>> handleConsentTypeUnavailable(final ConsentTypeUnavailableException ex) {
        LOGGER.warn("A consent type unavailable exception occurred", ex);
        return ResponseEntity.status(HttpStatus.NOT_FOUND).body(Map.of("errors", List.of(ex.getMessage())));
    }

    @ExceptionHandler(InvoiceException.class)
    public ResponseEntity<Map<String, List<String>>> handleInvoiceException(final InvoiceException ex) {
        LOGGER.warn("An invoice exception occurred", ex);
        return ResponseEntity.status(HttpStatus.BAD_REQUEST).body(Map.of("errors", List.of(ex.getMessage())));
    }

    @ExceptionHandler(InvoiceForbiddenException.class)
    public ResponseEntity<Map<String, List<String>>> handleInvoiceForbiddenException(final InvoiceForbiddenException ex) {
        LOGGER.warn("An invoice forbidden exception occurred", ex);
        return ResponseEntity.status(HttpStatus.FORBIDDEN).body(Map.of("errors", List.of(ex.getMessage())));
    }

    @ExceptionHandler(InvoiceCollectionNotFoundException.class)
    public ResponseEntity<Map<String, List<String>>> handleInvoiceCollectionNotFoundException(final InvoiceCollectionNotFoundException ex) {
        LOGGER.warn("An invoice collection not found exception occurred", ex);
        return ResponseEntity.status(HttpStatus.NOT_FOUND).body(Map.of("errors", List.of(ex.getMessage())));
    }

    @ExceptionHandler(InvoiceCollectionAlreadyExistsException.class)
    public ResponseEntity<Map<String, List<String>>> handleInvoiceCollectionAlreadyExistsException(final InvoiceCollectionAlreadyExistsException ex) {
        LOGGER.warn("An invoice collection already exists exception occurred", ex);
        return ResponseEntity.status(HttpStatus.CONFLICT).body(Map.of("errors", List.of(ex.getMessage())));
    }

    @ExceptionHandler(Exception.class)
    public ResponseEntity<Object> handleDefault(final Exception ex) {
        if (ex instanceof ErrorResponse errorResponse) {
            LOGGER.error("An exception occurred", ex);
            return ResponseEntity.status(errorResponse.getStatusCode())
                    .headers(errorResponse.getHeaders()).body(errorResponse.getBody());
        }
        LOGGER.error("An unknown exception occurred", ex);
        return ResponseEntity.status(HttpStatus.INTERNAL_SERVER_ERROR)
                .body(Map.of("errors", List.of("An unknown exception occurred")));
    }
}
```

### Edge cases
Framework validation exception:
```java
mockMvc.perform(post("/api/delegation").contentType(APPLICATION_JSON).content("{\"customerName\": \"\"}"))
        .andExpect(status().isBadRequest())
        .andExpect(jsonPath("$.detail").value("Invalid request content."));
```
Expected: `MethodArgumentNotValidException` has no handler in this class, so the catch-all keeps Spring's built-in `ProblemDetail` validation response shape.

Partner request rejected upstream:
```java
var response = handler.handlePartnerBadRequest(new PartnerBadRequestException("example.invalid rejected the payload"));
assertThat(response.getStatusCode().value()).isEqualTo(400);
```
Expected: callers receive a normalized partner-platform error body, not the raw upstream payload.

Exception that is an `ErrorResponse` carrying its own status:
```java
var response = handler.handleDefault(new ResponseStatusException(HttpStatus.NOT_FOUND));
assertThat(response.getStatusCode().value()).isEqualTo(404);
```
Expected: the catch-all keeps the exception's own status instead of turning it into a `500`.

## Provenance
- Scanned at: `abc1234` · tool/query: `rg -l '@RestControllerAdvice'` (3 files / 2 modules), `rg '@ExceptionHandler'` (12 matches / 3 files)
