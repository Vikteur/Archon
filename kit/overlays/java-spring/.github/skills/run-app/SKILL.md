---
name: run-app
description: Start, run, smoke-test and stop the Spring Boot backend (`./gradlew bootRun` with a docker compose PostgreSQL). Use when asked to run, start, launch or boot the app or backend, check that it comes up, hit its endpoints, look at its local database, or stop it.
---

The backend is a Spring Boot server; drive it with `.github/skills/run-app/scripts/smoke.sh`, which starts `bootRun` in
the background, waits until actuator health says UP, and checks it with `curl` and `psql`. All paths are relative to
the repo root (the main checkout or a worktree). The project's own facts (module, port, compose file, extra routes to
check) live in `docs/code-maps/run-app.md`; the script reads its `KEY: value` lines when the file exists.

## Prerequisites

A JDK the Gradle toolchain accepts (Java 21; Gradle can auto-provision or auto-detect it), Docker with a running daemon
and the compose plugin, `git`, `curl`, `ss`, `python3` (reads the compose file's database user and name). Gradle comes
from `./gradlew`.

```bash
java -version 2>&1 | head -1
docker compose version
```

## Run (agent path)

```bash
bash .github/skills/run-app/scripts/smoke.sh          # start (or reuse) + check; exit 0 = all PASS
bash .github/skills/run-app/scripts/smoke.sh check    # checks only, against a running instance
bash .github/skills/run-app/scripts/smoke.sh status
bash .github/skills/run-app/scripts/smoke.sh stop
```

`start` makes sure the database is there first. When the app module depends on `spring-boot-docker-compose`
(`developmentOnly`), `bootRun` starts the compose file itself and points the DataSource at it; otherwise the script runs
`docker compose up -d --wait`. It passes `SERVER_PORT`, so the app listens where the checks look.

`check` prints one PASS/FAIL line per step:

| step | expects |
|---|---|
| `GET <HEALTH_PATH>` | 200, `"status":"UP"` |
| `GET <HEALTH_PATH>/liveness`, `/readiness` | 200 UP (needs `management.endpoint.health.probes.enabled=true`) |
| each `EXTRA_CHECKS` line | the given status, and the body matching the regex when one is given |
| local database | every row of `flyway_schema_history` succeeded, listed |

Settings (environment first, then the code map, then the default): `APP_MODULE` (application), `PORT` (8080),
`HEALTH_PATH` (/actuator/health), `COMPOSE_FILE` (compose.yaml), `DB_SERVICE` (postgres), `DB_USER` / `DB_NAME` (from
the compose service's `POSTGRES_USER` / `POSTGRES_DB`), `EXTRA_CHECKS` (a file of `<status> <path> [regex]` lines),
`STATE_DIR`, `START_TIMEOUT` (300). Log: `${TMPDIR:-/tmp}/run-app-<repo>/app.log`.

To query the local database yourself:

```bash
docker compose exec postgres psql -U <user> -d <db> -c '\dt'
```

## Run (human path)

```bash
./gradlew :application:bootRun      # Ctrl-C stops it gracefully
```

Spring DevTools, when the project has it, restarts on a recompile; without it, stop and start again after a change.

## Test

```bash
./gradlew :<module>:test            # one module's unit and slice tests
./gradlew :<module>:integrationTest # its Testcontainers tests
```

Before a push run the project's affected-tests script, never the whole suite (see the root instruction file).

## Gotchas

- **The API is generated from the contract.** `compileJava` depends on `openApiGenerate`; a missing spec file fails the
  build with `inputSpec ... doesn't exist`. The project's code map says where the spec comes from.
- **Stop the JVM, not only Gradle.** `stop` sends SIGTERM to the port's listener first, so Spring runs its graceful
  shutdown (`server.shutdown=graceful`), then ends the Gradle client.
- **The compose database outlives the app.** With `spring.docker.compose.lifecycle-management=start-only`, or after the
  script's own `up`, the database keeps running, so the next start is warm and keeps its data. `docker compose down`
  (add `-v` to drop the data) ends it.
- **A port already in use** makes Tomcat fail with `Port <n> was already in use`; `status` shows who answers, `PORT`
  moves the app.
- **Stack traces in test output can be expected.** Error-mapper tests log the exceptions they provoke; read the JUnit
  results (`<module>/build/test-results/*/*.xml`), not the console.

## Troubleshooting

- **`APPLICATION FAILED TO START`** with `Failed to configure a DataSource`: no database. Without
  `spring-boot-docker-compose`, set `SPRING_DATASOURCE_URL` / `_USERNAME` / `_PASSWORD` or let the script start the
  compose file.
- **`Schema-validation: missing table`** (`ddl-auto=validate`): a migration is missing or Flyway is not on the runtime
  classpath; the database step of `check` lists what ran.
