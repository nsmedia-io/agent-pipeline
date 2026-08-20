#!/usr/bin/env bash
# pipeline-telemetry.mjs — EXIT-MARKER attribution (issue #30, commit C).
#
# BEHAVIOURAL CONTRACT, authored at Phase 3a before the implementation exists.
#
# THE DEFECT. telemetry() credits each interval to the phase named by the EARLIER event,
# which is correct only if events[] entries are ENTRY markers. They are not: every one of the
# ten real events in .pipeline/17/status.json carries a `verdict`, and a verdict is not
# knowable until a phase has RUN, so events[] are EXIT markers and every bucket is shifted one
# slot. On that record it credits Dev's 68 minutes to QA. Worse than a shift: the loop runs to
# `timed.length - 1`, so under the entry reading the LAST phase of every run receives no key at
# all -- a structural inability to ever report a run's final phase, not a one-slot error.
#
# THE FIX, stated as behaviour: credit each interval to the phase CLOSED by the LATER event.
#
# FIELD DATA OVER DERIVED TRUTH. status.schema.json's description sides with the parser
# ("the events that opened it") and commands/pipeline.md:65 -- the WRITER instruction -- sides
# with the record ("append after each phase transition, carrying its verdict"). The live record
# wins; the derived documentation is what changes (AC12, AC13).
#
# WHY THE KEYS ARE TOKENS AND NOT RAW LABELS (spec C2, a SecOps veto condition). A raw-label
# implementation would write `events[].phase` -- typed `{"type":"string"}` with NO pattern and
# NO maxLength, unlike `current_phase`, which IS pattern-validated -- as a PERSISTED OBJECT KEY
# into a file committed to git and archived verbatim. It would also make phaseKey's null branch
# unreachable, so `unattributed_ms` would become structurally 0 and the guarantee both the
# module docstring and the schema state ("a label KNOWN_PHASES does not declare shows up as a
# visible number instead of being silently dropped") would become an overclaim -- this issue's
# own defect class, introduced by its own fix. AC24 asserts the allowlist as a PROPERTY over
# every population, so a raw-label implementation reddens even if AC8's three numbers were
# somehow matched. KNOWN_PHASES is READ from dispatch-model.mjs here, never hand-copied.
#
# AC10 IS THE EXPECTED SURVIVOR of the AC8 and AC24 mutations, and that is a stated MECHANISM,
# not an observed coincidence: relabelling which key absorbs a delta does not change the SET of
# deltas, and total_lead_time_ms is timed[last].at - timed[0].at, independent of any label. Two
# greens (AC8, AC24) and one red (double-credit) is the pass. Three greens means the identity
# is not actually asserted; three reds means the relabel changed the delta set, which is itself
# the signal.
#
# DO NOT `/pipeline --resume 17`. .pipeline/17/status.json is the fixture AC8, AC9 and AC14
# pin by exact value; a resume would rewrite it and these numbers would move under the suite.

. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
require_node

make_temp_project || exit 90

PLUGIN_DIR="$PLUGIN_ROOT"
PIPELINE_MD="$PLUGIN_DIR/commands/pipeline.md"
SCHEMA="$PLUGIN_DIR/schemas/status.schema.json"
TELEMETRY="$SCRIPTS_DIR/pipeline-telemetry.mjs"
DISPATCH="$SCRIPTS_DIR/dispatch-model.mjs"
REPO_ROOT="$(cd "$PLUGIN_DIR/../.." && pwd)"
R17="$REPO_ROOT/.pipeline/17/status.json"
SUITE_UNDER_SCAN="$PLUGIN_DIR/tests/test-pipeline-telemetry.sh"

# field <key-expression> : telemetry() over $R17, printing one field.
r17_field() {
  MOD="$TELEMETRY" R="$R17" node --input-type=module -e "
    import { readFileSync } from 'node:fs';
    const m = await import(process.env.MOD);
    const t = m.telemetry(JSON.parse(readFileSync(process.env.R, 'utf8')));
    console.log(String($1));
  "
}

suite "AC8/AC9/AC14: the real record, read as EXIT markers"

# FIXTURE INTEGRITY FIRST. Every number below is meaningless if the record moved or vanished,
# and an absent file would otherwise redden six assertions with six confusing messages.
assert_eq "the pinned record is present" "$([[ -f "$R17" ]] && echo yes || echo no)" "yes"
assert_eq "and it still carries the ten events these numbers were measured over" \
  "$(R="$R17" node -e 'console.log(JSON.parse(require("fs").readFileSync(process.env.R,"utf8")).events.length)')" "10"
# The tell that decides the whole question, asserted rather than asserted-about.
assert_eq "all ten carry a \`verdict\`, which is why they are exit markers" \
  "$(R="$R17" node -e 'const e=JSON.parse(require("fs").readFileSync(process.env.R,"utf8")).events;console.log(e.filter(x=>"verdict" in x).length)')" "10"

# AC8. The 3a/3b pair. Under the entry reading '3a' reads 4088488 and there is NO '3b' key.
assert_eq "AC8: a '3b' key exists at all (the entry reading never credits the last phase)" \
  "$(r17_field "Object.prototype.hasOwnProperty.call(t.phase_elapsed_ms,'3b')")" "true"
assert_eq "AC8: phase_elapsed_ms['3b'] is Dev's 4088488 ms" \
  "$(r17_field "t.phase_elapsed_ms['3b']")" "4088488"
assert_eq "AC8: phase_elapsed_ms['3a'] is QA's 1532139 ms, not Dev's 68 minutes" \
  "$(r17_field "t.phase_elapsed_ms['3a']")" "1532139"

# AC9. A DIFFERENT pair of phases, so a fix that special-cased 3a/3b still reddens here. The
# 2.5-design event carries verdict SKIPPED and shares a timestamp with its predecessor, so the
# zero belongs to the skipped phase -- under the entry reading '2.5' reads 1532139 instead.
assert_eq "AC9: phase_elapsed_ms['2.5'] is 0 -- the skipped design phase owns the zero" \
  "$(r17_field "t.phase_elapsed_ms['2.5']")" "0"
assert_eq "AC9: phase_elapsed_ms['1'] is 3413188 (the token absorbs ba, ba-rework, ba-rework-r2)" \
  "$(r17_field "t.phase_elapsed_ms['1']")" "3413188"

# AC14. started_at precedes the first event by 91,264,632 ms (25.35 hours) of untracked wall
# clock on this record. Under exit semantics the first phase's START is genuinely unrecorded;
# inventing a leading boundary from started_at would make '0.5' read 91271177. This assertion
# is what makes "do not invent the first boundary" enforced rather than merely stated.
assert_eq "AC14: phase_elapsed_ms['0.5'] is 6545 -- the real first interval" \
  "$(r17_field "t.phase_elapsed_ms['0.5']")" "6545"
assert_eq "AC14: it is NOT 91271177 (started_at was not folded in as a leading boundary)" \
  "$(r17_field "t.phase_elapsed_ms['0.5'] === 91271177")" "false"
assert_eq "AC14: and NOT 563676 (the entry reading's value)" \
  "$(r17_field "t.phase_elapsed_ms['0.5'] === 563676")" "false"

# =============================================================================
# The self-scan machinery for AC10, AC11 and AC24's "every fixture in the suite" halves.
# =============================================================================
#
# WHY A SELF-SCAN AND NOT A HAND-COPIED LIST. AC10 and AC24 are asserted over the real record
# AND over EVERY fixture in test-pipeline-telemetry.sh. A list copied into this file would
# track whoever last remembered to update it, and would go quietly stale the moment Dev adds a
# fixture -- the exact "restates the contract instead of observing it" failure this issue is
# about. So the fixtures are EXTRACTED from the suite text by brace matching.
EXTRACT="$TEMP_PROJECT/extract-fixtures.mjs"
cat > "$EXTRACT" <<'EOF'
// Prints one JSON status fixture per line, extracted from a bash suite's text by balanced
// brace matching. A candidate qualifies only if it parses AND has an events[] array.
import { readFileSync } from "node:fs";
const text = readFileSync(process.env.SUITE, "utf8");
const out = [];
for (let i = 0; i < text.length; i++) {
  if (text[i] !== "{") continue;
  let d = 0, j = i;
  for (; j < text.length; j++) {
    if (text[j] === "{") d++;
    else if (text[j] === "}") { d--; if (d === 0) break; }
  }
  if (d !== 0) continue;
  const s = text.slice(i, j + 1);
  if (!/"events"\s*:/.test(s)) continue;
  try {
    const o = JSON.parse(s);
    if (Array.isArray(o.events)) { out.push(JSON.stringify(o)); i = j; }
  } catch { /* not a fixture */ }
}
console.log(out.join("\n"));
EOF

FIXTURES_FILE="$TEMP_PROJECT/fixtures.jsonl"
SUITE="$SUITE_UNDER_SCAN" node "$EXTRACT" > "$FIXTURES_FILE"
FIXTURE_COUNT=$(grep -c . "$FIXTURES_FILE" | tr -d ' ')

# THE NON-ZERO CONTROL ON THE SELF-SCAN. Without it, an extractor that silently matched
# nothing would report "0 fixtures violate the property" and read as a pass. 8 is the count
# measured at ebb81c1; the floor may only rise as fixtures are added.
assert_eq "SELF-SCAN CONTROL: the extractor really found fixtures to walk" \
  "$([[ "$FIXTURE_COUNT" -ge 8 ]] && echo ok || echo "found=$FIXTURE_COUNT")" "ok"

# THE OWN-FIXTURE SET. Shapes the suite under scan does not carry, so the two properties below
# are measured over more than one file's imagination: a run whose timestamps go BACKWARDS
# (negative delta, absorbed by unattributed_ms), a run carrying an UNDECLARED phase label, and
# a run with an UNTIMED event dropped before any figure is computed.
OWN_FIXTURES="$TEMP_PROJECT/own-fixtures.jsonl"
cat > "$OWN_FIXTURES" <<'EOF'
{"events":[{"phase":"0.5-map","verdict":"OK","at":"2026-08-01T00:00:00Z"},{"phase":"1-ba","verdict":"APPROVE","at":"2026-08-01T01:00:00Z"},{"phase":"3b-dev","verdict":"APPROVE","at":"2026-08-01T04:00:00Z"}]}
{"events":[{"phase":"0.5-map","verdict":"OK","at":"2026-08-01T02:00:00Z"},{"phase":"1-ba","verdict":"APPROVE","at":"2026-08-01T00:00:00Z"}]}
{"events":[{"phase":"1-ba","verdict":"APPROVE","at":"2026-08-01T00:00:00Z"},{"phase":"9-not-a-phase","verdict":"APPROVE","at":"2026-08-01T01:00:00Z"},{"phase":"5-archive","verdict":"DONE","at":"2026-08-01T02:00:00Z"}]}
{"events":[{"phase":"1-ba","verdict":"APPROVE","at":"2026-08-01T00:00:00Z"},{"phase":"3a-qa-tests","verdict":"APPROVE","at":"not-a-date"},{"phase":"5-archive","verdict":"DONE","at":"2026-08-01T02:00:00Z"}]}
{"events":[]}
EOF
cat "$FIXTURES_FILE" "$OWN_FIXTURES" > "$TEMP_PROJECT/all-fixtures.jsonl"
ALL_FIXTURES="$TEMP_PROJECT/all-fixtures.jsonl"

# violations <mode> <fixture-file> : counts fixtures failing the named property.
PROPS="$TEMP_PROJECT/props.mjs"
cat > "$PROPS" <<'EOF'
import { readFileSync } from "node:fs";
const m = await import(process.env.MOD);
const d = await import(process.env.DISPATCH);
const known = new Set(d.KNOWN_PHASES);
const mode = process.env.MODE;
let violations = 0, walked = 0;
const lines = readFileSync(process.env.FIXTURES, "utf8").split("\n").filter((l) => l.trim());
for (const line of lines) {
  const t = m.telemetry(JSON.parse(line));
  walked++;
  if (mode === "keys") {
    if (Object.keys(t.phase_elapsed_ms).some((k) => !known.has(k))) violations++;
  } else {
    // The partition identity. A null lead time means fewer than two timed events, in which
    // case there is no interval to partition and the identity is vacuous rather than false.
    if (t.total_lead_time_ms === null) continue;
    const sum = Object.values(t.phase_elapsed_ms).reduce((a, b) => a + b, 0);
    if (sum + t.unattributed_ms !== t.total_lead_time_ms) violations++;
  }
}
console.log(process.env.WANT === "walked" ? walked : violations);
EOF
prop() { MOD="$TELEMETRY" DISPATCH="$DISPATCH" MODE="$1" FIXTURES="$2" WANT="${3:-violations}" node "$PROPS"; }

suite "AC24: every phase_elapsed_ms key is a KNOWN_PHASES token, over every population"

# This is the assertion that makes the allowlist ENFORCED rather than incidental, and it is
# what stops the leak -- not the three pinned numbers above. KNOWN_PHASES is read from
# dispatch-model.mjs at run time.
printf '%s\n' "$(cat "$R17" | tr -d '\n')" > "$TEMP_PROJECT/r17.jsonl"
assert_eq "AC24: over the real .pipeline/17 record, no key is outside KNOWN_PHASES" \
  "$(prop keys "$TEMP_PROJECT/r17.jsonl")" "0"
assert_eq "AC24 CONTROL: and that zero was measured over a record that was actually walked" \
  "$(prop keys "$TEMP_PROJECT/r17.jsonl" walked)" "1"
assert_eq "AC24: over every fixture in the suite and in this file, no key is outside KNOWN_PHASES" \
  "$(prop keys "$ALL_FIXTURES")" "0"
assert_eq "AC24 CONTROL: and that zero was measured over a non-empty fixture set" \
  "$([[ "$(prop keys "$ALL_FIXTURES" walked)" -ge 13 ]] && echo ok || echo "walked=$(prop keys "$ALL_FIXTURES" walked)")" "ok"

suite "AC10: the partition identity, the EXPECTED SURVIVOR of the relabel mutations"

# sum(phase_elapsed_ms) + unattributed_ms === total_lead_time_ms. Insensitive to the
# entry/exit convention BY MECHANISM: the convention relabels which key absorbs each delta, it
# does not change the delta SET, and total_lead_time_ms is computed from the first and last
# timestamps with no reference to any label. It must stay GREEN under the AC8 and AC24
# mutations and RED under a double-credit.
assert_eq "AC10: the identity holds over the real .pipeline/17 record" \
  "$(prop identity "$TEMP_PROJECT/r17.jsonl")" "0"
assert_eq "AC10: and over every fixture in the suite and in this file" \
  "$(prop identity "$ALL_FIXTURES")" "0"
assert_eq "AC10 CONTROL: measured over a population with a BACKWARDS-timestamp fixture in it" \
  "$(MOD="$TELEMETRY" DISPATCH="$DISPATCH" node --input-type=module -e '
     const m = await import(process.env.MOD);
     const t = m.telemetry({events:[{phase:"0.5-map",at:"2026-08-01T02:00:00Z"},{phase:"1-ba",at:"2026-08-01T00:00:00Z"}]});
     console.log(t.unattributed_ms < 0 ? "negative" : String(t.unattributed_ms));
   ')" "negative"

suite "AC11: every event object in every status fixture carries a \`verdict\`"

# A fixture that strips the discriminating field cannot witness the convention it claims to
# test. Zero of the 29 event objects in the suite carry one today.
VERDICT_SCAN="$TEMP_PROJECT/verdict-scan.mjs"
cat > "$VERDICT_SCAN" <<'EOF'
import { readFileSync } from "node:fs";
const text = readFileSync(process.env.SUITE, "utf8");
const objs = text.match(/\{[^{}]*"phase"\s*:[^{}]*\}/g) || [];
const missing = objs.filter((s) => !/"verdict"\s*:/.test(s));
console.log(process.env.WANT === "total" ? objs.length : missing.length);
if (process.env.WANT === "names") for (const s of missing) console.error(s.replace(/\s+/g, " "));
EOF
TOTAL_EVENTS=$(SUITE="$SUITE_UNDER_SCAN" WANT=total node "$VERDICT_SCAN")
assert_eq "AC11 CONTROL: the scan really found event objects to check" \
  "$([[ "$TOTAL_EVENTS" -ge 29 ]] && echo ok || echo "found=$TOTAL_EVENTS")" "ok"
assert_eq "AC11: no event object in the suite is missing its \`verdict\`" \
  "$(SUITE="$SUITE_UNDER_SCAN" node "$VERDICT_SCAN")" "0"
# And this file holds itself to the same rule, so its own fixtures can witness the convention.
assert_eq "AC11: nor in this file's own fixtures" \
  "$(SUITE="${BASH_SOURCE[0]}" node "$VERDICT_SCAN")" "0"

suite "AC12/AC13: the two prose readers that currently side with the wrong convention"

# AC12. The schema description is the sentence that would reintroduce this bug at the next
# reading, exactly as the 'entirely commented out passes' docstring does for the gate.
assert_eq "AC12: the description no longer says the events that OPENED the phase" \
  "$(grep -c 'opened it' "$SCHEMA" | tr -d ' ')" "0"
assert_eq "AC12: it says the phase was CLOSED" \
  "$([[ "$(grep -c 'closed' "$SCHEMA" | tr -d ' ')" -ge 1 ]] && echo ok || echo no)" "ok"
assert_eq "AC12: it names \`verdict\` as the tell that events[] are exit markers" \
  "$([[ "$(grep -c 'verdict' "$SCHEMA" | tr -d ' ')" -ge 1 ]] && echo ok || echo no)" "ok"
assert_eq "AC12: and names KNOWN_PHASES as the key source" \
  "$([[ "$(grep -c 'KNOWN_PHASES' "$SCHEMA" | tr -d ' ')" -ge 1 ]] && echo ok || echo no)" "ok"

# AC13. Two fields with OPPOSITE conventions five lines apart is the trap that produced this
# defect. The sentence must sit inside that region, where a reader of either field meets it.
EVENTS_REGION=$(sed -n '55,80p' "$PIPELINE_MD")
assert_contains "AC13: the events[]/current_phase region names events[] as EXIT markers" \
  "$EVENTS_REGION" "EXIT marker"
assert_contains "AC13: and current_phase as an ENTRY marker" \
  "$EVENTS_REGION" "ENTRY marker"

suite "AC25: the schema stops forbidding a value its own corpus produces"

# Two of the four on-disk records return total_lead_time_ms = -2072774, because their events
# run backwards -- and the SIBLING field unattributed_ms documents backwards timestamps as a
# SUPPORTED SIGNAL. phase_elapsed_ms correctly stays non-negative because the code guards
# delta >= 0. Asserted as a shape read of the schema, in the idiom this suite already uses.
# NOTE, so nobody reads more urgency into this than it has: nothing in this repo validates
# status.json against status.schema.json (voice-lint.mjs:261, the phaseShapeFailure message, says so outright), so no validator
# is about to fire. It is a contract that contradicts its own corpus and its own sibling field.
assert_eq "AC25: total_lead_time_ms declares no \`minimum\`" \
  "$(SCHEMA="$SCHEMA" node -e '
     const s=JSON.parse(require("fs").readFileSync(process.env.SCHEMA,"utf8"));
     const f=s.properties.telemetry.properties.total_lead_time_ms;
     console.log(Object.prototype.hasOwnProperty.call(f,"minimum")?"declared":"absent");
   ')" "absent"
assert_eq "AC25 CONTROL: phase_elapsed_ms values DO keep their minimum (the code guards delta >= 0)" \
  "$(SCHEMA="$SCHEMA" node -e '
     const s=JSON.parse(require("fs").readFileSync(process.env.SCHEMA,"utf8"));
     console.log(String(s.properties.telemetry.properties.phase_elapsed_ms.additionalProperties.minimum));
   ')" "0"

suite "AC26: the convention marker, and the leak check it must not break"

# telemetry() shipped in 0.21.0, so adopter records accumulate under the OLD convention from
# now on and an entry-semantics block is otherwise forever indistinguishable from an exit one.
assert_eq "AC26: telemetry() emits attribution: 'exit'" \
  "$(r17_field "t.attribution")" "exit"
assert_eq "AC26: the schema declares it as an enum of exactly ['exit']" \
  "$(SCHEMA="$SCHEMA" node -e '
     const s=JSON.parse(require("fs").readFileSync(process.env.SCHEMA,"utf8"));
     const a=s.properties.telemetry.properties.attribution;
     console.log(a && a.type==="string" ? JSON.stringify(a.enum) : "undeclared");
   ')" '["exit"]'
assert_eq "AC26: the telemetry object stays closed" \
  "$(SCHEMA="$SCHEMA" node -e '
     const s=JSON.parse(require("fs").readFileSync(process.env.SCHEMA,"utf8"));
     console.log(String(s.properties.telemetry.additionalProperties));
   ')" "false"
# The closed-object half only bites if the two key sets are compared. A field emitted but not
# declared, or declared but not emitted, is caught here and nowhere else.
assert_eq "AC26: the emitted key set equals the schema's declared property set" \
  "$(MOD="$TELEMETRY" SCHEMA="$SCHEMA" R="$R17" node --input-type=module -e '
     import { readFileSync } from "node:fs";
     const m = await import(process.env.MOD);
     const s = JSON.parse(readFileSync(process.env.SCHEMA, "utf8"));
     const emitted = Object.keys(m.telemetry(JSON.parse(readFileSync(process.env.R,"utf8")))).sort();
     const declared = Object.keys(s.properties.telemetry.properties).sort();
     console.log(JSON.stringify(emitted) === JSON.stringify(declared) ? "equal"
       : "emitted=" + JSON.stringify(emitted) + " declared=" + JSON.stringify(declared));
   ')" "equal"

# THE LEAK CHECK, and why this marker is NOT zero-cost. test-pipeline-telemetry.sh:137-171
# admits a string only if it is a declared telemetry field NAME or a KNOWN_PHASES label, so the
# VALUE "exit" counts as a leak and notes_leaked == 0 reddens until the allowlist also admits
# ENUM VALUES DECLARED IN THE SCHEMA. That widening must preserve the file's stated idiom
# (read the names from the schema, never from a hand-copied list) and must NOT admit arbitrary
# strings -- which is what the two controls below measure.
LEAK="$TEMP_PROJECT/leak.mjs"
cat > "$LEAK" <<'EOF'
import { readFileSync } from "node:fs";
const d = await import(process.env.DISPATCH);
const schema = JSON.parse(readFileSync(process.env.SCHEMA, "utf8"));
const props = schema.properties.telemetry.properties;
const enumValues = Object.values(props).flatMap((p) => (Array.isArray(p.enum) ? p.enum : []));
const allowed = new Set([...Object.keys(props), ...d.KNOWN_PHASES, ...enumValues]);
let obj;
if (process.env.OBJ) obj = JSON.parse(process.env.OBJ);
else {
  const m = await import(process.env.MOD);
  obj = m.telemetry(JSON.parse(readFileSync(process.env.R, "utf8")));
}
console.log(JSON.stringify(obj).match(/"[^"]*"/g).map((s) => s.slice(1, -1)).filter((s) => !allowed.has(s)).length);
EOF
leak() { MOD="$TELEMETRY" DISPATCH="$DISPATCH" SCHEMA="$SCHEMA" R="$R17" OBJ="${1:-}" node "$LEAK"; }

assert_eq "AC26: real telemetry output leaks nothing once enum values are admitted" \
  "$(leak)" "0"
assert_eq "AC26 CONTROL: the existing note+path object still reports its 4" \
  "$(leak '{"phase_elapsed_ms":{"3a":1},"note":"loop back to BA","worktree_path":"/Users/x/wt"}')" "4"
assert_eq "AC26 CONTROL: free text in \`attribution\` still leaks (the widening is not 'admit all strings')" \
  "$([[ "$(leak '{"phase_elapsed_ms":{"3a":1},"attribution":"loop back to BA"}')" -ge 1 ]] && echo ok || echo "leaked=$(leak '{"phase_elapsed_ms":{"3a":1},"attribution":"loop back to BA"}')")" "ok"

finish
