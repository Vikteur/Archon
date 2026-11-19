#!/usr/bin/env bash
# Scaffold a new bounded context: the <capability>-domain, -usecase and -adapter modules with their build files,
# the adapter's bean wiring and test bases, registered in settings.gradle.kts and application/build.gradle.kts.
# Usage: scripts/scaffold/new-context.sh [--gateway] <capability> <Ctx> <basePackage> <apis> <models>
#   e.g. scripts/scaffold/new-context.sh therapeutic-relation TherapeuticRelation be.mijngezondheid.therapeuticrelation \
#        TherapeuticRelation "therapeuticRelation,therapeuticExclusion"
#   <apis>/<models>: the openApiConventions globalProperties of the adapter (contract tags and generated models).
#   --gateway: also a <capability>-gateway module (RestClient + WireMock tests) that the adapter depends on.
# Renders the project templates under docs/scaffold-templates/project/module/ (and adapter/bean-config) through
# scripts/scaffold.sh, so every file is in the scaffold record. Refuses when any of the modules exists.
# The aggregate's own files come after, one scripts/scaffold.sh call each (see docs/scaffold-templates/project/README.md).
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
gateway=false
if [[ "${1:-}" == "--gateway" ]]; then gateway=true; shift; fi
[[ $# -eq 5 ]] || { sed -n '4,9p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
cap="$1" Ctx="$2" base="$3" apis="$4" models="$5"
modules=(domain usecase adapter)
[[ $gateway == true ]] && modules+=(gateway)

[[ "$cap" =~ ^[a-z][a-z0-9-]*$ ]] || { echo "[new-context] capability must be kebab-case: $cap" >&2; exit 1; }
[[ "$Ctx" =~ ^[A-Z][A-Za-z0-9]*$ ]] || { echo "[new-context] Ctx must be PascalCase: $Ctx" >&2; exit 1; }
[[ "$base" =~ ^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)*$ ]] || { echo "[new-context] invalid base package: $base" >&2; exit 1; }
cd "$root"
for m in "${modules[@]}"; do
  [[ ! -e "$cap-$m" ]] || { echo "[new-context] module exists, refusing: $cap-$m" >&2; exit 1; }
done

ctx="$(printf '%s' "${Ctx:0:1}" | tr '[:upper:]' '[:lower:]')${Ctx:1}"
path="${base//.//}"
scaffold() { bash scripts/scaffold.sh "$@"; }

scaffold project/module/domain-build "$(jq -nc --arg c "$cap" '{capability:$c}')" "$cap-domain/build.gradle.kts"
scaffold project/module/usecase-build "$(jq -nc --arg c "$cap" '{capability:$c, authentication:false}')" \
  "$cap-usecase/build.gradle.kts"
scaffold project/module/adapter-build "$(jq -nc --arg c "$cap" --arg p "$base.adapter.controller" --arg a "$apis" \
  --arg m "$models" --argjson g "$gateway" '{capability:$c, gateway:$g, apiPackage:$p, apis:$a, models:$m}')" \
  "$cap-adapter/build.gradle.kts"
scaffold project/adapter/bean-config "$(jq -nc --arg p "$base.adapter.config" --arg C "$Ctx" --arg c "$ctx" \
  --arg u "$base.usecase" --arg d "$base.domain" \
  '{package:$p, Ctx:$C, ctx:$c, usecaseBasePackage:$u, domainBasePackage:$d}')" \
  "$cap-adapter/src/main/java/$path/adapter/config/${Ctx}BeanConfig.java"
scaffold --test project/module/abstract-repository-test "$(jq -nc --arg p "$base.adapter.repository" '{package:$p}')" \
  "$cap-adapter/src/test/java/$path/adapter/repository/AbstractRepositoryTest.java"
scaffold --test project/module/test-application-properties '{}' "$cap-adapter/src/test/resources/application.properties"
cp init_postgres.sql "$cap-adapter/src/test/resources/init_postgres.sql"
echo "[new-context] $cap-adapter/src/test/resources/init_postgres.sql (copy of init_postgres.sql)"
if [[ $gateway == true ]]; then
  scaffold project/module/gateway-build "$(jq -nc --arg c "$cap" '{capability:$c, authentication:true}')" \
    "$cap-gateway/build.gradle.kts"
  scaffold --test project/module/gateway-test-config "$(jq -nc --arg p "$base.gateway" \
    --arg r "${ctx}RestClient" '{package:$p, gatewayPackage:$p, restClient:$r}')" \
    "$cap-gateway/src/test/java/$path/gateway/TestConfig.java"
fi

# Register the modules: settings.gradle.kts include(...) block and the application's dependency.
node - "$cap" "${modules[*]}" <<'NODE'
const fs = require('fs');
const cap = process.argv[2];
const modules = process.argv[3].split(' ');
const settings = 'settings.gradle.kts';
let s = fs.readFileSync(settings, 'utf8');
const m = /include\(\n([\s\S]*?)\n\)/.exec(s);
if (!m) { console.error('[new-context] no include( ... ) block in settings.gradle.kts'); process.exit(1); }
const items = m[1].split('\n').map(l => l.trim().replace(/,$/, '')).filter(Boolean);
for (const mod of modules) {
  const q = `"${cap}-${mod}"`;
  if (!items.includes(q)) items.push(q);
}
s = s.replace(m[0], 'include(\n' + items.map(i => `    ${i}`).join(',\n') + '\n)');
fs.writeFileSync(settings, s);

const app = 'application/build.gradle.kts';
let a = fs.readFileSync(app, 'utf8');
const dep = `    implementation(project(":${cap}-adapter"))`;
if (!a.includes(dep)) {
  const lines = a.split('\n');
  const last = lines.map((l, i) => /^\s*implementation\(project\(":/.test(l) ? i : -1).filter(i => i >= 0).pop();
  if (last === undefined) { console.error('[new-context] no implementation(project(...)) line in ' + app); process.exit(1); }
  lines.splice(last + 1, 0, dep);
  fs.writeFileSync(app, lines.join('\n'));
}
console.log(`[new-context] registered ${modules.map(m => `${cap}-${m}`).join(', ')} in settings.gradle.kts and ${app}`);
NODE
