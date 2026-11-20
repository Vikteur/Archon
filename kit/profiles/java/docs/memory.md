# Project memory

Decisions already taken, and approaches already tried and abandoned, one bullet each, newest last. Read it before you
propose a change that reverses one: the reasoning is not in the code. Installed by the Archon kit (`archon kit add`)
as a starter, written only when the project had no `docs/memory.md`; from here on it is the project's own file.

## Decisions

- CI job set (ci-workflow-check.sh, N7): `archon-scripts test`. The jobs of the kit's
  `.github/workflows/ci.yml`. A change to the job set lands together with a new bullet here that names the new set;
  the last one counts.
- Report-only gates (ci-gate.sh, kit/SPEC.md): tests ran, format (Spotless), coverage (JaCoCo, no threshold), secret
  scan (gitleaks) and contract lint (Spectral) print their findings and never fail a job. A gate turns blocking when its
  kit key `gates.<gate>` in `.archon/kit.yaml` is `block`; that switch is a gate change (gate-change-check.sh,
  kit-gates) and lands together with a dated `### yyyy-mm-dd` entry here that names the gate and why.
