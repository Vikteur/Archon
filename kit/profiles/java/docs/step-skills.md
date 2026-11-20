# Step skills

The table the plan node of build-feature-copilot writes each step's two skill lines from: under every step,
`Test skills: <names>` for the test agent and `Build skills: <names>` for the build agent, each with only the skills of
that agent's column that fit what the step touches (the skill names, not the paths). A step touches several rows when
it changes several things; `none` stands on a line only when that agent writes nothing for the step.

| What the step touches             | Test skills                              | Build skills                                                     |
|-----------------------------------|------------------------------------------|------------------------------------------------------------------|
| any code or test                  | tdd-loop, jvm-testing                    | java, clean-code                                                 |
| domain type                       | object-mother-builders                   | domain-modeling, validation-notification-result                  |
| domain event                      |                                          | domain-events                                                    |
| use case                          | usecase-bdd-spec, object-mother-builders | usecase-orchestration, validation-notification-result            |
| controller, error mapping         |                                          | api-first-controller, exception-to-http                          |
| mapper (domain ↔ DTO)             | domain-to-dto-mapper-tests               | domain-dto-mapper                                                |
| repository, entity                | testcontainers                           | persistence-repository, jpa-entity-mapping                       |
| database schema                   | testcontainers                           | flyway-migrations                                                |
| gateway, remote call              |                                          | resilience4j, domain-dto-mapper                                  |
| DI wiring, config, profiles       |                                          | bean-config-di                                                   |
| generated code, codegen in build  |                                          | code-generation                                                  |
| test against a real service       | testcontainers                           |                                                                  |
| architecture rule                 | archunit-fitness                         |                                                                  |

A skill named here that no installed profile ships (each node's `skills:` list in the workflow is its allow-list) is
left off the line. The project may change the rows to its own stack: the kit owns this file
(`.archon/kit.lock.json`), so an update overwrites a local change.
