---
name: run-app
description: Start, run, smoke-test and stop the wedding-portal backend (Quarkus dev mode on :8080 with a Dev Services PostgreSQL). Use when asked to run, start, launch or boot the portal app or backend, check that it comes up, hit its endpoints, look at its dev database, or stop it.
---

The backend is a Quarkus server; drive it with `.github/skills/run-app/smoke.sh`, which starts dev mode in the
background, waits for it, and checks it with `curl` and `psql`. All paths are relative to the repo root (the main
checkout or a worktree).

## Prerequisites

Already on this machine, nothing to install: JDK 26 as `java` (SDKMAN `current` → Temurin 26; the Gradle toolchain asks
for 26), Docker with a running daemon (Dev Services starts `postgres:18.6-alpine`), `git`, `curl`, `ss`. No Maven, no
Node: Gradle comes from `./gradlew`.

```bash
java -version 2>&1 | head -1          # openjdk version "26.0.2.1"
docker version --format '{{.Server.Version}}'
```

## Run (agent path)

```bash
bash .github/skills/run-app/smoke.sh          # start (or reuse) + check; exit 0 = all PASS
bash .github/skills/run-app/smoke.sh check    # checks only, against a running instance
bash .github/skills/run-app/smoke.sh status
bash .github/skills/run-app/smoke.sh stop
```

A cold start takes about 17 s (contract clone included); a warm one reuses the running instance. `start` first makes
sure `contract/` exists: it clones `@@KIT_CONTRACT_REPO@@` there when missing and checks it out at
`@@KIT_CONTRACT_TAG_KEY@@` from `gradle.properties` with `.claude/scripts/contract-pin.sh`. It sets throwaway ops credentials
(`ops` / `local-dev-only`) unless `WEDDING_OPS_USERNAME` / `WEDDING_OPS_PASSWORD` are set.

`check` prints one PASS/FAIL line per step:

| step | expects |
|---|---|
| `GET /api/health` | 200 `{"ok":true}`, no auth |
| `GET /q/health/live` | 200 UP, no auth |
| `GET /q/health/ready` | 401 without credentials; 200 as ops, with the database check UP |
| `GET /q/metrics` as ops | 200, Prometheus text |
| `GET /api/no-such-route` | 404 `{"code":"NOT_FOUND",...}` from the app's error mapper |
| `GET /api/health` with a bad basic header | 401 (proactive auth) |
| dev database | every row of `flyway_schema_history` succeeded, listed |

Log: `/tmp/run-app/app.log`. Overrides: `PORT`, `STATE_DIR`, `START_TIMEOUT`. Dev mode hot-reloads on the next
request after a source change, so leave it running while you edit and re-run `check`.

To query the dev database yourself:

```bash
db=$(docker ps --filter ancestor=postgres:18.6-alpine --format '{{.ID}}' | head -1)
docker exec "$db" psql -U quarkus -d wedding_portal -c '\dt'
```

## Run (human path)

```bash
WEDDING_OPS_USERNAME=ops WEDDING_OPS_PASSWORD=local-dev-only ./gradlew :application:quarkusDev   # Ctrl-C stops it
```

Needs `contract/` in place first (see Gotchas). Dev UI: http://localhost:8080/q/dev-ui.

## Test

```bash
./gradlew :shared-adapter:test       # one module's tests: 136 pass in this module
```

Before a push run `.claude/scripts/affected-check.sh`, never the whole suite (see `.claude/CLAUDE.md`).

## Gotchas

- **Only `HealthApi` is implemented so far.** Every other contract operation answers 404, so the smoke checks are the
  app's whole HTTP surface today. When a controller lands, add its route to `check` in `smoke.sh`.
- **`contract/` is not in git.** The build generates the server interfaces from `contract/dist/openapi.yaml`, which CI
  clones into the ignored `contract/` folder. A fresh checkout or worktree does not have it; `smoke.sh start` does
  this for you. The pin is a tag (`main` is refused), so a newer contract release needs a `gradle.properties` bump.
- **The ops credentials have no default, on purpose** (owner decision 2026-10-18, `docs/memory.md`): dev mode refuses to
  start without them. The script's pair is for local use only; never put a real one in a file.
- **The dev database does not survive a restart**, even with `testcontainers.reuse.enable=true` in
  `~/.testcontainers.properties` (set on this machine since 2026-10-19). Quarkus 3.39.1 creates the container with
  `withReuse(true)` (it carries an `org.testcontainers.hash` label), but its PostgreSQL Dev Service closes it with
  `PostgreSQLContainer.close()` on shutdown, not the reuse-aware `ContainerShutdownCloseable`, so a clean stop still
  removes it and the next start gets an empty, freshly migrated database.
- **Stopping the gradle process is not enough.** The `quarkusDev` client does not pass SIGTERM on to the dev JVM; `stop`
  ends the port's listener (`ss -ltnp`) first.
- **Stack traces in test output are expected.** The error-mapper tests log the exceptions they provoke; read the JUnit
  results (`<module>/build/test-results/test/*.xml`), not the console.

## Troubleshooting

- **`property 'inputSpec' specifies file '.../contract/dist/openapi.yaml' which doesn't exist`** (`BUILD FAILED` in
  `:shared-adapter:openApiGenerate`): no contract checkout. `smoke.sh start` clones it; by hand:
  `git clone https://github.com/@@KIT_CONTRACT_REPO@@.git contract && bash .claude/scripts/contract-pin.sh contract`.
