---
name: bean-config-di
description: Wire collaborators with @Configuration @Bean methods, typed configuration properties and constructor injection. Use when configuring DI.
---
# Bean configuration & dependency injection

## When to use
Wiring a collaborator (client, gateway, cache, scheduler) into the Spring application context, or
choosing an implementation per environment.

## How
- Declare non-trivial beans as `@Bean` methods in dedicated `@Configuration` classes; keep wiring
  **out of** domain/use-case code.
- Prefer **constructor injection** (final fields, no `@Autowired` needed on a single constructor);
  avoid field injection. Mark discovered beans with a stereotype (`@Service`, `@Component`,
  `@Repository`), and centralize wiring of clients and third-party types in the configuration classes.
- Scope environment-specific beans with `@Profile` or `@ConditionalOnProperty`; disambiguate
  multiples with `@Qualifier` or `@Primary`.
- Externalize values with a `@ConfigurationProperties` record (registered through
  `@EnableConfigurationProperties` or `@ConfigurationPropertiesScan`; `@Value` only for a single
  value); never inline endpoints/secrets.
- Keep config classes thin — they assemble, they don't compute.

## Pattern signals (discovery cues)
`@Configuration` classes with `@Bean` methods; constructor-injected `final` collaborators;
`@Profile` / `@ConditionalOn*` / `@Qualifier`; `@ConfigurationProperties` / `@Value` for externalized config.

## Project specifics → see docs
- Code map (config classes, profiles, properties conventions) → `docs/code-maps/bean-config-di.md` *(per-repo map; if marked `kind: worked-example`, follow its structure and map its pseudonymized names to this repo's own)*

## Guardrails (what NOT to do)
- Don't wire beans inside domain/use-case classes — that's the config layer's job.
- Don't use field injection; constructor-inject final fields.
- Don't hardcode env-specific values — externalize and profile them.

## Definition of done
- [ ] Collaborators wired by `@Bean` methods via constructor injection; env variants profiled/qualified; values externalized; no wiring in business code.
- [ ] Verified by: the application context starting in a `@SpringBootTest`, and no business class importing the DI framework's injection annotation.
