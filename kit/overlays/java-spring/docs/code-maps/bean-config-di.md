---
runtime: lazy
kind: worked-example
---

<!-- AI_DISCLAIMER v1.0 -->
# Code map — `bean-config-di` (project: `shop-backend`)

> This file has been created (totally or partially) with the assistance of artificial intelligence tools.
> All content has been generated under the direct supervision of a named individual,
> and under the AI.Backbone Orchestrator Compliance framework

## This repo (<project>)
These are the real facts. Everything from "Where this pattern lives" down is the pseudonymized worked example
(`shop-backend`): follow its structure, not its names.

- **Configuration** enters only through `@Configuration` classes and `@ConfigurationProperties` records in
  `application` and gateways (an ArchUnit rule, `CrossCuttingConventionTest`).
- **Cookies keep fixed names, paths and lifetimes:** `<session-cookie>` path `/`, 30 days absolute, 7 days idle;
  `<second-cookie>` path `/api`, 30 days absolute, 14 days idle; both written as a `ResponseCookie` with HttpOnly,
  SameSite=Lax, Secure on HTTPS.
- **CORS** is configuration only: off in the `prod` profile, the `dev` profile allows `DEV_CORS_ORIGINS` (default vite
  ports 5173-5176 on localhost and 127.0.0.1) with credentials, through one `CorsConfigurationSource` bean that the
  `SecurityFilterChain` uses (`http.cors(...)`).
- **Tokens** are 32 random bytes, base64url; only their SHA-256 digest is stored.
- **Logging:** personal data goes through `<base-package>.logging.LogSafe` (`LogSafe.email(...)`, `LogSafe.token(...)`).
  The audit log is append-only.

## Where this pattern lives (exemplars)
| Exemplar | What it shows | Layer / module |
|----------|---------------|----------------|
| [`WebServiceConfig.java`](exemplars/web-service-config.md#bean-config-di) | `@Configuration` class, `@Bean` methods with module-prefixed names composing a project-local factory helper | adapter (`partner-gateway`) |

### Excerpts
Config class plus declarative bean production (full source in the [exemplar leaf](exemplars/web-service-config.md#bean-config-di)):
```java
@Configuration("partnerWebServiceConfig")
public class WebServiceConfig {
    @Bean
    Interceptor<SoapMessage> partnerSessionTokenOutInterceptor() {
        return wsFactory.createSessionTokenOutInterceptor();
    }
}
```
The SOAP port clients' settings are bound from `application.yml` (`partner.clients.<name>.*`) into the
`PartnerClientProperties` record, and each client is one `@Bean` method that hands them to `WSFactory`.

### Edge cases
Two modules define `WebServiceConfig`:
```java
@Configuration("partnerWebServiceConfig")
class WebServiceConfig { ... }   // com.acme.shop.partner.config and com.acme.shop.fulfilment.config
```
Expected: Spring names a scanned configuration class by its simple class name, so two `WebServiceConfig` classes
clash at startup (`ConflictingBeanDefinitionException`) unless each takes an explicit module-prefixed name; the
module-prefixed `@Bean` method names must stay unique too (bean overriding is off by default).

Shared helper bean is absent:
```java
public WebServiceConfig(WSFactory wsFactory) { ... }   // no WSFactory bean on the classpath
```
Expected: the context fails to start immediately (`UnsatisfiedDependencyException`); `@Bean` methods do not
hide absent collaborators.

A `@Bean` method starts hand-building proxies:
```java
@Bean
RegistryPortType registryPortType() {
    var factory = new JaxWsProxyFactoryBean();
    factory.setAddress("https://registry.example.invalid/ws");
    return factory.create(RegistryPortType.class);
}
```
Expected: reject the change — declare the client under `partner.clients.<name>.*`, bind it through
`PartnerClientProperties`, and keep proxy and interceptor construction in `WSFactory`.

## Local conventions (the project facts the skill omits)
- Package root: `<module>/.../config/`.
- Naming shape: `*Config` (for example `WebServiceConfig`, `SalesRegionCacheConfig`,
  `PartnerRestClientConfig`); `@Bean` methods carry a module-prefixed name (`partner...`) and are injected
  with `@Qualifier("partner...")` (or a custom qualifier) when the same type is produced in more than one module.
- Required collaborators / base types: constructor injection of `@ConfigurationProperties` records (`@Value` only for
  a single value) and shared infra beans (the CXF `Bus` is managed by the CXF Spring Boot starter, not injected);
  `@Bean` methods stay declarative, delegating actual construction logic to a helper class.
- Config / wiring: properties live in `application.yml` with `application-dev.yml`/`-test.yml`/`-prod.yml`
  profile files; scheduler configs use `@Profile("!test")` (or `@ConditionalOnProperty`) to disable jobs under test.

## Frequency & coverage (why this earned a skill)
- Occurrences: config classes (`@Configuration` in `*Config.java`) — 70 matches / 67 files / 24
  modules; `@Bean` — 90 matches / 43 files / 24 modules (as of `abc1234`).

## Drift / exceptions
- None observed beyond the module-prefixed bean-name convention noted above.
- **Throttle key:** `<project>.throttle.server-key` (base64, ≥32 bytes) is required in `prod` from env
  `<PROJECT>_THROTTLE_SERVER_KEY`, fixed throwaway values in `application-dev.yml`/`application-test.yml`; bound by a
  `@Validated` `@ConfigurationProperties` record, `ThrottleKeyHasher` checks it at start-up and never logs it.
- **Proxy:** `<PROJECT>_PROXY_FORWARDING` (default false, `server.forward-headers-strategy`) and
  `<PROJECT>_TRUSTED_PROXIES` (default empty, `server.tomcat.remoteip.internal-proxies`) go together, both or neither;
  `ForwardingGuard` refuses one without the other at start-up. The `test` profile forwards from 127.0.0.1.
- **Session:** `SessionCookieFilter` (a `OncePerRequestFilter` in the `SecurityFilterChain`) reads `<session-cookie>`
  and hands the token to `SessionAuthenticationProvider` (an `AuthenticationProvider` for
  `SessionTokenAuthentication`), which runs `ResolveSessionUseCase` on the request thread; the servlet stack is
  blocking, so no worker-thread hop is needed, and the use case's `@Transactional` carries the EntityManager. A
  missing, malformed or stale cookie leaves the request anonymous; `ServletSessionCookies` writes the cookie through
  `SessionCookies`.

## Provenance
- Scanned at: `abc1234` · tool/query: `rg '@Configuration' --glob '*Config.java'`, `rg '@Bean' --glob '*.java'`
