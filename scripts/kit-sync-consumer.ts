/**
 * Fixes found by installing the kit into a consumer repo (fork PR #12 and its follow-ups): what the source does that
 * breaks or misleads in another project. Each rewrite is [from, to, count] on the source file before conversion, like
 * TARGETED; a count that does not fit fails the sync, so a source change under an anchor is seen at the next sync.
 * No project noun goes in here (P3): the text names the kit's own paths and mechanisms only.
 */
import type { Rewrite } from './kit-sync-lists';

/** The planner's convention line: the templates the code-map leaves link, not every file under scaffold-templates/. */
const PLANNER_TEMPLATES: Rewrite = [
  '      The templates under docs/scaffold-templates/ and the docs/code-maps leaves of those skills are the conventions.\n',
  "      The templates the `## Scaffold` tables of those skills' docs/code-maps leaves link, and those leaves, are the\n" +
    "      conventions: a repo's own templates live in docs/scaffold-templates/project/; the kit's, one level up, are worked\n" +
    '      examples that no leaf links.\n',
  1,
];

export const CONSUMER_TARGETED: Record<string, Rewrite[]> = {
  // The agents take the repo's own templates first (targets.js: docs/scaffold-templates/project/).
  '.claude/agents/developer.md': [
    [
      'it names the templates whose\n  `## Scaffold` Target fits and prints the render command,',
      "it names the templates whose\n  `## Scaffold` Target fits (the repo's own under docs/scaffold-templates/project/ included, and preferred) and\n  prints the render command,",
      1,
    ],
  ],
  '.claude/agents/test-writer.md': [
    [
      '  templates whose `## Scaffold` Target fits and prints the render command,\n',
      "  templates whose `## Scaffold` Target fits (the repo's own under docs/scaffold-templates/project/ included, and\n  preferred) and prints the render command,\n",
      1,
    ],
  ],
  '.archon/workflows/build-feature.yaml': [PLANNER_TEMPLATES],
  '.archon/workflows/build-feature-copilot.yaml': [PLANNER_TEMPLATES],
  // A memory.md that groups its entries under `## Decisions` writes them as `### <date> — …`.
  '.claude/scripts/gate-change-check.sh': [
    [
      '# A decision entry: the change adds to docs/memory.md a dated heading `## <yyyy-mm-dd> — …`, and the lines it adds there\n',
      '# A decision entry: the change adds to docs/memory.md a dated heading `## <yyyy-mm-dd> — …` (or `### <yyyy-mm-dd> — …`,\n' +
        '# the entry level of a memory.md that groups its entries under `## Decisions`), and the lines it adds there\n',
      1,
    ],
    [
      'if ! grep -qE \'^## [0-9]{4}-[0-9]{2}-[0-9]{2} \' <<< "$added"; then\n',
      'if ! grep -qE \'^###? [0-9]{4}-[0-9]{2}-[0-9]{2} \' <<< "$added"; then\n',
      1,
    ],
    [
      "(a dated '## <yyyy-mm-dd> — …' heading) to $memory\"",
      "(a dated '## <yyyy-mm-dd> — …' or '### <yyyy-mm-dd> — …' heading) to $memory\"",
      1,
    ],
  ],
  'scripts/test/gate-change-check.test.sh': [
    [
      'check "2 a bullet without a dated heading is no entry" "$([ "$rc" -eq 1 ] && said \'adds no decision entry\'; echo $?)"\n',
      'check "2 a bullet without a dated heading is no entry" "$([ "$rc" -eq 1 ] && said \'adds no decision entry\'; echo $?)"\n' +
        "new_repo; sed -i 's/lint check/lint check --strict/' .github/workflows/ci.yml\n" +
        "printf '\\n## Decisions\\n\\n### 2026-10-21 — the lint step is stricter\\n- ci.yml: the lint step\\n' >> docs/memory.md; commit; run main\n" +
        'check "2 a ### entry under a ## Decisions section counts" "$([ "$rc" -eq 0 ] && said \'gate-change-check: ok\'; echo $?)"\n' +
        "new_repo; sed -i 's/lint check/lint check --strict/' .github/workflows/ci.yml\n" +
        "printf '\\n#### 2026-10-21 — too deep\\n- ci.yml: the lint step\\n' >> docs/memory.md; commit; run main\n" +
        'check "2 a #### heading is no entry" "$([ "$rc" -eq 1 ] && said \'adds no decision entry\'; echo $?)"\n',
      1,
    ],
    // The fixture's second job is a neutral lint job: the source names its Groma job, which the kit does not ship.
    ['  groma:\n', '  lint:\n', 1],
    ['      - run: groma check\n', '      - run: lint check\n', 1],
    [
      "sed -i 's/groma check/groma check --strict/'",
      "sed -i 's/lint check/lint check --strict/'",
      2,
    ],
    ['the groma step is stricter', 'the lint step is stricter', 2],
    // The new job of a case: the source's image job does not ship.
    [
      "printf '  image:\\n    steps:\\n      - run: docker build .\\n'",
      "printf '  extra:\\n    steps:\\n      - run: echo extra\\n'",
      1,
    ],
    ['entry "ci.yml gets the image job"', 'entry "ci.yml gets the extra job"', 1],
  ],
  // A neutral second job in the fixtures: the source's Groma and mutation jobs do not ship.
  '.archon/scripts/test/red-triage.test.sh': [
    ['groma', 'lint', 4],
    ['Mutation score 60% < 80%', '3 lint problems', 1],
    ['mutation', 'lint', 4],
  ],
  // The output is source code: the mustache CLI HTML-escapes `{{x}}` (/ " & become &#x2F; &quot; &amp;).
  'scripts/scaffold.sh': [
    [
      '# mustache@4.2.0, pinned with its integrity hash in scripts/scaffold/package-lock.json; npm ci installs it on first use.\n',
      '# mustache@4.2.0, pinned with its integrity hash in scripts/scaffold/package-lock.json; npm ci installs it on first use.\n' +
        '# Rendered without HTML escaping: the output is source code, so `{{x}}` writes "/", quotes and "&" as given (the\n' +
        '# mustache CLI would write &#x2F;, &quot; and &amp;).\n',
      1,
    ],
    [
      'out="$(node "$renderer" "$vars" "$template")"\n',
      'out="$(node -e \'const m = require(process.argv[1]); const fs = require("fs"); m.escape = String;\n' +
        '  process.stdout.write(m.render(fs.readFileSync(process.argv[3], "utf8"), JSON.parse(fs.readFileSync(process.argv[2], "utf8"))));\' \\\n' +
        '  "$TOOL_DIR/node_modules/mustache" "$vars" "$template")"\n',
      1,
    ],
  ],
  'docs/code-maps/README.md': [
    [
      "leaf's `## Scaffold` section lists its own).\n\n",
      "leaf's `## Scaffold` section lists its own).\n\n" +
        "The kit's templates are worked examples too: their names and types come from the reference set, so their output rarely\n" +
        'compiles as is in another repo, and the kit owns them (`.archon/kit.lock.json`), so an update overwrites a local fix.\n' +
        "Put the repo's own templates in `docs/scaffold-templates/project/<layer>/<name>.mustache` instead: the kit never removes\n" +
        'a file there and only a project profile of the repo ships one (kept once edited), and\n' +
        '`scripts/scaffold.sh project/<layer>/<name> ...` renders it. `--for`, the\n' +
        'scaffold step and the scaffold-check gate (all through `scripts/scaffold/targets.js`) take them up without an edit to a\n' +
        "kit-owned leaf: a repo template with a kit template's name (`project/domain/id` beside `domain/id`) takes over that\n" +
        "template's rows, and a new one is offered from the `## Scaffold` table of `docs/scaffold-templates/project/README.md`,\n" +
        "a table like a leaf's whose links are relative to that folder. Prefer the repo's template where both fit. Keep a\n" +
        'working `<name>.example.json` next to each, so a script can render every template and compile the result.\n\n',
      1,
    ],
  ],
};
