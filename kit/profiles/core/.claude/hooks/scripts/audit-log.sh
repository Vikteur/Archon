#!/usr/bin/env bash
# audit-log.sh — append one Claude Code lifecycle event to the per-session audit trail (JSONL).
#
# This is the "harness load log" leg of the audit trail (see .claude/hooks/README.md): every
# session/tool/subagent event lands in .apm-audit/sessions/<sessionId>.jsonl. Three tiers of
# skill/instruction/doc observation feed the per-agent report (scripts/audit-report.sh) — docs
# (DOC_SEEN/DOC_LOAD, any docs/**.md; SCOPE lists the docs/code-maps tree) answer whether the
# code-maps a skill points at are actually read:
#
#   SCOPE              (sessionStart)  what was AVAILABLE — the deployed .claude/skills/ dirs +
#                                      .claude/rules/ files present in this checkout
#   *_SEEN             (postToolUse)   what was DISCOVERED — a skill/instruction path that only
#                                      appeared in a tool RESULT (ls / grep / file-search output
#                                      scrolled past the agent) without being opened by that call
#   *_LOAD             (postToolUse)   what was READ & USED — the path appears in the tool ARGS
#                                      (an explicit view/cat of the body), stamped with the
#                                      file's last-touch commit + dirty flag at that moment
#
# Usage (wired via observability.json; the CLI runs it with cwd=.claude/hooks):
#   ./scripts/audit-log.sh <event>       # event: sessionStart|userPrompt|postToolUse|
#                                        #        postToolUseFailure|subagentStart|subagentStop|
#                                        #        sessionEnd
#
# Contract (Claude Code hooks; <event> keeps the original camelCase names — see settings.json):
#   stdin  : JSON payload — session_id, cwd, hook_event_name, plus per event: tool_name/tool_input/
#            tool_response (PostToolUse*), agent_type (inside a subagent, and on SubagentStart/Stop),
#            prompt (UserPromptSubmit), reason (SessionEnd). Copilot camelCase still tolerated.
#   stdout : nothing the model needs — observability only.
#   exit 0 : ALWAYS. This hook must never block or delay work, so there is no `set -e` and
#            every step is defensive; a broken logger degrades to silence, not denial.
#            (Logging deliberately hangs off postToolUse, not fail-closed preToolUse.)
#
# jq is optional but recommended: without it the args/result split is impossible, so the raw
# scan counts every path mention as a LOAD (discovery folds into usage — degraded but joinable).
#
# Speed: the CLI waits for this hook on every tool call, and on Git Bash every forked process costs tens of
# milliseconds. So the payload is read by ONE jq call (every field, and the skill/instruction/doc/persona names of the
# tool args and result), strings are escaped in bash itself, and records are built without command substitutions.
# A slow logger was costing a build-feature run ~8 minutes (1.7 s per tool call, 7 s per session start).
# The payload is read by the read builtin, the repo root and HEAD are read from .git without git, and a file's
# last-touch commit is looked up once per HEAD (see stamp). Every record is the same as before, field for field.
set -uo pipefail

event="${1:-unknown}"
# The read builtin, not $(cat): no fork. It keeps trailing newlines that $(cat) dropped, which jq and grep ignore.
IFS= read -r -d '' payload 2>/dev/null || true

# Repo root: hooks run with cwd=.claude/hooks. The nearest directory holding .git (a directory, or a worktree's file) is
# what `git rev-parse --show-toplevel` answers, found without a fork; git itself only when GIT_DIR or GIT_WORK_TREE
# could make it answer differently. Fall back to ../..
root=""
if [ -z "${GIT_DIR:-}${GIT_WORK_TREE:-}" ]; then
  d="$PWD"
  while [ -n "$d" ]; do
    if [ -e "$d/.git" ]; then root="$d"; break; fi
    [ "${d%/*}" != "$d" ] || break
    d="${d%/*}"
  done
else
  root="$(git rev-parse --show-toplevel 2>/dev/null)" || root=""
fi
[ -n "$root" ] || root="$(cd ../.. 2>/dev/null && pwd)" || root="$PWD"

have_jq=0; command -v jq >/dev/null 2>&1 && have_jq=1

# The one jq pass. It prints shell assignments (@sh-quoted), so `eval` only ever sets these variables. The name lists
# are the same regexes the old per-field grep/sed pipelines used, with "seen" already minus "loaded" in the same call.
# A failing jq (garbled payload) leaves every field empty, as each separate call did before.
session="" ts="" tool="" agent_evt="" f_cwd="" f_prompt="" f_transcript="" f_stop="" f_reason="" arg_full="" arg_path=""
sk_load="" sk_seen="" in_load="" in_seen="" doc_load="" doc_seen="" personas=""
if [ "$have_jq" = 1 ]; then
  fields="$(jq -r --arg ev "$event" '
    def s(f): (try f catch null) // "" | if type == "string" then . else tostring end;
    def skills: [scan("skills[\\\\/]+([A-Za-z0-9_-]+)[\\\\/]+SKILL\\.md") | .[0]] | unique;
    def instrs: [scan("rules[\\\\/]+[A-Za-z0-9._-]+\\.md|instructions[\\\\/]+[A-Za-z0-9._-]+\\.instructions\\.md")
                 | sub("^(rules|instructions)[\\\\/]+"; "")] | unique;
    def docs: gsub("\\\\\\\\"; "/") | gsub("\\\\[ntrbf]"; " ")
              | [scan("docs/[A-Za-z0-9._/-]+\\.md") | gsub("//+"; "/")] | unique;
    def lines: join("\n");
    . as $p
    | (if ($ev == "postToolUse" or $ev == "postToolUseFailure") then
         (($p.tool_input // $p.toolArgs // {}) | tostring) as $args
         | (($p.tool_response // $p.toolResult // $p.tool_result // {}) | tostring) as $res
         | {sk_load: ($args | skills), sk_seen: (($res | skills) - ($args | skills)),
            in_load: ($args | instrs), in_seen: (($res | instrs) - ($args | instrs)),
            doc_load: ($args | docs), doc_seen: (($res | docs) - ($args | docs)),
            personas: ([$args | scan("agents[\\\\/]+([A-Za-z0-9_-]+)(?:\\.agent)?\\.md") | .[0]] | unique),
            arg_full: s(($p.tool_input // $p.toolArgs // {}) as $a
                        | $a.command // $a.file_path // $a.notebook_path // $a.path // $a.pattern // ($a | tostring)),
            arg_path: s(($p.tool_input // $p.toolArgs // {}) as $a
                        | if $a.command == null and ($a.file_path // $a.notebook_path // $a.path) != null
                          then "1" else "" end)}
       else {} end) as $tool
    | {session: s($p.sessionId // $p.session_id), ts: s($p.timestamp), tool: s($p.toolName // $p.tool_name),
       agent_evt: s($p.agent_type // $p.agentName // $p.agent_name), f_cwd: s($p.cwd), f_prompt: s($p.prompt),
       f_transcript: s($p.transcriptPath // $p.transcript_path), f_stop: s($p.stopReason // $p.stop_reason),
       f_reason: s($p.reason)} + ($tool | with_entries(if (.value | type) == "array" then .value |= lines else . end))
    | to_entries[] | "\(.key)=\(.value | @sh)"' <<< "$payload" 2>/dev/null)" && eval "$fields"
fi

[ -n "$session" ] || session="${CLAUDE_AUDIT_SESSION:-${COPILOT_AUDIT_SESSION:-unknown}}"
# Launcher-provided role/ticket/prompt capture: CLAUDE_* names; COPILOT_* still honoured.
audit_role="${CLAUDE_AUDIT_ROLE:-${COPILOT_AUDIT_ROLE:-}}"
audit_ticket="${CLAUDE_AUDIT_TICKET:-${COPILOT_AUDIT_TICKET:-}}"
audit_prompts="${CLAUDE_AUDIT_PROMPTS:-${COPILOT_AUDIT_PROMPTS:-}}"

# Byte-wise string work runs in the C locale, as tr and cut did.
clean_session() {  # session id becomes a filename — keep it path-safe even if the payload is hostile/garbled
  local LC_ALL=C
  session="${session//[^A-Za-z0-9._-]/}"; session="${session:0:64}"
}
clean_session
[ -n "$session" ] || session="unknown"

# %(...)T is a bash builtin (no `date` fork); TZ=UTC0 makes it UTC.
TZ=UTC0 printf -v logged_at '%(%Y-%m-%dT%H:%M:%SZ)T' -1 2>/dev/null || logged_at=""

dir="$root/.apm-audit"
if [ ! -d "$dir/sessions" ] || [ ! -d "$dir/state" ]; then mkdir -p "$dir/sessions" "$dir/state" 2>/dev/null || exit 0; fi
log="$dir/sessions/${session}.jsonl"
stack="$dir/state/${session}.agents"

# --- agent attribution -------------------------------------------------------------------
# preToolUse/postToolUse carry no agent identity, so track it: subagentStart pushes the
# agentName on a per-session stack, subagentStop pops it. Between those, the acting agent is
# the top of the stack; outside any subagent it is the role the launcher exported
# (CLAUDE_AUDIT_ROLE, set by scripts/run-role.sh) or "main". Parallel subagents in one
# session would interleave here — the raw AGENT_START/STOP records keep that visible.
case "$event" in
  subagentStart) [ -n "$agent_evt" ] && printf '%s\n' "$agent_evt" >> "$stack" 2>/dev/null ;;
  subagentStop)  [ -s "$stack" ] && sed -i '$d' "$stack" 2>/dev/null ;;
esac
agent=""
if [ -s "$stack" ]; then
  while IFS= read -r line || [ -n "$line" ]; do agent="$line"; done < "$stack" 2>/dev/null
fi
# Claude Code stamps agent_type on every event fired inside a subagent: on a tool event it is
# authoritative and beats the stack (which parallel subagents interleave).
case "$event" in postToolUse|postToolUseFailure) [ -n "$agent_evt" ] && agent="$agent_evt" ;; esac
[ -n "$agent" ] || agent="${audit_role:-main}"

esc() {  # esc <text> — sets ESC to the JSON-string-escaped text (control chars stripped, then \ and ")
  local LC_ALL=C s="$1" bs='\' q='"'
  s="${s//[$'\001'-$'\037']/}"; s="${s//"$bs"/"$bs$bs"}"; ESC="${s//"$q"/"$bs$q"}"
}

emit() {  # emit <type> [s:<key> <string> | r:<key> <raw json>]... — append one record
  local type="$1" out k; shift
  esc "$session"; out="{\"type\":\"$type\",\"event\":\"$event\",\"session\":\"$ESC\""
  esc "$agent"; out="$out,\"agent\":\"$ESC\""
  esc "$ts"; out="$out,\"ts\":\"$ESC\",\"loggedAt\":\"$logged_at\""
  while [ $# -ge 2 ]; do
    k="${1#?:}"
    case "$1" in
      s:*) esc "$2"; out="$out,\"$k\":\"$ESC\"" ;;
      r:*) out="$out,\"$k\":$2" ;;
    esac
    shift 2
  done
  printf '%s}\n' "$out" >> "$log" 2>/dev/null
}

json_arr() {  # json_arr [name...] — sets ARR to a JSON array of escaped strings
  local out="" n
  for n in "$@"; do esc "$n"; out="${out:+$out,}\"$ESC\""; done
  ARR="[$out]"
}

cut_at() {  # cut_at <text> <bytes> — sets CUTS to at most <bytes> bytes of text, never splitting a UTF-8 character
  local LC_ALL=C s="$1" n="$2"
  if [ "${#s}" -le "$n" ]; then CUTS="$s"; return; fi
  while [ "$n" -gt 0 ] && [[ "${s:n:1}" == [$'\x80'-$'\xbf'] ]]; do n=$((n - 1)); done
  CUTS="${s:0:n}"; CUT="true"
}

trunc_lines() {  # trunc_lines <text> <bytes> — sets TRUNC to the first <bytes> bytes of every line (carriage returns
  # dropped), and CUT to true when a line was longer
  local LC_ALL=C out="" line rest="${1//$'\r'/}" max="${2:-200}"
  CUT="false"
  while :; do
    line="${rest%%$'\n'*}"; cut_at "$line" "$max"; out="$out$CUTS"
    [ "$line" = "$rest" ] && break
    out="$out"$'\n'; rest="${rest#*$'\n'}"
  done
  TRUNC="${out%"${out##*[!$'\n']}"}"
}

esc_lines() {  # esc_lines <text> — as esc, but line breaks and tabs stay, as \n and \t
  local LC_ALL=C s="$1" bs='\' q='"'
  s="${s//"$bs"/"$bs$bs"}"; s="${s//"$q"/"$bs$q"}"
  s="${s//$'\n'/"${bs}n"}"; s="${s//$'\t'/"${bs}t"}"
  ESC="${s//[$'\001'-$'\037']/}"
}

read_line() {  # read_line <file> — sets LINE to the file's first line, without a fork; fails when it is unreadable
  LINE=""; [ -f "$1" ] || return 1
  IFS= read -r LINE < "$1" 2>/dev/null || [ -n "$LINE" ]
}

head_sha() {  # sets HEAD_SHA to the full commit HEAD points at, read from .git without a fork (git when that fails)
  [ -z "${HEAD_SHA:-}" ] || return 0
  local gd="$root/.git" common r sha="" ref
  if [ -f "$gd" ] && read_line "$gd"; then
    gd="${LINE#gitdir: }"; case "$gd" in /*|[A-Za-z]:*) ;; *) gd="$root/$gd" ;; esac
  fi
  common="$gd"
  if read_line "$gd/commondir"; then case "$LINE" in /*|[A-Za-z]:*) common="$LINE" ;; *) common="$gd/$LINE" ;; esac; fi
  if read_line "$gd/HEAD"; then
    case "$LINE" in
      "ref: "*)
        ref="${LINE#ref: }"
        if read_line "$common/$ref"; then sha="$LINE"
        elif [ -f "$common/packed-refs" ]; then
          while IFS= read -r r; do [ "${r#* }" = "$ref" ] && { sha="${r%% *}"; break; }; done < "$common/packed-refs"
        fi ;;
      *) sha="$LINE" ;;
    esac
  fi
  case "$sha" in *[!0-9a-f]*|"") sha="" ;; esac
  [ ${#sha} -eq 40 ] || [ ${#sha} -eq 64 ] || sha="$(git -C "$root" rev-parse HEAD 2>/dev/null)"
  HEAD_SHA="${sha:-none}"
}

# A file's last-touch commit depends only on HEAD, so it is kept per session and HEAD in state/<session>.stamps
# (HEAD <tab> path <tab> commit), and `git log` runs once per file and HEAD instead of on every load. The dirty flag
# depends on the work tree at that moment, so `git diff` still runs on every load.
stamps="$dir/state/${session}.stamps"
stamp() {  # stamp <repo-relative-path> — set commit= last-touch short sha, dirty= true/false
  commit=""; dirty="false"
  if [ -f "$root/$1" ]; then
    local h p c hit=0
    head_sha
    if [ "$HEAD_SHA" != none ] && [ -f "$stamps" ]; then
      while IFS=$'\t' read -r h p c; do
        if [ "$h" = "$HEAD_SHA" ] && [ "$p" = "$1" ]; then commit="$c"; hit=1; break; fi
      done < "$stamps"
    fi
    if [ "$hit" = 0 ]; then
      if commit="$(git -C "$root" log -1 --format=%h -- "$1" 2>/dev/null)" && [ "$HEAD_SHA" != none ]; then
        printf '%s\t%s\t%s\n' "$HEAD_SHA" "$1" "$commit" >> "$stamps" 2>/dev/null
      fi
    fi
    git -C "$root" diff --quiet -- "$1" 2>/dev/null || dirty="true"
  fi
}

# Without jq the args/result split is impossible: scan the raw payload and count every mention as a LOAD (degraded
# mode, as before). These pipelines run only then.
if [ "$have_jq" = 0 ]; then
  sk_load="$(printf '%s' "$payload" | grep -oE 'skills[\\/]+[A-Za-z0-9_-]+[\\/]+SKILL\.md' 2>/dev/null \
    | sed -E 's#skills[\\/]+([A-Za-z0-9_-]+)[\\/]+SKILL\.md#\1#' | sort -u || true)"
  in_load="$(printf '%s' "$payload" \
    | grep -oE '(rules[\\/]+[A-Za-z0-9._-]+\.md|instructions[\\/]+[A-Za-z0-9._-]+\.instructions\.md)' 2>/dev/null \
    | sed -E 's#^(rules|instructions)[\\/]+##' | sort -u || true)"
  doc_load="$(printf '%s' "$payload" | sed -e 's#\\\\#/#g' -e 's#\\[ntrbf]# #g' \
    | grep -oE 'docs/[A-Za-z0-9._/-]+\.md' 2>/dev/null | sed -E 's#//+#/#g' | sort -u || true)"
  personas="$(printf '%s' "$payload" | grep -oE 'agents[\\/]+[A-Za-z0-9_-]+(\.agent)?\.md' 2>/dev/null \
    | sed -E 's#agents[\\/]+([A-Za-z0-9_-]+)(\.agent)?\.md#\1#' | sort -u || true)"
fi

case "$event" in
  sessionStart)
    # Join keys for the report: the commit the session ran on + the deployed-set lockfile stamp.
    head_sha="$(git -C "$root" rev-parse --short HEAD 2>/dev/null || echo '')"
    branch="$(git -C "$root" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '')"
    lock_at=""
    if [ -f "$root/apm.lock.yaml" ]; then
      lock_at="$(sed -n "s/^generated_at: *'\{0,1\}\([^']*\)'\{0,1\}$/\1/p" "$root/apm.lock.yaml" 2>/dev/null | head -n1)"
    fi

    # TICKET — the join key everything else hangs off. It used to come only from
    # COPILOT_AUDIT_TICKET, which only scripts/run-role.sh sets, so a session started with a bare
    # `copilot` recorded "" and became unqueryable: the audit found ALL EIGHT SESSION_START records
    # carrying an empty ticket, and `audit-report.sh --ticket PROJ-1406` returning "no sessions match"
    # against files that mention PROJ-1406 seven times. The trail was complete and useless.
    #
    # The branch name already encodes it and is already read one line above, so derive it when the
    # env var is absent: feature/PROJ-1406-mask-id-in-logs, PROJ-1406/part-domain, bugfix/proj-99 all
    # yield the id. Explicit env always wins — a deliberate --ticket must be able to override a
    # branch that says otherwise (a hotfix cut from the wrong branch, a worktree reused).
    ticket="$audit_ticket"
    ticket_src="env"
    if [ -z "$ticket" ] && [ -n "$branch" ]; then
      ticket="$(printf '%s' "$branch" | grep -oiE '[A-Z][A-Z0-9]+-[0-9]+' | head -n1 | tr '[:lower:]' '[:upper:]' || true)"
      [ -n "$ticket" ] && ticket_src="branch"
    fi
    [ -n "$ticket" ] || ticket_src="none"

    # ENTRYPOINT — how the session was launched. Without this an unattributed session is
    # indistinguishable from one legitimately running as "main", so "429 of 431 records say
    # agent:main" cannot be read as either a tooling gap or a real fact. Recording it makes the
    # difference visible instead of inferred: "raw" means nobody set a role, and any per-role
    # analysis of that session is measuring nothing.
    entrypoint="raw"; [ -n "$audit_role" ] && entrypoint="run-role"

    emit "SESSION_START" s:role "$audit_role" s:ticket "$ticket" s:ticketSource "$ticket_src" \
      s:entrypoint "$entrypoint" s:headSha "$head_sha" s:branch "$branch" s:lockGeneratedAt "$lock_at" s:cwd "$f_cwd"

    # SCOPE: what this checkout (repo or pruned part worktree) actually offers the session —
    # the deployed skill set + the instruction files. This becomes the "scoped into the
    # worktree" column of the per-agent report.
    sk=(); in_=()
    if [ -d "$root/.claude/skills" ]; then
      while IFS= read -r d; do [ -n "$d" ] && sk+=("$d"); done \
        < <(ls -1 "$root/.claude/skills" 2>/dev/null | sort)
    fi
    for f in "$root/.claude/rules"/*.md; do
      [ -f "$f" ] && in_+=("${f##*/}")
    done
    # docs denominator: the code-maps tree only — the framework-owned docs whose usage the
    # report should account for. Other docs/ reads still log as DOC_LOAD/SEEN, just unscoped.
    dm=()
    if [ -d "$root/docs/code-maps" ]; then
      while IFS= read -r f; do [ -n "$f" ] && dm+=("$f"); done \
        < <(cd "$root" && find docs/code-maps -name '*.md' 2>/dev/null | tr '\\' '/' | sort)
    fi
    json_arr ${sk[@]+"${sk[@]}"}; a_sk="$ARR"
    json_arr ${in_[@]+"${in_[@]}"}; a_in="$ARR"
    json_arr ${dm[@]+"${dm[@]}"}; a_dm="$ARR"
    emit "SCOPE" r:skills "$a_sk" r:instructions "$a_in" r:docs "$a_dm"
    ;;
  userPrompt)
    # PROMPT TEXT IS NOT STORED BY DEFAULT.
    #
    # This trail lives in a regulated repo, and a prompt is the least predictable field in it: it
    # is whatever the operator typed, which in practice has included personal identifiers,
    # ticket context, pasted logs and credential hints ("try it with my keyring"). Storing that
    # verbatim on disk turns an observability file into a data-protection surface — one careless
    # `git add -A` publishes it, and unlike every other field here it can never be justified as
    # necessary, because nothing consumes it: scripts/audit-report.sh does not read `prompt` at all.
    #
    # What the report DOES need from this event is a join key and a way to tell two sessions apart.
    # A truncated SHA-256 gives both — identical prompts collide by design, which is the useful
    # property — without keeping the content. Length is kept because "was this the one-liner or the
    # 4KB paste" is the question a reconstruction actually asks.
    #
    # CLAUDE_AUDIT_PROMPTS=raw restores the old behaviour for a debugging session. It is an env var
    # on the launching process, deliberately not a hooks.env key: opting into storing user text
    # should be a per-session act by a human, not a setting a repo drifts into and forgets.
    raw="$f_prompt"
    chars="$(printf '%s' "$raw" | wc -m 2>/dev/null | tr -cd '0-9')"; chars="${chars:-0}"
    sha=""
    if command -v sha256sum >/dev/null 2>&1; then
      sha="$(printf '%s' "$raw" | sha256sum 2>/dev/null | cut -c1-16)"
    elif command -v shasum >/dev/null 2>&1; then
      sha="$(printf '%s' "$raw" | shasum -a 256 2>/dev/null | cut -c1-16)"
    fi
    if [ "$audit_prompts" = "raw" ]; then
      emit "PROMPT" s:capture "raw" r:promptChars "$chars" s:promptSha "$sha" s:prompt "$(printf '%s' "$raw" | cut -c1-200)"
    else
      emit "PROMPT" s:capture "redacted" r:promptChars "$chars" s:promptSha "$sha"
    fi
    ;;
  subagentStart)
    emit "AGENT_START" s:agentName "$agent_evt" s:transcript "$f_transcript"
    # SKILL_PRELOAD: Claude Code puts the skills an agent's frontmatter lists (`skills:`, a block or an inline [a, b]
    # list) in its context at its start, with no Skill call, so no TOOL record shows them. Record each one as the file
    # says now, flagged found:false when the checkout has no such skill (a misspelled preload loads nothing).
    preloads=()
    af="$root/.claude/agents/${agent_evt//[^A-Za-z0-9_-]/}.md"
    if [ -n "${agent_evt//[^A-Za-z0-9_-]/}" ] && [ -f "$af" ]; then
      fm=0; in_list=0
      while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        if [ "$line" = "---" ]; then [ "$fm" = 1 ] && break; fm=1; continue; fi
        [ "$fm" = 1 ] || break
        if [ "$in_list" = 1 ]; then
          if [[ "$line" =~ ^[[:space:]]*-[[:space:]]+(.*)$ ]]; then preloads+=("${BASH_REMATCH[1]}"); continue; fi
          in_list=0
        fi
        if [[ "$line" =~ ^skills:[[:space:]]*\[(.*)\][[:space:]]*$ ]]; then
          IFS=',' read -r -a items <<< "${BASH_REMATCH[1]}"
          preloads+=(${items[@]+"${items[@]}"})
        elif [[ "$line" =~ ^skills:[[:space:]]*$ ]]; then
          in_list=1
        fi
      done < "$af"
    fi
    for skill in ${preloads[@]+"${preloads[@]}"}; do
      skill="${skill#"${skill%%[![:space:]]*}"}"; skill="${skill%"${skill##*[![:space:]]}"}"
      skill="${skill#[\"\']}"; skill="${skill%[\"\']}"
      [ -n "$skill" ] || continue
      found="false"
      [ -f "$root/.claude/skills/${skill##*:}/SKILL.md" ] || [ -f "$root/skills/${skill##*:}/SKILL.md" ] && found="true"
      emit "SKILL_PRELOAD" s:agentName "$agent_evt" s:skill "$skill" r:found "$found"
    done
    ;;
  subagentStop)
    emit "AGENT_STOP" s:agentName "$agent_evt" s:stopReason "$f_stop"
    ;;
  sessionEnd)
    emit "SESSION_END" s:reason "$f_reason"
    rm -f "$stack" "$stamps" 2>/dev/null
    ;;
  postToolUse|postToolUseFailure)
    # Tool summary: never store toolResult (can be megabytes) — just the tool + a short arg hint.
    # A path argument is kept whole up to 1024 bytes (a Windows worktree path is often over 200, and without its file
    # name the record cannot say what was written); a command keeps 200 bytes a line, its line breaks as \n.
    if [ -n "$arg_path" ]; then trunc_lines "$arg_full" 1024; else trunc_lines "$arg_full" 200; fi
    okflag="true"; [ "$event" = "postToolUseFailure" ] && okflag="false"
    esc_lines "$TRUNC"; arg_json="\"$ESC\""
    if [ "$CUT" = "true" ]; then
      emit "TOOL" s:tool "$tool" r:arg "$arg_json" r:argCut true r:ok "$okflag"
    else
      emit "TOOL" s:tool "$tool" r:arg "$arg_json" r:ok "$okflag"
    fi

    # READ vs DISCOVERED: a path in the tool ARGS is an explicit open (the body entered
    # context) → *_LOAD. A path only in the tool RESULT scrolled past the agent (ls / grep /
    # file-search output) without being opened by this call → *_SEEN. Without jq the two
    # can't be separated, so everything counts as a LOAD (degraded mode, header note).
    for skill in $sk_load; do
      sp=".claude/skills/${skill}/SKILL.md"
      [ -f "$root/$sp" ] || sp="skills/${skill}/SKILL.md"
      stamp "$sp"
      emit "SKILL_LOAD" s:skill "$skill" s:skillPath "$sp" s:skillCommit "$commit" r:dirty "$dirty"
    done
    for skill in $sk_seen; do
      emit "SKILL_SEEN" s:skill "$skill"
    done

    for instr in $in_load; do
      case "$instr" in *.instructions.md) stamp ".github/instructions/${instr}" ;; *) stamp ".claude/rules/${instr}" ;; esac
      emit "INSTRUCTION_LOAD" s:instruction "$instr" s:instructionCommit "$commit" r:dirty "$dirty"
    done
    for instr in $in_seen; do
      emit "INSTRUCTION_SEEN" s:instruction "$instr"
    done

    for d in $doc_load; do
      stamp "$d"
      emit "DOC_LOAD" s:doc "$d" s:docCommit "$commit" r:dirty "$dirty"
    done
    for d in $doc_seen; do
      emit "DOC_SEEN" s:doc "$d"
    done

    # Persona loads: an agent body read (.claude/agents/<role>.md) is context too.
    for p in $personas; do
      emit "PERSONA_LOAD" s:persona "$p"
    done
    ;;
  *)
    emit "EVENT"
    ;;
esac

exit 0
