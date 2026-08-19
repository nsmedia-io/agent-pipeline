#!/usr/bin/env bash
# The status.json half of issue #17: the shard-fallback path, the panel_roles enum, the
# derived telemetry, the effective-config audit record, and the no-absolute-paths rule.
#
# The thread running through all of it: status.json is committed AND archived verbatim by the
# Librarian, so anything written into it is written into a public tree. The schema used to
# carry a sentence claiming worktree_path "should be redacted before this file is archived",
# and NOTHING redacted anything -- `grep -rn redact plugins/pipeline/` returned three prose
# hits and no code. A prose claim about a control that does not exist is worse than no claim,
# so it is replaced by a PROHIBITION and by the assertion below that can go red.

. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
require_node

make_temp_project || exit 90

PLUGIN_DIR="$PLUGIN_ROOT"
PIPELINE_MD="$PLUGIN_DIR/commands/pipeline.md"
SCHEMA="$PLUGIN_DIR/schemas/status.schema.json"
TELEMETRY="$SCRIPTS_DIR/pipeline-telemetry.mjs"
MERGE="$SCRIPTS_DIR/merge-peer-review.mjs"
REPO_ROOT="$(cd "$PLUGIN_DIR/../.." && pwd)"

node_run() { MOD="$1"; shift; MOD="$MOD" node --input-type=module -e "$@"; }

# =============================================================================
# AC13 -- THE PHASE 4 SHARD FALLBACK.
# =============================================================================
suite "AC13: the fallback directory is materially different from ARTIFACT_DIR"

# The old instruction told a reviewer whose write was refused to retry at
# <WORKTREE_PATH>/.pipeline/<issue>/, which IS <ARTIFACT_DIR> -- the same path, so a refused
# write had nowhere to go. Asserted as a STRING property of the instruction, because that is
# what a reviewer reads.
assert_eq "the preamble no longer names the worktree .pipeline dir as the fallback" \
  "$(grep -c 'write the shard beside your own worktree at <WORKTREE_PATH>/.pipeline/<issue>/' "$PIPELINE_MD" | tr -d ' ')" "0"
assert_eq "it names a distinct subdirectory instead" \
  "$(grep -c 'fallback-shards/peer-review.<role>.json' "$PIPELINE_MD" | tr -d ' ')" "1"

# The fallback is only worth anything if the MERGE reads it. Extracted from the merge block
# the orchestrator actually runs, not from prose about it.
MERGE_BLOCK="$TEMP_PROJECT/merge-block.sh"
awk '/^# Full round: reset, then fold every dispatched role/{f=1} f{print} f&&/^```$/{exit}' "$PIPELINE_MD" \
  | grep -v '^```' > "$MERGE_BLOCK"
assert_eq "the merge block was extracted (without this, the next assertion measures an empty file)" \
  "$([[ -s "$MERGE_BLOCK" ]] && echo yes || echo no)" "yes"
assert_eq "and it falls back to that directory before declaring a shard missing" \
  "$(grep -c 'fallback-shards' "$MERGE_BLOCK" | tr -d ' ')" "1"
assert_eq "the fallback is consulted BEFORE the missing-shard branch" \
  "$([[ "$(grep -n 'fallback-shards' "$MERGE_BLOCK" | cut -d: -f1)" -lt "$(grep -n 'MISSING SHARD' "$MERGE_BLOCK" | cut -d: -f1)" ]] && echo before || echo after)" \
  "before"

suite "AC13: a shard that lands NOWHERE still HALTS -- recoverability never became leniency"

# The fail direction is the point. Run the real merge script against a missing shard: a lost
# VETO must never merge as an absent-therefore-fine review.
MDIR="$TEMP_PROJECT/merge-fixture"
mkdir -p "$MDIR"
printf '%s' '{"verdict":"APPROVE","reviewed_at":"2026-08-01T00:00:00Z"}' > "$MDIR/peer-review.ba.json"
( cd "$MDIR" && node "$MERGE" "$MDIR/peer-review.json" ba="$MDIR/peer-review.ba.json" >/dev/null 2>&1 )
assert_eq "a present shard merges (exit 0), so the halt below is not the script refusing everything" "$?" "0"
( cd "$MDIR" && node "$MERGE" "$MDIR/peer-review.json" secops="$MDIR/peer-review.secops.json" >/dev/null 2>&1 )
assert_eq "a shard that exists nowhere HALTS with exit 2" "$?" "2"

# =============================================================================
# AC14 / AC15 -- panel_roles accepts all eight roles, and its description is true.
# =============================================================================
suite "AC14: panel_roles accepts the eight roles the orchestrator can actually append"

ROLES_OK=$(SCHEMA="$SCHEMA" node --input-type=module -e '
  import { readFileSync } from "node:fs";
  const schema = JSON.parse(readFileSync(process.env.SCHEMA, "utf8"));
  const allowed = schema.properties.panel_roles.items.enum;
  const want = ["ba","dba","devops","secops","dev","qa","design_review","art_director"];
  console.log(want.every(r => allowed.includes(r)) ? "all-accepted" : "missing:" + want.filter(r=>!allowed.includes(r)).join(","));
')
assert_eq "every role the panel can carry is in the enum" "$ROLES_OK" "all-accepted"
# NON-ZERO CONTROL: the enum is a real allowlist, not an any-string field that would accept
# a typo'd role and silently drop it from the rubric.
assert_eq "CONTROL: an invented role is still rejected by the enum" \
  "$(SCHEMA="$SCHEMA" node --input-type=module -e '
     import { readFileSync } from "node:fs";
     const s = JSON.parse(readFileSync(process.env.SCHEMA, "utf8"));
     console.log(s.properties.panel_roles.items.enum.includes("nonsense") ? "accepted" : "rejected");
   ')" "rejected"

suite "AC15: the description no longer contradicts what the orchestrator appends"

assert_eq "the 'tracked via its own shard' claim is gone" \
  "$(grep -c 'design_review lens is tracked via its own shard' "$SCHEMA" | tr -d ' ')" "0"
assert_eq "and the description says design_review is APPENDED to this array" \
  "$(grep -c 'design_review is APPENDED TO THIS ARRAY' "$SCHEMA" | tr -d ' ')" "1"
assert_eq "CONTROL: commands/pipeline.md really does append it (the fact the description now states)" \
  "$(grep -c 'PANEL_ROLES="$PANEL_ROLES design_review"' "$PIPELINE_MD" | tr -d ' ')" "1"

# =============================================================================
# AC16 -- the telemetry computation, against known timestamps.
# =============================================================================
suite "AC16: per-phase elapsed and lead time are the exact values the fixture implies"

FIX='{"review_rounds":2,"events":[
  {"phase":"1-ba","at":"2026-08-01T00:00:00Z"},
  {"phase":"2-review","at":"2026-08-01T01:00:00Z"},
  {"phase":"3-impl","at":"2026-08-01T03:30:00Z"},
  {"phase":"4-review","at":"2026-08-01T04:00:00Z"},
  {"phase":"4-review-complete","at":"2026-08-01T05:00:00Z"}]}'
T=$(MOD="$TELEMETRY" FIX="$FIX" node --input-type=module -e '
  const m = await import(process.env.MOD);
  const t = m.telemetry(JSON.parse(process.env.FIX));
  console.log(JSON.stringify(t));
')
assert_eq "phase 1 elapsed is exactly one hour"     "$(printf '%s' "$T" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).phase_elapsed_ms["1"]))')" "3600000"
assert_eq "phase 2 elapsed is exactly two and a half hours" "$(printf '%s' "$T" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).phase_elapsed_ms["2"]))')" "9000000"
assert_eq "phase 3 elapsed is exactly half an hour" "$(printf '%s' "$T" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).phase_elapsed_ms["3"]))')" "1800000"
assert_eq "total lead time is exactly five hours"   "$(printf '%s' "$T" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).total_lead_time_ms))')" "18000000"
assert_eq "review_rounds is the recorded counter, not a guess" "$(printf '%s' "$T" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).review_rounds))')" "2"

# The counter is EXPLICIT because events[] has no round field. When it is absent the number of
# 4-review ENTRIES is the honest floor, and that fallback is asserted rather than assumed.
T2=$(MOD="$TELEMETRY" node --input-type=module -e '
  const m = await import(process.env.MOD);
  console.log(m.telemetry({events:[{phase:"4-review",at:"2026-08-01T00:00:00Z"},{phase:"4-review-complete",at:"2026-08-01T01:00:00Z"},{phase:"4-review",at:"2026-08-02T00:00:00Z"},{phase:"4-review-complete",at:"2026-08-02T01:00:00Z"}]}).review_rounds);
')
assert_eq "with no counter recorded, the phase-4 entries are counted instead" "$T2" "2"
assert_eq "an empty status yields a null lead time, not a fabricated zero" \
  "$(MOD="$TELEMETRY" node --input-type=module -e 'const m=await import(process.env.MOD);console.log(String(m.telemetry({}).total_lead_time_ms))')" "null"
assert_eq "and nothing it emits is a free-text note, a path, or a command string" \
  "$(MOD="$TELEMETRY" FIX="$FIX" node --input-type=module -e '
     const m = await import(process.env.MOD);
     const t = m.telemetry(JSON.parse(process.env.FIX));
     const strings = JSON.stringify(t).match(/"[^"]*"/g).filter(s=>!/^"(phase_elapsed_ms|total_lead_time_ms|review_rounds|events_counted|[0-9.]+)"$/.test(s));
     console.log(strings.length);
   ')" "0"

# =============================================================================
# AC43 -- the two migration sets are recorded as DISTINCT entries.
# =============================================================================
suite "AC43: effective_config records the tripwire set and the gate set separately"

eff() { MOD="$TELEMETRY" CFG="$1" node --input-type=module -e '
  const m = await import(process.env.MOD);
  console.log(JSON.stringify(m.effectiveConfig(JSON.parse(process.env.CFG))));
'; }
EFF_CUSTOM=$(eff '{"migrationGlobs":["db/changes/**"]}')
EFF_NONE=$(eff '{}')
same_sets() { printf '%s' "$1" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const c=JSON.parse(s);console.log(JSON.stringify(c.migration_globs_tripwire)===JSON.stringify(c.migration_globs_gate)?"equal":"different")})'; }

assert_eq "under a narrowing config the two entries DIFFER" "$(same_sets "$EFF_CUSTOM")" "different"
# NON-ZERO CONTROL, and it is what makes the assertion about DISTINCTNESS rather than presence:
# under no config the same two entries are equal, and the check must be watched telling the
# two cases apart.
assert_eq "under no config at all they are equal" "$(same_sets "$EFF_NONE")" "equal"
assert_contains "both keys exist by name" "$EFF_CUSTOM" "migration_globs_tripwire"
assert_contains "and the gate's set is the narrowed one" "$EFF_CUSTOM" '"migration_globs_gate":["db/changes/**"]'

suite "AC33: the schema REFUSES an unexpected property inside effective_config"

assert_eq "effective_config is closed (additionalProperties false)" \
  "$(SCHEMA="$SCHEMA" node --input-type=module -e '
     import { readFileSync } from "node:fs";
     const s = JSON.parse(readFileSync(process.env.SCHEMA, "utf8"));
     console.log(String(s.properties.effective_config.additionalProperties));
   ')" "false"
assert_eq "and its model values are allowlisted, so the audit record cannot carry a full model ID" \
  "$(SCHEMA="$SCHEMA" node --input-type=module -e '
     import { readFileSync } from "node:fs";
     const s = JSON.parse(readFileSync(process.env.SCHEMA, "utf8"));
     console.log(s.properties.effective_config.properties.models.additionalProperties.enum.join("/"));
   ')" "opus/sonnet/haiku"
assert_eq "CONTROL: a sibling object in the same schema is NOT closed, so 'false' means something" \
  "$(SCHEMA="$SCHEMA" node --input-type=module -e '
     import { readFileSync } from "node:fs";
     const s = JSON.parse(readFileSync(process.env.SCHEMA, "utf8"));
     console.log(String(s.properties.peer_review_verdict_counts.additionalProperties));
   ')" "undefined"

# =============================================================================
# AC34 -- NO ABSOLUTE PATHS IN status.json, over the REAL corpus.
# =============================================================================
suite "AC34: no string at any depth in a status.json looks like an absolute path"

# The walk is the same one in both directions: it runs over the REAL corpus (every tracked
# .pipeline/*/status.json and every knowledge/issue-archive/*.json) AND over two crafted
# fixtures it must redden on. A fixture-only check is a test whose fixture never constructs
# the collision it claims to test.
WALK="$TEMP_PROJECT/walk.mjs"
cat > "$WALK" <<'EOF'
import { readFileSync } from "node:fs";
const ABS = [/^\//, /^[A-Za-z]:\\/];
const hits = [];
function walk(v, path) {
  if (typeof v === "string") { if (ABS.some(re => re.test(v))) hits.push(path + "=" + v); return; }
  if (Array.isArray(v)) return v.forEach((x, i) => walk(x, path + "[" + i + "]"));
  if (v && typeof v === "object") return Object.entries(v).forEach(([k, x]) => walk(x, path + "." + k));
}
let scanned = 0;
for (const f of process.argv.slice(1)) {
  try { walk(JSON.parse(readFileSync(f, "utf8")), f); scanned++; } catch { /* unreadable: not a status file */ }
}
console.log(JSON.stringify({ scanned, hits }));
EOF

CORPUS=()
while IFS= read -r f; do [[ -n "$f" ]] && CORPUS+=("$REPO_ROOT/$f"); done < <(cd "$REPO_ROOT" && git ls-files | grep -E '(^|/)\.pipeline/[^/]+/status\.json$|^knowledge/issue-archive/.*\.json$|/knowledge/issue-archive/.*\.json$')
CORPUS_RESULT=$(node "$WALK" "${CORPUS[@]}" 2>/dev/null)
SCANNED=$(printf '%s' "$CORPUS_RESULT" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).scanned))')
HITS=$(printf '%s' "$CORPUS_RESULT" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).hits.join(" ")))')

# The corpus size is REPORTED, not assumed. If the archive is still empty the suite says so
# rather than reporting a silent pass over nothing: today knowledge/issue-archive/ holds zero
# JSON files, so this number is carried by the .pipeline status files alone.
assert_eq "the real corpus is non-empty (a zero over an empty corpus proves nothing)" \
  "$([[ "$SCANNED" -ge 1 ]] && echo "scanned>=1" || echo "scanned=$SCANNED: NOTHING WAS WALKED")" "scanned>=1"
assert_eq "the archive corpus is stated rather than assumed: it is empty today" \
  "$(cd "$REPO_ROOT" && git ls-files | grep -cE 'knowledge/issue-archive/.*\.json$' | tr -d ' ')" "0"
assert_eq "no absolute-path string appears anywhere in the real corpus" "$HITS" ""

# NON-ZERO CONTROL, in two spellings, because a check anchored on '/Users/' alone is a
# blocklist over one spelling of one machine's layout.
FIX1="$TEMP_PROJECT/abs-users.json"
printf '%s' '{"current_phase":"3-impl","worktree_path":"/Users/someone/worktrees/x"}' > "$FIX1"
FIX2="$TEMP_PROJECT/abs-var.json"
printf '%s' '{"current_phase":"3-impl","events":[{"phase":"3-impl","note":"/var/folders/z/tmp"}]}' > "$FIX2"
assert_contains "CONTROL: the same walk reddens on /Users/..." "$(node "$WALK" "$FIX1")" "/Users/someone/worktrees/x"
assert_contains "CONTROL: and on /var/folders/... at depth, inside an array" "$(node "$WALK" "$FIX2")" "/var/folders/z/tmp"

suite "AC34(b): an absolute glob in a project config is never written through"

EFF_ABS=$(eff '{"migrationGlobs":["/Users/x/repo/db/migrations/**"]}')
assert_not_contains "the absolute glob string does not reach effective_config" "$EFF_ABS" "/Users/x/repo"
assert_contains "it is replaced by the rejection token" "$EFF_ABS" "<absolute-glob-rejected>"
assert_contains "and the rejection is counted, so it is reportable rather than silent" "$EFF_ABS" '"rejected_absolute_globs":'
assert_eq "CONTROL: an ordinary glob is recorded verbatim" \
  "$(printf '%s' "$(eff '{"migrationGlobs":["db/changes/**"]}')" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).migration_globs_gate.join(",")))')" \
  "db/changes/**"

suite "AC23: the redaction claim is gone, replaced by a prohibition that can go red"

assert_eq "the schema no longer claims worktree_path should be redacted" \
  "$(grep -c 'should be redacted before this file is archived' "$SCHEMA" | tr -d ' ')" "0"
assert_contains "it carries a writer prohibition instead" "$(cat "$SCHEMA")" "must never carry an absolute filesystem path"
# Scoped to the SHIPPED tree, not the suites: this file quotes the deleted sentence in its own
# header, and a grep that counted itself would be un-passable for the wrong reason.
assert_eq "and nothing shipped claims a redaction step exists in code" \
  "$(grep -rl 'redacted before this file is archived' "$PLUGIN_DIR/scripts" "$PLUGIN_DIR/schemas" "$PLUGIN_DIR/commands" "$PLUGIN_DIR/agents" 2>/dev/null | wc -l | tr -d ' ')" "0"

# =============================================================================
# AC17 / AC32 -- the archival path is untouched, and the config file is a tier trigger.
# =============================================================================
suite "AC17: the archival path is untouched"

assert_eq "'status' is still an ARCHIVE_ARTIFACTS entry, on the line that defines the list" \
  "$(grep -c 'const ARCHIVE_ARTIFACTS = .*"status"' "$SCRIPTS_DIR/knowledge-store.mjs" | tr -d ' ')" "1"
assert_eq "CONTROL: the same grep reports 0 for an artifact that is NOT archived" \
  "$(grep -c 'const ARCHIVE_ARTIFACTS = .*"design_gate"' "$SCRIPTS_DIR/knowledge-store.mjs" | tr -d ' ')" "0"

suite "AC32: pipeline.config.json is itself an architectural trigger, in BOTH configs"

trigger_paths() { node --input-type=module -e '
  import { readFileSync } from "node:fs";
  const c = JSON.parse(readFileSync(process.env.F, "utf8"));
  const p = (c.architecturalTriggers && c.architecturalTriggers.paths) || [];
  console.log(p.join(","));
'; }
assert_eq "this repo's own config lists it" "$(F="$REPO_ROOT/pipeline.config.json" trigger_paths)" "pipeline.config.json"
assert_eq "and so does the shipped example" "$(F="$PLUGIN_DIR/pipeline.config.example.json" trigger_paths)" "pipeline.config.json"
assert_contains "and the orchestrator states the rule where the tier is decided" \
  "$(cat "$PIPELINE_MD")" "A diff that touches \`pipeline.config.json\` itself is architectural, always"
# NON-ZERO CONTROL: the trigger is a specific path, not a rule that promotes every diff.
assert_eq "CONTROL: README.md is not in the trigger list" \
  "$([[ "$(F="$REPO_ROOT/pipeline.config.json" trigger_paths)" == *"README"* ]] && echo listed || echo "not-listed")" "not-listed"

finish
