---
runtime: lazy
kind: worked-example
---

<!-- AI_DISCLAIMER v1.0 -->
# Code map — `api-first-controller` (project: `shop-backend`)

> This file has been created (totally or partially) with the assistance of artificial intelligence tools.
> All content has been generated under the direct supervision of a named individual,
> and under the AI.Backbone Orchestrator Compliance framework

## This repo (<project>)
These are the real facts. Everything from "Where this pattern lives" down is the pseudonymized worked example
(`shop-backend`): follow its structure, not its names.

- **The `@RestController` implements the generated `<Tag>Api`** (`<base-package>.api`) in
  `<base-package>.<context>.adapter.controller`; it stays thin: get the organisation from `CurrentOrganisation`
  (shared-adapter), call the use case, `NotificationResponses.throwOnErrors(notification)`, map to the DTO.
- A non-200 success status is the generated `@ResponseStatus` on the `<Tag>Api` method (201 from the contract, 204
  for a `void` operation); the override never sets it. `skipDefaultInterface=true` makes every generated method
  abstract, so a shared helper answers 501 (`ResponseStatusException(HttpStatus.NOT_IMPLEMENTED)`) for an operation
  that is not built yet.
- A fixed `Cache-Control` is set in the implementing method with `CacheControl` on the injected current
  `HttpServletResponse`: `useResponseEntity=false` fixes the return type to the DTO, so no `ResponseEntity`, and
  Spring has no method annotation for a fixed response header.
- **Request body limit** is set explicitly (`spring.servlet.multipart.max-file-size` and `max-request-size`,
  `10240KB`), never left to the default.
- **Every implemented route outside the allow-list carries `@PreAuthorize`, `@Secured`, `@RolesAllowed`, `@PermitAll`
  or `@DenyAll`** (`@EnableMethodSecurity(jsr250Enabled = true)`) on the method or the class;
  `application/.../security/RouteGuardTest` refuses it otherwise.

## Where this pattern lives (exemplars)
| Exemplar | What it shows | Layer / module |
|----------|---------------|----------------|
| [`CustomerController.java`](exemplars/customer-controller.md#api-first-controller) | `implements <Capability>Api`, delegates to use-cases, maps via a static `*ToDTOMapper` | adapter (`account-adapter`) |

### Excerpts
Generated-contract controller (full source in the [exemplar leaf](exemplars/customer-controller.md#api-first-controller)):
```java
@RestController
public class CustomerController implements AccountApi {
    @Override
    public List<DelegationDTO> getAllDelegations() {
        response.setHeader(HttpHeaders.CACHE_CONTROL, CacheControl.maxAge(Duration.ofDays(1)).getHeaderValue());
        return getDelegationsUseCase.execute().stream()
                .map(DelegationToDTOMapper::map).toList();
```

Controller-owned route beside generated overrides:
```java
@GetMapping("/api/delegation/verify-topic-access/{topic}")
public Boolean verifyDelegationForTopic(@PathVariable("topic") Topic topic) {
    return verifyDelegationForTopicAccessUseCase.execute(topic);
}
```

### Edge cases
Generated override plus one manual route in the same controller:
```java
assertThat(CustomerController.class.getInterfaces()).contains(AccountApi.class);
assertThat(CustomerController.class.getDeclaredMethod("verifyDelegationForTopic", Topic.class)).isNotNull();
```
Expected: contract methods stay on the generated interface; controller-specific routes can coexist when the contract has not absorbed them yet.

Boundary mapping after a successful read:
```java
var dto = DelegationToDTOMapper.map(delegation);
assertThat(dto.getCustomerName()).isEqualTo("Jane Doe");
```
Expected: the controller maps domain output through a dedicated mapper instead of constructing DTOs inline.

Use-case validation failure on a write endpoint:
```java
when(recordLastCustomerVisitUseCase.execute()).thenReturn(Notification.builder()
        .error("Could not record Springfield storefront visit").build());
mockMvc.perform(post("/api/customer/last-visit"))
        .andExpect(status().isBadRequest())
        .andExpect(jsonPath("$.errors", hasItem("Could not record Springfield storefront visit")));
```
Expected: write endpoints translate the returned notification into an HTTP response without leaking domain internals.

## Scaffold
Render the base case with `scripts/scaffold.sh <template> '<json on one line>' <target>` from the repo root. The
template's header comment lists its exact variables; the script refuses to overwrite an existing file.

| Template | Target | Variables | Left to you |
|---|---|---|---|
| [adapter/controller](../scaffold-templates/adapter/controller.mustache) | `<capability>-adapter/src/main/java/<pkg>/adapter/controller/<Name>Controller.java` | `package` (base package, without `.adapter.controller`), `basePackage`, `Name`, `Api`, `apiPackage`, `modelPackage`, `UseCase`, `useCase`, `operationId`, `Domain` (all from the contract's tag and operation); the organisation comes from `CurrentOrganisation` | path/query parameters and request bodies; non-200 responses; more operations on the same `Api`; list results; authorization (a STOP item) |
| [adapter/controller-command](../scaffold-templates/adapter/controller-command.mustache) | `.../adapter/controller/<Name>Controller.java` | `package` (base package, without `.adapter.controller`), `basePackage`, `Name`, `Api`, `apiPackage`, `modelPackage`, `Domain`, `Dto`, `dto`, `upsertOperationId`, `deleteOperationId`, `key`, `pathKeyType`, `typedId` (the domain id type wrapping the path UUID) (all from the contract's tag and operations); errors go through `NotificationResponses.throwOnErrors` | success statuses other than 204; more operations on the same `Api`; authorization (a STOP item) |

The mapper it calls comes from `domain-dto-mapper`; its test from `jvm-testing` (controller-test).

A write operation pair (create-or-update and delete by key) uses controller-command instead. It calls the use cases
from `usecase-orchestration` (usecase-create-or-update, usecase-delete), maps the body with request-dto-to-domain-mapper
(`domain-dto-mapper`) and is tested by controller-command-test (`jvm-testing`).

## Local conventions (the project facts the skill omits)
- Package root: `<capability>-adapter/src/main/java/com/acme/shop/<capability>/adapter/controller/`.
- Naming shape: `*Controller`, `@RestController`, `implements <Capability>Api` (the Spring MVC interface generated
  by openapi-generator `spring`, `interfaceOnly=true`, `skipDefaultInterface=true`, `useResponseEntity=false`,
  `useTags=true`, `useBeanValidation=true`, `modelNameSuffix=DTO`, from `shop.openapi-conventions.gradle.kts`).
  Methods return what the interface declares (the DTO, or `void`); the success status is the generated
  `@ResponseStatus`, a fixed `Cache-Control` is `CacheControl` on the injected response, and a non-200 status with an
  error body is a thrown `NotificationException` that the central `@RestControllerAdvice` answers.
- Required collaborators: one `*UseCase` per endpoint, constructor-injected; a static
  `*ToDTOMapper` for the domain→DTO step (never inline DTO construction).
- Config / wiring: a `@RestController` singleton found by component scan; the `@RequestMapping`/`@PathVariable`/
  `@RequestBody`/`@Valid` annotations live on the generated Api interface and are not re-declared on the overrides.
  Lombok `@RequiredArgsConstructor` for constructor injection.

## Frequency & coverage (why this earned a skill)
- Occurrences: 33 files across 14 modules (as of `abc1234`).
- Hotspots: every capability adapter with a REST surface (`access-matrix-adapter`,
  `product-restriction-adapter`, `application`, `authentication-adapter`, `promotion-adapter`,
  `payments-gateway`, `storefront-adapter`, `partner-gateway`, `merchant-adapter`,
  `campaign-adapter`, `account-adapter`, `attribute-mapping-adapter`, `invoice-adapter`,
  `order-adapter`).

## Drift / exceptions
- Not every controller method is a generated-interface override — a controller may add a
  hand-annotated `@GetMapping` route alongside the generated ones (see `CustomerController.verifyDelegationForTopic`)
  when the OpenAPI contract does not yet cover that endpoint. Treat as intentional, not drift.

## Provenance
- Scanned at: `abc1234` · tool/query: `scripts/scan-patterns.sh --glob '*.java' 'Controller implements [A-Za-z]+Api'`
