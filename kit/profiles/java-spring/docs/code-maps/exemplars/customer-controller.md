---
runtime: lazy
source: account-adapter/src/main/java/com/acme/shop/account/adapter/controller/CustomerController.java
serves: [api-first-controller]
kind: worked-example
---

<!-- AI_DISCLAIMER v1.0 -->
# Exemplar — `account-adapter/.../controller/CustomerController.java` (project: `shop-backend`)

> This file has been created (totally or partially) with the assistance of artificial intelligence tools.
> All content has been generated under the direct supervision of a named individual,
> and under the AI.Backbone Orchestrator Compliance framework

## What this artifact is
A Spring MVC `@RestController` implementing a generated OpenAPI `*Api` interface (`AccountApi`, from
openapi-generator `spring`, `interfaceOnly`) — the contract-first shape used across every capability adapter.

## Contract-first controller {#api-first-controller}
**Serves:** [`api-first-controller`](../api-first-controller.md)

`@RestController public class CustomerController implements AccountApi` — endpoint methods are `@Override`s of the
generated interface (no `@GetMapping`/`@PathVariable`/`@RequestBody` annotations re-declared on those methods; Spring
MVC reads them from the generated interface). Methods return what the generated interface declares (the DTO, or
`void` for an operation without a response body, answered with the interface's generated `@ResponseStatus`); a fixed
`Cache-Control` is a `CacheControl` header set on the injected current `HttpServletResponse` (the return type is
fixed, so no `ResponseEntity`), and a non-200 status with an error body is a thrown `NotificationException`, which the
central `@RestControllerAdvice` answers with the `{"errors": [...]}` body.
Constructor-injected use-cases, one per endpoint
(`GetDelegationsUseCase`, `GetCustomerInformationUseCase`, ...); the controller's own job is only to call
`.execute(...)` and map the domain result to the generated DTO via a small static `*ToDTOMapper`
(for example `DelegationToDTOMapper::map`), never building DTOs inline. One extra non-generated endpoint
(`verifyDelegationForTopic`, hand-annotated `@GetMapping`) shows the pattern also tolerates a controller-owned
route alongside the generated ones when the contract does not (yet) cover it.

### Source (pseudonymized)
```java
package com.acme.shop.account.adapter.controller;

import com.acme.shop.account.domain.Topic;
import com.acme.shop.account.usecase.GetCustomerInformationUseCase;
import com.acme.shop.account.usecase.GetDelegationsUseCase;
import com.acme.shop.account.usecase.RecordLastVisitCustomerUseCase;
import com.acme.shop.account.usecase.VerifyDelegationForTopicAccessUseCase;
import com.acme.shop.api.AccountApi;
import com.acme.shop.api.model.CustomerInformationDTO;
import com.acme.shop.api.model.DelegationDTO;
import com.acme.shop.common.adapter.controller.NotificationException;
import jakarta.servlet.http.HttpServletResponse;
import lombok.RequiredArgsConstructor;
import org.springframework.http.CacheControl;
import org.springframework.http.HttpHeaders;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RestController;

import java.time.Duration;
import java.util.List;

@RestController
@RequiredArgsConstructor
public class CustomerController implements AccountApi {
    private final GetDelegationsUseCase getDelegationsUseCase;
    private final GetCustomerInformationUseCase getCustomerInformationUseCase;
    private final RecordLastVisitCustomerUseCase createOrUpdateCustomerLastVisitUseCase;
    private final VerifyDelegationForTopicAccessUseCase verifyDelegationForTopicAccessUseCase;
    private final HttpServletResponse response; // a proxy to the current request's response

    @GetMapping("/api/delegation/verify-topic-access/{topic}")
    public Boolean verifyDelegationForTopic(@PathVariable("topic") Topic topic) {
        return verifyDelegationForTopicAccessUseCase.execute(topic);
    }

    @Override
    public List<DelegationDTO> getAllDelegations() {
        response.setHeader(HttpHeaders.CACHE_CONTROL, CacheControl.maxAge(Duration.ofDays(1)).getHeaderValue());
        return getDelegationsUseCase.execute().stream()
                .map(DelegationToDTOMapper::map).toList();
    }

    @Override
    public CustomerInformationDTO getGeneralInformation(String nid) {
        var customerInformation = getCustomerInformationUseCase.execute(nid);

        return CustomerInformationToDTOMapper.map(customerInformation);
    }

    @Override
    public void recordLastVisit() {
        var notification = createOrUpdateCustomerLastVisitUseCase.execute();

        if (notification.hasErrors()) {
            throw new NotificationException(notification.getErrors());
        }
    }
}
```

### Edge cases
Generated contract read with caching:
```java
mockMvc.perform(get("/api/delegation"))
        .andExpect(status().isOk())
        .andExpect(header().string(HttpHeaders.CACHE_CONTROL, containsString("max-age")));
```
Expected: generated-interface overrides can still add HTTP response metadata such as cache control.

Manual route beside generated methods:
```java
mockMvc.perform(get("/api/delegation/verify-topic-access/ORDERS"))
        .andExpect(status().isOk());
```
Expected: controller-owned routes can coexist with generated overrides without changing the contract-generated methods.

Write endpoint returning validation errors:
```java
when(recordLastCustomerVisitUseCase.execute()).thenReturn(Notification.builder()
        .error("Could not record Springfield storefront visit")
        .build());
mockMvc.perform(post("/api/customer/last-visit"))   // @WebMvcTest(CustomerController.class) loads the advice too
        .andExpect(status().isBadRequest());
```
Expected: the controller turns notification errors into `400 Bad Request` with a structured `NotificationDTO`.

## Provenance
- Scanned at: `abc1234` · tool/query: `rg 'Controller implements [A-Za-z]+Api' --glob '*.java'` (33 files / 14 modules)
