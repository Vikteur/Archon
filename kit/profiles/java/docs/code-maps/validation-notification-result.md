---
runtime: lazy
kind: worked-example
---

<!-- AI_DISCLAIMER v1.0 -->
# Code map — `validation-notification-result` (project: `shop-backend`)

> This file has been created (totally or partially) with the assistance of artificial intelligence tools.
> All content has been generated under the direct supervision of a named individual,
> and under the AI.Backbone Orchestrator Compliance framework

## This repo (wedding-portal)
These are the real facts. Everything from "Where this pattern lives" down is the pseudonymized worked example
(`shop-backend`): follow its structure, not its names. Decisions: [memory, 2026-10-17].

- **Every use case returns a `Notification`**, also for not found and forbidden. Each error carries an `ErrorCode`
  enum value: the 44 codes of rekord-contract v6.1.3, nothing else. An error without a code counts as 422
  `VALIDATION_FAILED`.
- **`Creation<T>`** is the factory result: `Creation.of(value, notification)`, `Creation.of(value)` and
  `Creation.empty(notification)`.
- **Validators** in `app.rekord.common.domain.validation`: `ObjectValidator` and `StringValidator` append
  `"<field> is required"` to the notification.
- **`addViolation(property, message)`** declares the request property a rule broke. The error string is the path, a
  space and the message (`displayName is reserved`, `lines[2].name is a duplicate`); the path is lower camel case with
  list indexes, anything else is an `IllegalArgumentException`. A rule that checks no single property keeps calling
  `addError(message)`: the message stands alone. A use case that refuses on rules evaluates every rule, then throws
  `ValidationFailedException` (a `RejectedException`) once, with the errors in rule order.
- Shared domain code lives in `app.rekord.common.domain(.validation)`; the HTTP side of a notification is
  [exception-to-http].

## Where this pattern lives (exemplars)
| Exemplar | What it shows | Layer / module |
|----------|---------------|----------------|
| [`Notification.java`](exemplars/notification.md#validation-notification-result) | The collector itself: errors + warnings, `hasErrors()`, joined messages, `empty()` / `of()` / `merge()` / `addNotification()` composition | domain (`common-domain`) |

### Excerpts
Collector factories + composition helpers:
```java
public static Notification of(String error) {
    var notification = empty();
    notification.addError(error);
    return notification;
}

public Notification addNotification(Notification notification) {
    if (notification == null) {
        return this;
    }

    errors.addAll(notification.getErrors());
    warnings.addAll(notification.getWarnings());
    return this;
}
```

### Edge cases
Merging siblings keeps errors but not warnings:
```java
var left = Notification.of("Page.title is required");
var right = Notification.empty();
right.addWarning("Page.slug will be normalized");

var merged = Notification.merge(left, right);
```
Expected: `merged.getErrors()` contains both error lists; warning lists do not flow through `merge(...)`.

Adding a `null` child notification:
```java
var parent = Notification.empty();
parent.addNotification(null);
```
Expected: no exception and no state change.

## Local conventions (the project facts the skill omits)
- The result type is `com.acme.shop.common.domain.validation.Notification` (`common-domain`) — one shared
  class for the whole repo, never per-capability copies.
- Field rules go through validator helpers with the signature convention
  `StringValidator.notBlank("Type.field", value, notification)` — helpers append into the caller's
  accumulator rather than returning their own; one accumulator per validation pass.
- Entities expose `validate()` returning `Notification`; composite validations combine child
  results via `addNotification(...)` or `merge(...)`.
- Creation flows validate before constructing.
- `merge(...)` propagates errors only; `addNotification(...)` propagates both errors and warnings.

## Frequency & coverage (why this earned a skill)
- Occurrences: 179 files across 32 modules import the type (as of `abc1234`) — one of the widest-spread
  shared patterns in the backend.

## Drift / exceptions
- Warning propagation differs by helper: `merge(...)` ignores warnings while `addNotification(...)`
  copies them. Callers pick the helper that matches the intent.

## Provenance
- Scanned at: `abc1234` · tool/query: `grep -rl 'common.domain.validation.Notification' --include='*.java'`

[memory, 2026-10-17]: ../memory.md
[exception-to-http]: exception-to-http.md
