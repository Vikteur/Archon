---
runtime: lazy
source: partner-gateway/src/main/java/com/acme/shop/partner/config/WebServiceConfig.java
serves: [bean-config-di]
kind: worked-example
---

<!-- AI_DISCLAIMER v1.0 -->
# Exemplar — `partner-gateway/.../config/WebServiceConfig.java` (project: `shop-backend`)

> This file has been created (totally or partially) with the assistance of artificial intelligence tools.
> All content has been generated under the direct supervision of a named individual,
> and under the AI.Backbone Orchestrator Compliance framework

## What this artifact is
One of 67 Spring `@Configuration` classes in the repo; this one supplies the WS-Security interceptors and the three
generated SOAP port clients (`RegistryPortType`, `AttributeServicePortType`, `CustomerServicePortType`)
via a project-local `WSFactory` helper (`webservice-config` module), which builds each proxy with CXF's
`JaxWsProxyFactoryBean`. The clients' settings are bound from `application.yml` into a `@ConfigurationProperties`
record; the CXF `Bus` is managed by the CXF Spring Boot starter (`org.apache.cxf:cxf-spring-boot-starter-jaxws`) —
the same shape used for every CXF/SOAP gateway.

## `@Configuration` class with `@Bean` methods {#bean-config-di}
**Serves:** [`bean-config-di`](../bean-config-di.md)

A `@Configuration` class with constructor injection of the shared `WSFactory` collaborator;
each interceptor `@Bean` method returns one security interceptor, named by its module-prefixed method name
(`partner...`; convention here: Spring names a scanned configuration class by its simple class name and refuses a
second bean of the same name, so the class takes an explicit `partnerWebServiceConfig` name and every `@Bean` method
name carries the module prefix). Each client `@Bean` method takes its interceptor by `@Qualifier` and its settings
from `PartnerClientProperties` and hands both to `WSFactory`; gateways get the port client by constructor injection,
and no `@Bean` method configures a `JaxWsProxyFactoryBean` itself.

### Source (pseudonymized)
```java
package com.acme.shop.partner.config;

import com.acme.partner.auth.protocol.v1.AttributeServicePortType;
import com.acme.partner.customer.protocol.v1.CustomerServicePortType;
import com.acme.partner.registry.protocol.v2.RegistryPortType;
import com.acme.shop.webservice.config.ws.WSFactory;
import lombok.extern.slf4j.Slf4j;
import org.apache.cxf.binding.soap.SoapMessage;
import org.apache.cxf.interceptor.Interceptor;
import org.apache.cxf.ws.security.wss4j.WSS4JOutInterceptor;
import org.springframework.beans.factory.annotation.Qualifier;
import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.boot.context.properties.EnableConfigurationProperties;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

import java.net.URI;

@Configuration("partnerWebServiceConfig")
@EnableConfigurationProperties(PartnerClientProperties.class)
@Slf4j
public class WebServiceConfig {
    private final WSFactory wsFactory;

    public WebServiceConfig(WSFactory wsFactory) {
        this.wsFactory = wsFactory;
    }

    @Bean
    Interceptor<SoapMessage> partnerSessionTokenOutInterceptor() {
        return wsFactory.createSessionTokenOutInterceptor();
    }

    @Bean
    WSS4JOutInterceptor partnerKeyStoreOutInterceptor() {
        return wsFactory.createKeyStoreOutInterceptor();
    }

    @Bean
    RegistryPortType partnerRegistryPortType(PartnerClientProperties clients,
            @Qualifier("partnerSessionTokenOutInterceptor") Interceptor<SoapMessage> sessionToken) {
        return wsFactory.createClient(RegistryPortType.class, clients.registry(), sessionToken);
    }

    @Bean
    AttributeServicePortType partnerAttributeServicePortType(PartnerClientProperties clients,
            @Qualifier("partnerKeyStoreOutInterceptor") WSS4JOutInterceptor keyStore) {
        return wsFactory.createClient(AttributeServicePortType.class, clients.attributeAuthority(), keyStore);
    }

    @Bean
    CustomerServicePortType partnerCustomerServicePortType(PartnerClientProperties clients,
            @Qualifier("partnerSessionTokenOutInterceptor") Interceptor<SoapMessage> sessionToken) {
        return wsFactory.createClient(CustomerServicePortType.class, clients.customerService(), sessionToken);
    }
}

@ConfigurationProperties("partner.clients")
record PartnerClientProperties(Client registry, Client attributeAuthority, Client customerService) {
    record Client(String wsdl, URI endpointUrl, String endpointNamespace, String endpointName) {}
}
```

```yaml
# application/src/main/resources/application.yml
partner:
  clients:
    registry:
      wsdl: wsdls/RegistryWebService-v2.wsdl
      endpoint-url: ${properties.endpoint.partner.registry}
      endpoint-namespace: urn:com:acme:shop:partner:registry:protocol:v2
      endpoint-name: RegistryPort
    attribute-authority:
      wsdl: wsdls/PartnerAttributeAuthority-v1.wsdl
      endpoint-url: ${properties.endpoint.partner.attribute-authority}
      endpoint-namespace: urn:com:acme:shop:partner:auth:protocol:v1
      endpoint-name: AttributeServicePort
    customer-service:
      wsdl: wsdls/partner-customer-service-v1.wsdl
      endpoint-url: ${properties.endpoint.partner.customer-service}
      endpoint-namespace: urn:com:acme:shop:partner:customer:protocol:v1
      endpoint-name: CustomerServicePort
```

### Edge cases
Two modules define a `WebServiceConfig`:
```java
@Configuration("partnerWebServiceConfig")
class WebServiceConfig { ... }   // com.acme.shop.partner.config and com.acme.shop.fulfilment.config
```
Expected: no collision only because each class takes an explicit module-prefixed name — Spring's default bean name
is the simple class name, so two unnamed `WebServiceConfig` classes fail the scan with
`ConflictingBeanDefinitionException`; the `@Bean` method names must stay unique too, hence the module prefix.

Absent interceptor bean:
```java
@Bean
RegistryPortType partnerRegistryPortType(PartnerClientProperties clients,
        @Qualifier("partnerSessionTokenOutInterceptor") Interceptor<SoapMessage> sessionToken) { ... }
// ...but no @Bean method named partnerSessionTokenOutInterceptor exists
```
Expected: startup fails immediately (`NoSuchBeanDefinitionException`) instead of creating an unsecured SOAP client.

Adding a new SOAP integration:
```yaml
partner:
  clients:
    supplier-service:
      wsdl: wsdls/SupplierService-v1.wsdl
      endpoint-url: ${properties.endpoint.partner.supplier-service}
```
```java
@Bean
SupplierServicePortType partnerSupplierServicePortType(PartnerClientProperties clients,
        @Qualifier("partnerSessionTokenOutInterceptor") Interceptor<SoapMessage> sessionToken) {
    return wsFactory.createClient(SupplierServicePortType.class, clients.supplierService(), sessionToken);
}
```
Expected: the new client is declared in config, bound through a new `PartnerClientProperties` component and built by
a one-line `@Bean` method; no `@Bean` method hand-configures a `JaxWsProxyFactoryBean`, and proxy and interceptor
construction stays in `WSFactory`.

## Provenance
- Scanned at: `abc1234` · tool/query: `rg '@Configuration' --glob '*Config.java'` (70 matches / 67 files / 24 modules), `rg '@Bean'` (90 matches / 43 files / 24 modules)
