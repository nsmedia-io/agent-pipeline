#!/usr/bin/env bash
# config-doctor.mjs, two additions: the agent frontmatter lint and the consumer-owned config
# namespace.
#
# (1) A consumer's repo-local agent carried an unquoted ": " in its description. YAML reads
#     that as a second key on one line, Claude Code skipped the agent, and nothing named the
#     file. Nothing in the plugin parsed agents/*.md frontmatter at all. Every defect row below
#     has a CONTROL that differs from it by the one construct the row is about.
# (2) The "read by nothing" warning named no remedy, and the only exemption (a `_` prefix) was
#     documented nowhere. `x` is now the documented project-owned object.

. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
require_node

DOCTOR="$SCRIPTS_DIR/config-doctor.mjs"
EXAMPLE="$PLUGIN_ROOT/pipeline.config.example.json"
README="$PLUGIN_ROOT/README.md"

make_temp_project 5150 || exit 90
( cd "$TEMP_PROJECT" && git init -q . && git commit -q --allow-empty -m init ) 2>/dev/null
AGENTS="$TEMP_PROJECT/.claude/agents"
mkdir -p "$AGENTS"
printf '%s' '{"checkCommand":"npm test"}' > "$TEMP_PROJECT/pipeline.config.json"

doctor() { OUT=$(CLAUDE_PROJECT_DIR="$TEMP_PROJECT" node "$DOCTOR" 2>/dev/null); RC=$?; }

# agent <file> <frontmatter-body...>: one line per argument between the --- fences.
agent() {
  local f="$AGENTS/$1"; shift
  { printf -- '---\n'; printf '%s\n' "$@"; printf -- '---\n\nBody.\n'; } > "$f"
}
reset_agents() { rm -f "$AGENTS"/*.md; }

# ---------------------------------------------------------------------------
suite "agent frontmatter: the defect that went silent, and its control"

reset_agents
agent reviewer.md 'name: reviewer' 'description: Money reviewer. Owns: the ledger' 'model: opus'
doctor
assert_eq "the doctor still exits 0 on a broken agent" "$RC" "0"
assert_contains "an unquoted ': ' in description is reported" "$OUT" "agent .claude/agents/reviewer.md does not parse"
assert_contains "and the report names the construct and the remedy" "$OUT" 'unquoted ": "'
assert_contains "and the line it is on" "$OUT" "line 3"

reset_agents
agent reviewer.md 'name: reviewer' 'description: "Money reviewer. Owns: the ledger"' 'model: opus'
doctor
assert_not_contains "CONTROL: the same description double-quoted is clean" "$OUT" "reviewer.md"

reset_agents
agent reviewer.md 'name: reviewer' 'description: Money reviewer' '  continued: here' 'model: opus'
doctor
assert_contains "an unquoted ': ' on a CONTINUATION line of a plain value is reported too" "$OUT" 'unquoted ": "'
reset_agents
agent reviewer.md 'name: reviewer' 'description: Money reviewer' '  continued here' 'model: opus'
doctor
assert_not_contains "CONTROL: the same continuation without the colon is clean" "$OUT" "reviewer.md"

# ---------------------------------------------------------------------------
suite "agent frontmatter: required keys, allowlisted values"

reset_agents
agent a.md 'description: "x"'
agent b.md 'name: b'
doctor
assert_contains "a missing name is reported" "$OUT" 'a.md is missing "name"'
assert_contains "a missing description is reported" "$OUT" 'b.md is missing "description"'

reset_agents
agent c.md 'name: c' 'description: "x"' 'model: gpt-5' 'effort: ultra'
doctor
assert_contains "an unknown model is reported" "$OUT" 'model "gpt-5" is not a known value'
assert_contains "an unknown effort is reported" "$OUT" 'effort "ultra" is not a known value'

reset_agents
agent c.md 'name: c' 'description: "x"' 'model: claude-opus-4-5' 'effort: xhigh'
agent d.md 'name: d' 'description: "x"' 'model: inherit' 'effort: max' 'tools: Read, Grep' 'maxTurns: 40'
doctor
assert_not_contains "CONTROL: a full claude-* model id and a known effort are clean" "$OUT" "c.md"
assert_not_contains "CONTROL: inherit, max, tools and maxTurns are clean" "$OUT" "d.md"

# ---------------------------------------------------------------------------
suite "agent frontmatter: the rest of the parse errors"

reset_agents
agent e.md 'name: e' 'description: "bad \s escape"'
agent f.md 'name: f' 'description: "closed" trailing'
agent g.md 'name: g' 'name: g2' 'description: "x"'
agent h.md 'name:h' 'description: "x"'
printf -- '---\nname: i\ndescription: "x"\n' > "$AGENTS/i.md"
printf 'name: j\n' > "$AGENTS/j.md"
printf -- '---\nname: k\n\tdescription: "x"\n---\n' > "$AGENTS/k.md"
doctor
assert_contains "an invalid double-quoted escape is reported" "$OUT" 'e.md does not parse'
assert_contains "text after a closing quote is reported" "$OUT" 'f.md does not parse'
assert_contains "a duplicate key is reported" "$OUT" '"name" is declared twice'
assert_contains "key:value with no space is reported" "$OUT" 'h.md does not parse'
assert_contains "an unclosed frontmatter block is reported" "$OUT" 'i.md does not parse'
assert_contains "a file with no frontmatter is reported" "$OUT" 'j.md has no frontmatter'
assert_contains "a tab-indented line is reported" "$OUT" 'k.md does not parse'

reset_agents
agent e.md 'name: e' 'description: "escaped \\ backslash, \"quote\", é"'
agent f.md 'name: f' "description: 'it''s: fine'"
agent g.md 'name: g' 'description: >' '  folded: text is fine' '  in a block scalar' 'tools:' '  - Read' '  - Bash'
printf '# Agents\n\nNot an agent.\n' > "$AGENTS/README.md"
printf -- '---\r\nname: crlf\r\ndescription: "x"\r\n---\r\n' > "$AGENTS/crlf.md"
doctor
assert_not_contains "CONTROL: valid double-quoted escapes are clean" "$OUT" "e.md"
assert_not_contains "CONTROL: a single-quoted value with a doubled quote and a colon is clean" "$OUT" "f.md"
assert_not_contains "CONTROL: a block scalar may carry ': ', and a block list is clean" "$OUT" "g.md"
assert_not_contains "CONTROL: README.md in the agents dir is not an agent" "$OUT" "README.md"
assert_not_contains "CONTROL: CRLF line endings are clean" "$OUT" "crlf.md"

reset_agents
agent h.md 'name: h' 'description: Reviews things # and more'
doctor
assert_contains "an unquoted ' #' is reported as a truncating comment" "$OUT" 'drops everything from there as a comment'

# ---------------------------------------------------------------------------
suite "agent frontmatter: the plugin's own agents, and the value lists"

reset_agents
doctor
assert_not_contains "the plugin's nine shipped agents lint clean" "$OUT" "agent plugin agents/"
POP=$(DOC="$DOCTOR" AG="$PLUGIN_ROOT/agents" node --input-type=module -e '
  const m = await import((await import("node:url")).pathToFileURL(process.env.DOC).href);
  const fs = await import("node:fs"); const path = await import("node:path");
  const files = fs.readdirSync(process.env.AG).filter((f) => f.endsWith(".md"));
  const parsed = files.filter((f) => { const r = m.parseAgentFrontmatter(fs.readFileSync(path.join(process.env.AG, f), "utf8")); return r.present && r.errors.length === 0 && typeof r.data.name === "string" && typeof r.data.description === "string"; });
  console.log(files.length + "/" + parsed.length);')
assert_eq "VACUITY: every shipped agent file PARSED with a name and description (files/parsed)" "$POP" "9/9"

# A broken copy of a real shipped agent, so the clean result above is not a lint that finds nothing.
# awk, not `sed 0,/re/`, which BSD sed (macOS) does not have. The splice lands OUTSIDE any quotes.
awk '!done && /^description: /{ sub(/^description: "?/, "description: Broken: "); done=1 } { print }' \
  "$PLUGIN_ROOT/agents/ba.md" > "$AGENTS/ba-copy.md"
doctor
assert_contains "CONTROL: a real shipped agent with ': ' spliced into its description is reported" "$OUT" "ba-copy.md does not parse"

EFFORTS=$(DOC="$DOCTOR" DE="$SCRIPTS_DIR/dispatch-effort.mjs" node --input-type=module -e '
  const { pathToFileURL } = await import("node:url");
  const a = await import(pathToFileURL(process.env.DOC).href); const b = await import(pathToFileURL(process.env.DE).href);
  console.log(JSON.stringify(a.KNOWN_AGENT_EFFORTS) === JSON.stringify(b.ALLOWED_EFFORTS) ? "same" : "DRIFT " + a.KNOWN_AGENT_EFFORTS + " vs " + b.ALLOWED_EFFORTS);')
assert_eq "the lint's effort list equals dispatch-effort.mjs ALLOWED_EFFORTS" "$EFFORTS" "same"

# ---------------------------------------------------------------------------
suite "config namespace: the remedy travels with the warning"

reset_agents
printf '%s' '{"checkCommand":"npm test","riskTiers":{"money":1}}' > "$TEMP_PROJECT/pipeline.config.json"
doctor
assert_contains "an unknown key is still reported" "$OUT" '"riskTiers" is read by nothing'
assert_contains "and the warning names the x object" "$OUT" 'under the "x" object'
assert_contains "and the _ prefix" "$OUT" 'starting with "_"'

printf '%s' '{"checkCommand":"npm test","x":{"riskTiers":{"money":1}},"_note":"mine"}' > "$TEMP_PROJECT/pipeline.config.json"
doctor
assert_not_contains "CONTROL: the same setting under x is not reported" "$OUT" "read by nothing"
assert_contains "and the config reads healthy" "$OUT" "all keys recognized"

printf '%s' '{"checkCommand":"npm test","x":"not an object"}' > "$TEMP_PROJECT/pipeline.config.json"
doctor
assert_contains "x must be an object" "$OUT" '"x" should be object but is string'

printf '%s' '{"checkCommand":"npm test","xy":1}' > "$TEMP_PROJECT/pipeline.config.json"
doctor
assert_not_contains "a short typo is never told to use x as a spelling suggestion" "$OUT" 'Did you mean "x"'

assert_eq "the example config carries the x object" "$(node -e 'const c=require(process.argv[1]); console.log(typeof c.x === "object" && c.x !== null && !Array.isArray(c.x) ? "object" : "absent")' "$EXAMPLE")" "object"
assert_contains "the README config table has an x row" "$(grep '^| `x`' "$README")" "PROJECT-OWNED"
assert_contains "the README marks architecturalTriggers ADVISORY" "$(grep '^| `architecturalTriggers`' "$README")" "ADVISORY"
assert_contains "the example marks keywords advisory" "$(cat "$EXAMPLE")" '"_keywords_comment": "ADVISORY.'

finish
