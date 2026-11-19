#!/usr/bin/env bash
# Tests for scripts/contract-mcp/server.mjs, through the MCP SDK's own client over stdio, on the readiness fixture
# contract and a Java tree this script writes; schema-graph.mjs on its own fixture spec; and where, schema and usedBy
# on the real tree when the checkout has the contract and the generated sources. Run from anywhere:
# bash scripts/test/contract-mcp.test.sh
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tool="$root/scripts/contract-mcp"
fx="$root/scripts/test/fixtures/contract-agent-readiness"
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "PASS: $1"; }
bad() { fail=$((fail+1)); echo "FAIL: $1${2:+ -- $2}"; }

[ -d "$tool/node_modules" ] || npm ci --prefix "$tool" --silent >/dev/null 2>&1 || { echo "FAIL: npm ci in $tool"; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
[ -n "$work" ] && [ -d "$work" ] || { echo "FAIL: mktemp"; exit 1; }
mkdir -p "$work/contract/dist"
cp "$fx/openapi.yaml" "$work/contract/dist/openapi.yaml"
bash "$root/scripts/contract-agent-readiness.sh" --spec "$work/contract/dist/openapi.yaml" --map "$fx/map.json" \
  --out "$work/build/contract-agent-readiness" >/dev/null 2>&1 || { echo "FAIL: the readiness report"; exit 1; }

# The Java tree `where` reads, written here so no fixture .java file sits in the repo: generated interfaces, a
# controller that implements two of them (one method live, one a stub, one missing), a use case, a mapper, their tests,
# an HTTP test with a concatenated path, a test that only names an operation, and a src/test class that implements a
# route (the arch fixtures do), which `where` must leave out.
gen="shared-adapter/build/generated/openapi/src/gen/java/com/example/api"
jv() { mkdir -p "$(dirname "$work/$1")"; cat >"$work/$1"; }
jv "$gen/NotesApi.java" <<'JAVA'
package com.example.api;
@Path("")
public interface NotesApi {
    @DELETE
    @Path("/notes/{noteId}")
    void deleteNote(@PathParam("noteId") UUID noteId);

    @PATCH
    @Path("/notes/{noteId}/name")
    @Consumes({ "application/json" })
    Note renameNote(@PathParam("noteId") UUID noteId, @Valid @NotNull RenameNote body);

    @GET
    @Path("/notes")
    @Produces({ "application/json" })
    List<Note> listNotes();
}
JAVA
jv "$gen/ProjectsApi.java" <<'JAVA'
package com.example.api;
@Path("")
public interface ProjectsApi {
    @POST
    @Path("/projects")
    Project createProject(@Valid ProjectInput body);
}
JAVA
jv "$gen/HealthApi.java" <<'JAVA'
package com.example.api;
@Path("/status")
public interface HealthApi {
    @GET
    @Produces({ "application/json" })
    Status getStatus();
}
JAVA
jv notes-adapter/src/main/java/app/fx/NotesController.java <<'JAVA'
package app.fx;
public class NotesController implements NotesApi, ProjectsApi {
    private final DeleteNoteUseCase deleteNoteUseCase;
    private final CreateProjectUseCase createProjectUseCase;

    @Override
    public void deleteNote(UUID noteId) {
        deleteNoteUseCase.execute(NoteIdMapper.map(noteId));
    }

    @Override
    @DenyAll
    public Note renameNote(UUID noteId, RenameNote body) {
        throw new UnsupportedOperationException();
    }

    @Override
    public Project createProject(ProjectInput body) {
        return createProjectUseCase.execute(body.getName());
    }
}
JAVA
jv notes-usecase/src/main/java/app/fx/DeleteNoteUseCase.java <<'JAVA'
package app.fx;
public class DeleteNoteUseCase { public void execute(NoteId id) { } }
JAVA
jv notes-usecase/src/main/java/app/fx/CreateProjectUseCase.java <<'JAVA'
package app.fx;
public class CreateProjectUseCase { public Project execute(String name) { return null; } }
JAVA
jv notes-adapter/src/main/java/app/fx/NoteIdMapper.java <<'JAVA'
package app.fx;
public final class NoteIdMapper { public static NoteId map(UUID id) { return new NoteId(id); } }
JAVA
jv notes-usecase/src/test/java/app/fx/DeleteNoteUseCaseTest.java <<'JAVA'
package app.fx;
class DeleteNoteUseCaseTest { private final DeleteNoteUseCase useCase = new DeleteNoteUseCase(); void deletes() { useCase.execute(null); } }
JAVA
jv application/src/test/java/app/fx/DeleteNoteResourceTest.java <<'JAVA'
package app.fx;
class DeleteNoteResourceTest {
    void deletes() {
        given().when().delete("/notes/" + noteId).then().statusCode(204);
    }
}
JAVA
jv application/src/test/java/app/fx/RenameNoteDocTest.java <<'JAVA'
package app.fx;
/** Pins renameNote's refusal, through the guard only. */
class RenameNoteDocTest { }
JAVA
jv notes-adapter/src/test/java/app/fx/FixtureRoute.java <<'JAVA'
package app.fx;
public class FixtureRoute implements NotesApi {
    @Override
    public void deleteNote(UUID noteId) { }
}
JAVA

# Calls the tools named in $1 (a JSON object: answer name → [tool, arguments]) and prints one JSON object of what
# they answered, with the tool list under `tools`.
client() {
  CLAUDE_PROJECT_DIR="$work" CALLS="$1" node --input-type=module -e "
    import { Client } from '$tool/node_modules/@modelcontextprotocol/sdk/dist/esm/client/index.js';
    import { StdioClientTransport } from '$tool/node_modules/@modelcontextprotocol/sdk/dist/esm/client/stdio.js';
    const c = new Client({ name: 'test', version: '0' });
    await c.connect(new StdioClientTransport({ command: 'node', args: ['$tool/server.mjs'], env: { ...process.env } }));
    const text = async (name, args) => { const r = await c.callTool({ name, arguments: args }); return { isError: !!r.isError, size: r.content[0].text.length, value: JSON.parse(r.content[0].text) }; };
    const out = { tools: (await c.listTools()).tools.map((t) => t.name).sort() };
    for (const [k, [name, args]] of Object.entries(JSON.parse(process.env.CALLS))) out[k] = await text(name, args);
    await c.close();
    console.log(JSON.stringify(out));"
}
out="$work/out.json"
check() { # check <name> <jq filter that must yield true>
  if [ "$(jq -r "$2" "$out" 2>/dev/null)" = "true" ]; then ok "$1"; else bad "$1" "$(jq -c "$2" "$out" 2>&1 | head -c 300)"; fi
}

client '{
  "search": ["search", {"query": "delete a note"}],
  "none": ["search", {"query": "zzqx"}],
  "read": ["read", {"operationId": "deleteNote"}],
  "unknown": ["read", {"operationId": "noSuchOperation"}],
  "live": ["where", {"operationId": "deleteNote"}],
  "stub": ["where", {"operationId": "renameNote"}],
  "second": ["where", {"operationId": "createProject"}],
  "classPath": ["where", {"operationId": "getStatus"}],
  "missing": ["where", {"operationId": "listNotes"}],
  "stubs": ["where", {"status": "stub"}],
  "tag": ["where", {"tag": "projects"}],
  "two": ["where", {"operationId": "deleteNote", "tag": "Notes"}],
  "nowhere": ["where", {"operationId": "noSuchOperation"}],
  "noSchema": ["schema", {"name": "nope"}],
  "noUse": ["usedBy", {"target": "nope.field"}]
}' >"$out" 2>"$work/err" || bad "the client runs" "$(head -c 300 "$work/err")"
check "it has five tools: search, read, where, schema and usedBy" '.tools==["read","schema","search","usedBy","where"]'
check "search finds the operation by its words, first" '.search.value[0].operationId=="deleteNote"'
check "a hit has the operationId, method, path, summary and verdict" '.search.value[0]|keys==["method","operationId","path","summary","verdict"]'
check "search answers at most ten" '.search.value|length<=10'
check "a query no operation shares a word with finds nothing" '.none.value==[]'
check "read answers the method and path" '.read.value.method=="DELETE" and (.read.value.path|startswith("/"))'
check "read answers the verdict of the readiness report" '.read.value.verdict=="describe"'
check "read answers the findings an agent must know" '[.read.value.findings[].rule]|sort==["alternative","blast-radius","reversibility"]'
check "read inlines every \$ref" '[.read.value|..|objects|select(has("$ref"))]|length==0'
check "an error answer keeps only its description" '[.read.value.responses|to_entries[]|select(.key|startswith("2")|not)|.value|keys==["description"]]|all'
check "read names the next call, where" '.read.value.next|contains("where")'
check "an unknown operationId is an error that points to search" '.unknown.isError and (.unknown.value|contains("search"))'

check "where: a live method names its interface method and line" '.live.value.interface|test("^NotesApi.deleteNote .*/NotesApi.java:[0-9]+$")'
check "where: the controller is the src/main class, never a src/test one" '.live.value.controller|test("^NotesController.deleteNote notes-adapter/src/main/.*NotesController.java:7$")'
check "where: a method with a real body is live" '.live.value.status=="live"'
check "where: without an index the chain comes from the conventions" '.live.value.via=="conventions"'
check "where: the calls are the use-case field and the mapper" '[.live.value.calls[]|split(" ")[0]]|sort==["DeleteNoteUseCase","NoteIdMapper"]'
check "where: the unit tests are found by the <Class>Test name" '.live.value.unitTests==["notes-usecase/src/test/java/app/fx/DeleteNoteUseCaseTest.java"]'
check "where: an HTTP test with a concatenated path parameter is found" '.live.value.httpTests==["application/src/test/java/app/fx/DeleteNoteResourceTest.java:4"]'
check "where: @DenyAll with only a throw is a stub" '.stub.value.status=="stub"'
check "where: a test that only names the operation is a mention, not an HTTP test" '.stub.value.httpTests==[] and .stub.value.mentions==["application/src/test/java/app/fx/RenameNoteDocTest.java:2"]'
check "where: a controller that implements two interfaces serves both" '.second.value.controller|startswith("NotesController.createProject ")'
check "where: an interface with only a class-level @Path is read" '.classPath.value.interface|test("^HealthApi.getStatus .*HealthApi.java:[0-9]+$")'
check "where: an operation no controller implements is none, with a hint" '.missing.value.status=="none" and .missing.value.controller==null and (.missing.value.hint|contains("NotesApi"))'
check "where: a status lists its operations, short form" '.stubs.value==[{"operationId":"renameNote","status":"stub","controller":"notes-adapter/src/main/java/app/fx/NotesController.java:13"}]'
check "where: a tag matches without case and lists all its operations" '(.tag.value|length)==6 and ([.tag.value[]|select(.operationId=="createProject")][0].status=="live")'
check "where: more than one selector is an error" '.two.isError'
check "where: an unknown operationId is an error that points to search" '.nowhere.isError and (.nowhere.value|contains("search"))'
check "where: an answer stays under 4,000 characters" '[.live,.stub,.second,.classPath,.missing|.size<4000]|all'
check "schema: an unknown name is an error that points to search" '.noSchema.isError and (.noSchema.value|contains("search"))'
check "usedBy: an unknown schema is an error" '.noUse.isError'

# cli.mjs, the shell fallback: for each command its stdout is the MCP tool's answer text, byte for byte, with the same
# exit code (0, or 1 for an isError answer); a wrong command or arguments exit 2, --help exits 0.
cli="$tool/cli.mjs"
CLAUDE_PROJECT_DIR="$work" CASES='[
  ["search", ["search","delete","a","note"], "search", {"query":"delete a note"}],
  ["search none", ["search","zzqx"], "search", {"query":"zzqx"}],
  ["read", ["read","deleteNote"], "read", {"operationId":"deleteNote"}],
  ["read unknown", ["read","noSuchOperation"], "read", {"operationId":"noSuchOperation"}],
  ["where id", ["where","deleteNote"], "where", {"operationId":"deleteNote"}],
  ["where unknown", ["where","noSuchOperation"], "where", {"operationId":"noSuchOperation"}],
  ["where tag", ["where","--tag","projects"], "where", {"tag":"projects"}],
  ["where status", ["where","--status","stub"], "where", {"status":"stub"}],
  ["schema unknown", ["schema","nope"], "schema", {"name":"nope"}],
  ["usedBy unknown", ["usedBy","nope.field"], "usedBy", {"target":"nope.field"}]
]' node --input-type=module -e "
  import { Client } from '$tool/node_modules/@modelcontextprotocol/sdk/dist/esm/client/index.js';
  import { StdioClientTransport } from '$tool/node_modules/@modelcontextprotocol/sdk/dist/esm/client/stdio.js';
  import { spawnSync } from 'node:child_process';
  const c = new Client({ name: 'test', version: '0' });
  await c.connect(new StdioClientTransport({ command: 'node', args: ['$tool/server.mjs'], env: { ...process.env } }));
  const out = {};
  for (const [k, argv, name, args] of JSON.parse(process.env.CASES)) {
    const r = await c.callTool({ name, arguments: args });
    const p = spawnSync('node', ['$cli', ...argv], { encoding: 'utf8', env: { ...process.env } });
    out[k] = { same: p.stdout === r.content[0].text + '\\n', exit: p.status, expected: r.isError ? 1 : 0 };
  }
  await c.close();
  console.log(JSON.stringify(out));" >"$out" 2>"$work/err" || bad "the cli comparison runs" "$(head -c 300 "$work/err")"
for k in $(jq -r 'keys[]|@base64' "$out" 2>/dev/null); do
  n="$(printf %s "$k" | base64 -d)"
  check "cli: $n prints the MCP answer and exits as it does" ".[\"$n\"]|.same and .exit==.expected"
done
check "cli: an error answer exits 1" '.["read unknown"].exit==1 and .["where unknown"].exit==1'
cli() { CLAUDE_PROJECT_DIR="$work" node "$cli" "$@" >"$work/cli.out" 2>"$work/cli.err"; echo $?; }
[ "$(cli --help)" = 0 ] && grep -q 'where --tag <tag>' "$work/cli.out" && grep -q 'Finds where an API operation lives' "$work/cli.out" \
  && ok "cli: --help exits 0 and lists each command with the tool's description" || bad "cli: --help"
[ "$(cli)" = 2 ] && grep -q '^Usage:' "$work/cli.err" && ok "cli: no arguments exit 2 with the usage" || bad "cli: no arguments"
[ "$(cli frobnicate)" = 2 ] && ok "cli: an unknown command exits 2" || bad "cli: unknown command"
[ "$(cli read)" = 2 ] && ok "cli: a missing argument exits 2" || bad "cli: missing argument"
[ "$(cli read a b)" = 2 ] && ok "cli: too many arguments exit 2" || bad "cli: too many arguments"
[ "$(cli where --status bogus)" = 2 ] && ok "cli: a bad status exits 2" || bad "cli: bad status"
[ "$(cli where --tag)" = 2 ] && ok "cli: a flag without its value exits 2" || bad "cli: flag without value"
mv "$work/build" "$work/build.off"
[ "$(cli read deleteNote)" = 1 ] && grep -q "contract-agent-readiness.sh" "$work/cli.err" && ok "cli: without the report it exits 1 and names the check" || bad "cli: without the report"
mv "$work/build.off" "$work/build"

# plan-ops.mjs, plan-context.sh's section: the operations a ticket names, by operationId or by METHOD and path, in
# the ticket's order, with where's facts and the readiness verdict.
printf 'Description:\nRename a note (renameNote), and keep DELETE /notes/{noteId} as it is. Not deleteNotes.\n' >"$work/ticket.md"
node "$tool/plan-ops.mjs" "$work/ticket.md" "$work" >"$work/ops.md" 2>"$work/err" || bad "plan-ops runs" "$(head -c 300 "$work/err")"
grep -q '^## Contract operations this ticket names$' "$work/ops.md" && ok "plan-ops: one section" || bad "plan-ops: one section" "$(head -c 300 "$work/ops.md")"
[ "$(grep -oE '^- \*\*[A-Za-z]+\*\*' "$work/ops.md" | tr -d '* -' | paste -sd,)" = "renameNote,deleteNote" ] \
  && ok "plan-ops: by id and by METHOD path, in the ticket's order, whole words only" || bad "plan-ops: the named operations" "$(grep '^- ' "$work/ops.md")"
grep -qE '^- \*\*deleteNote\*\* `DELETE /notes/\{noteId\}` \([A-Za-z]+\): live, verdict describe$' "$work/ops.md" \
  && ok "plan-ops: method, path, status and verdict" || bad "plan-ops: the deleteNote line" "$(grep deleteNote "$work/ops.md" | head -2)"
grep -qF '  - controller: `NotesController.deleteNote notes-adapter/src/main/' "$work/ops.md" && grep -qF 'DeleteNoteUseCaseTest.java' "$work/ops.md" \
  && ok "plan-ops: the controller and the unit tests" || bad "plan-ops: controller and tests" "$(head -c 600 "$work/ops.md")"
printf 'Nothing from the contract here.\n' >"$work/ticket.md"
[ -z "$(node "$tool/plan-ops.mjs" "$work/ticket.md" "$work")" ] && ok "plan-ops: a ticket that names no operation prints nothing" || bad "plan-ops: no operation"
node "$tool/plan-ops.mjs" "$work/ticket.md" "$work/nowhere" >/dev/null 2>&1; [ $? -eq 1 ] && ok "plan-ops: no contract exits 1" || bad "plan-ops: no contract"

# Without the generated sources the interface comes from the naming rule, and the answer says so; a pin that differs
# from the loaded contract is a note.
mv "$work/shared-adapter/build" "$work/generated.off"
printf '@@KIT_CONTRACT_TAG_KEY@@=v0.9.0\n' >"$work/gradle.properties"
client '{"rule": ["where", {"operationId": "getStatus"}]}' >"$out" 2>"$work/err" || bad "the client runs without generated sources" "$(head -c 300 "$work/err")"
check "where: without generated sources the interface is named by the rule" '.rule.value.interface=="HealthApi.getStatus (from the naming rule)"'
check "where: it says the generated sources are missing and how to make them" '[.rule.value.notes[]|select(contains("openApiGenerate"))]|length==1'
check "where: a pin that differs from the loaded contract is a note" '[.rule.value.notes[]|select(contains("v0.9.0"))]|length==1'
mv "$work/generated.off" "$work/shared-adapter/build"
rm "$work/gradle.properties"

# With a CodeGraph index the call chain comes from it, and the unit tests are the test files that call the callees.
if command -v codegraph >/dev/null 2>&1; then
  if (cd "$work" && codegraph init -y >/dev/null 2>&1); then
    client '{"cg": ["where", {"operationId": "deleteNote"}]}' >"$out" 2>"$work/err" || bad "the client runs on an index" "$(head -c 300 "$work/err")"
    check "where: with an index the chain comes from CodeGraph" '.cg.value.via=="codegraph"'
    check "where: CodeGraph names the called methods" '[.cg.value.calls[]|split(" ")[0]]|sort==["DeleteNoteUseCase.execute","NoteIdMapper.map"]'
    check "where: CodeGraph's unit tests are the test files that call them" '.cg.value.unitTests==["notes-usecase/src/test/java/app/fx/DeleteNoteUseCaseTest.java"]'
  else bad "codegraph init on the fixture tree"; fi
else echo "SKIP: no codegraph on PATH, the CodeGraph path of where is untested"; fi

# schema and usedBy, on a fixture spec with a cycle, an allOf and a oneOf with a discriminator.
graph() { # graph <spec> <root> <calls: answer name → [function, argument]>
  node --input-type=module -e "
    import { parse } from '$tool/node_modules/yaml/dist/index.js';
    import { readFileSync } from 'node:fs';
    import { schemaGraph } from '$tool/schema-graph.mjs';
    const g = schemaGraph(parse(readFileSync('$1', 'utf8')), '$2');
    const out = {};
    for (const [k, [fn, arg]] of Object.entries(JSON.parse(process.argv[1]))) out[k] = g[fn](arg);
    console.log(JSON.stringify(out));" "$3"
}
graph "$root/scripts/test/fixtures/contract-mcp/schemas.yaml" "$work" '{
  "folder": ["schema", "Folder"], "input": ["schema", "folderInput"], "shape": ["schema", "shape"], "id": ["schema", "id"],
  "nope": ["schema", "foldr"], "near": ["nearest", "foldr"],
  "uFolder": ["usedBy", "folder"], "uName": ["usedBy", "folder.name"], "uInput": ["usedBy", "folderInput.colour"],
  "uId": ["usedBy", "id"], "uCircle": ["usedBy", "circle.radius"], "uNoField": ["usedBy", "folder.nope"]
}' >"$out" 2>"$work/err" || bad "the schema graph runs" "$(head -c 300 "$work/err")"
check "schema: a name matches without case" '.folder.name=="folder"'
check "schema: allOf is flattened, each inherited field names its source" '.folder.properties.name.from=="named" and (.folder.properties.id|has("from")|not)'
check "schema: required gathers every allOf part" '(.folder.required|sort)==["id","name"]'
check "schema: a nested schema stays a name, also inside an array" '.folder.properties.parent=={"$ref":"folder"} and .folder.properties.children.items=={"$ref":"folder"}'
check "schema: constraints and the first sentence of a description are kept" '.folder.properties.name.maxLength==80 and .folder.properties.name.description=="What people call it."'
check "schema: enum, nullable and additionalProperties are kept" '.input.properties.colour.enum==["RED","BLUE"] and .input.properties.colour.nullable and .input.additionalProperties==false'
check "schema: oneOf shows each variant with the discriminator value that selects it" '.shape.oneOf==[{"$ref":"circle","when":"kind = round"},{"$ref":"square","when":"kind = SQUARE"}]'
check "schema: a scalar schema answers its type and format" '.id.type=="string" and .id.format=="uuid"'
check "schema: it names the generated Java model" '.folder.java.model|startswith("com.example.api.model.Folder ")'
check "schema: an unknown name answers nothing, and nearest names the closest three" '.nope==null and .near[0]=="folder" and (.near|length)==3'
check "usedBy: a schema in a cycle is found once per operation and direction" '[.uFolder.operations[]|.operationId+" "+.direction]|sort==["getFolder response","renameFolder response"]'
check "usedBy: a field of an allOf base names its owner, and is reached through every schema built on it" '(.uName.owner|contains("named")) and .uName.count.operations==2'
check "usedBy: a request field says whether it is required" '.uInput.operations==[{"operationId":"renameFolder","direction":"request","required":false,"route":"body > folderInput.colour"}]'
check "usedBy: a path parameter is a request route" '[.uId.operations[]|select(.direction=="request")|.route]|unique==["path folderId > id"]'
check "usedBy: a response route says its status" '[.uId.operations[]|select(.direction=="response")|.status]|unique==["200"]'
check "usedBy: a oneOf variant is reached through its parent" '.uCircle.operations[0].route=="body > shape > oneOf > circle.radius"'
check "usedBy: a field the schema lacks is an error that lists its fields" '(.uNoField.error|contains("nope")) and (.uNoField.fields|index("parent")!=null)'

# On the real tree: every operation of the pinned contract resolves, the generated interfaces agree with the spec on
# method and path, and one known field leads to its one operation. Skipped where the contract or the generated
# sources are not in the checkout.
if [ -f "$root/contract/dist/openapi.yaml" ] && [ -d "$root/$gen" ]; then
  node --input-type=module -e "
    import { parse } from '$tool/node_modules/yaml/dist/index.js';
    import { readFileSync } from 'node:fs';
    import { codeIndex, generatedMethods } from '$tool/code-index.mjs';
    import { schemaGraph } from '$tool/schema-graph.mjs';
    import { operations } from '$root/scripts/contract-agent-readiness/read.mjs';
    const spec = parse(readFileSync('$root/contract/dist/openapi.yaml', 'utf8'));
    const ops = operations(spec); const g = generatedMethods('$root');
    const list = codeIndex('$root', spec).list({});
    console.log(JSON.stringify({
      ops: ops.length, listed: list.length, statuses: list.every((l) => ['live', 'stub', 'none'].includes(l.status)),
      drift: ops.filter((o) => g.get(o.id)?.httpMethod !== o.method || g.get(o.id)?.path !== o.path).map((o) => o.id),
      email: schemaGraph(spec, '$root').usedBy('signInRequest.email').operations,
    }));" >"$out" 2>"$work/err" || bad "the real-tree check runs" "$(head -c 300 "$work/err")"
  check "real tree: every operation is listed once, as live, stub or none" '.ops==.listed and .statuses'
  check "real tree: the generated interfaces agree with the spec on method and path" '.drift==[]'
  check "real tree: signInRequest.email is a required request field of signIn only" '.email==[{"operationId":"signIn","direction":"request","required":true,"route":"body > signInRequest.email"}]'
else echo "SKIP: no contract or generated sources in this checkout, the real-tree checks are untested"; fi

# It stops, and says which command to run, when a file is missing or the report is of another contract.
starts() { CLAUDE_PROJECT_DIR="$work" timeout 5 node "$tool/server.mjs" </dev/null 2>&1; }
mv "$work/build" "$work/build.off"
msg="$(starts)"; rc=$?
if [ "$rc" -eq 1 ] && grep -q "contract-agent-readiness.sh" <<<"$msg"; then ok "without the report it stops and names the check"; else bad "without the report it stops and names the check" "exit $rc: $msg"; fi
mv "$work/build.off" "$work/build"
sed -i 's/^  version: .*/  version: 99.0.0/' "$work/contract/dist/openapi.yaml"
msg="$(starts)"; rc=$?
if [ "$rc" -eq 1 ] && grep -q "Run the readiness check again" <<<"$msg"; then ok "a report of another contract version stops it"; else bad "a report of another contract version stops it" "exit $rc: $msg"; fi

# .archon/kit.yaml: spec path, server name and project name come from it; KIT_* env wins; no file = today's values.
sed -i 's/^  version: 99.0.0/  version: 1.0.0/' "$work/contract/dist/openapi.yaml"
ver="$(sed -n 's/^  version: *//p' "$work/contract/dist/openapi.yaml" | head -n 1 | tr -d "\"' ")"
node -e "
  import('$tool/kit-config.mjs').then(({ kitConfig }) => {
    const d = kitConfig('$work', {});
    const k = kitConfig('$work', { KIT_CONTRACT_SERVER_NAME: 'from-env' });
    console.log([d('contract.spec_path'), d('contract.repo'), d('contract.tag_key'), d('contract.api_package'), d('project_name'), k('contract.server_name')].join(' '));
  });" > "$work/kit.out" 2>&1
if [ "$(cat "$work/kit.out")" = "contract/dist/openapi.yaml @@KIT_CONTRACT_REPO@@ @@KIT_CONTRACT_TAG_KEY@@ com.example.api app from-env" ]; then ok "kit-config: defaults without kit.yaml, env override wins"; else bad "kit-config defaults" "$(cat "$work/kit.out")"; fi
mkdir -p "$work/.archon" "$work/spec"
cp "$work/contract/dist/openapi.yaml" "$work/spec/api.yaml"
printf 'project_name: acme\ncontract:\n  server_name: acme-api\n  spec_path: spec/api.yaml\n' > "$work/.archon/kit.yaml"
mv "$work/contract" "$work/contract.off"
cat > "$work/kit-run.mjs" <<JS
import { Client } from '$tool/node_modules/@modelcontextprotocol/sdk/dist/esm/client/index.js';
import { StdioClientTransport } from '$tool/node_modules/@modelcontextprotocol/sdk/dist/esm/client/stdio.js';
const c = new Client({ name: 'test', version: '0' });
await c.connect(new StdioClientTransport({ command: 'node', args: ['$tool/server.mjs'], env: { ...process.env, CLAUDE_PROJECT_DIR: '$work' } }));
const tools = (await c.listTools()).tools;
console.log(c.getServerVersion().name + '|' + c.getInstructions().includes('acme API contract') + '|' + tools.find((t) => t.name === 'search').description.includes('acme API operations'));
await c.close();
JS
node "$work/kit-run.mjs" > "$work/kit.out" 2>&1
if [ "$(cat "$work/kit.out")" = "acme-api|true|true" ]; then ok "kit.yaml: server name, project name and spec_path drive the server"; else bad "kit.yaml drives the server" "$(cat "$work/kit.out")"; fi
# an absolute contract.spec_path: a contract outside the project, loaded as it is (path.resolve, not joined to the root)
ext="$(mktemp -d)"; cp "$work/spec/api.yaml" "$ext/outside-api.yaml"
printf 'project_name: acme\ncontract:\n  server_name: acme-api\n  spec_path: %s/outside-api.yaml\n' "$ext" > "$work/.archon/kit.yaml"
rm -rf "$work/spec"
node "$work/kit-run.mjs" > "$work/kit.out" 2>&1
if [ "$(cat "$work/kit.out")" = "acme-api|true|true" ]; then ok "kit.yaml: an absolute spec_path outside the project is loaded as it is"; else bad "an absolute spec_path" "$(cat "$work/kit.out")"; fi
rm -rf "$ext" "$work/.archon" "$work/spec"; mv "$work/contract.off" "$work/contract"

echo "contract-mcp tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
