#!/usr/bin/env bash
# The /pipeline orchestrator is a core (commands/pipeline.md, loaded on every run) plus one file per
# phase under orchestrator/, each Read by the orchestrator when its phase starts. Splitting a
# prompt opens three failure shapes a single file could not have, and this suite holds each one:
#
#   (1) a phase file nothing tells the orchestrator to load: its rules exist on disk and in no run;
#   (2) a phase file the pins never read: harness.sh's PIPELINE_MD_PARTS decides what every
#       prose-pinning suite sees, so a file missing from that list escapes every pin at once;
#   (3) a phase file the plugin loader would register as a command of its own (markdown in a
#       subdirectory of commands/ can be exposed as a namespaced slash command, which is why the
#       phase files live in orchestrator/, outside commands/), or a rationale file
#       a prompt tells the model to read (which would put the moved bytes straight back).
#
# And the same for the two blocks the nine agent contracts now read by reference from shared/.

. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"

CORE="$PLUGIN_ROOT/commands/pipeline.md"
PARTS_DIR="$PLUGIN_ROOT/orchestrator"
SHARED_DIR="$PLUGIN_ROOT/shared"

suite "the core and its phase files agree with the pins' fixed order"

ON_DISK="$(cd "$PARTS_DIR" 2>/dev/null && ls -1 *.md 2>/dev/null | LC_ALL=C sort | tr '\n' ' ' | sed 's/ *$//')"
IN_LIST="$(printf '%s\n' $PIPELINE_MD_PARTS | LC_ALL=C sort | tr '\n' ' ' | sed 's/ *$//')"
assert_eq "VACUITY: the phase directory holds files at all" \
  "$([[ -n "$ON_DISK" ]] && echo present || echo "EMPTY: $PARTS_DIR")" "present"
assert_eq "harness.sh's PIPELINE_MD_PARTS names exactly the files in orchestrator/ (no file escapes the pins)" \
  "$IN_LIST" "$ON_DISK"
assert_eq "and names each one once (a duplicate would double every count a pin takes)" \
  "$(printf '%s\n' $PIPELINE_MD_PARTS | LC_ALL=C sort | uniq -d | tr '\n' ' ')" ""

pipeline_md_concat "$PLUGIN_ROOT" || exit 90
EXPECTED_BYTES=$(( $(wc -c < "$CORE") ))
for p in $PIPELINE_MD_PARTS; do EXPECTED_BYTES=$(( EXPECTED_BYTES + $(wc -c < "$PARTS_DIR/$p") )); done
assert_eq "the concatenation the pins read is the core plus every part, byte for byte in length" \
  "$(( $(wc -c < "$PIPELINE_MD_CONCAT") ))" "$EXPECTED_BYTES"

# NON-ZERO CONTROL: a missing part must refuse, not concatenate around the hole.
new_tmpdir || exit 90
FAKE="$NEW_TMPDIR/plugin"
mkdir -p "$FAKE/orchestrator"
cp "$CORE" "$FAKE/commands/pipeline.md"
for p in $PIPELINE_MD_PARTS; do cp "$PARTS_DIR/$p" "$FAKE/orchestrator/$p"; done
rm -f "$FAKE/orchestrator/phase-4-panel.md"
pipeline_md_concat "$FAKE" 2>/dev/null
FAKE_RC=$?
assert_eq "NON-ZERO CONTROL: a part missing from the tree makes the concatenation refuse (exit 90)" "$FAKE_RC" "90"

suite "every phase file is reachable: the core tells the orchestrator when to Read it"

UNNAMED=""
for p in $PIPELINE_MD_PARTS; do
  grep -qF "\`$p\`" "$CORE" || UNNAMED="$UNNAMED $p"
done
assert_eq "the core's loading map names every phase file" "$UNNAMED" ""
DANGLING=""
for n in $(grep '^|' "$CORE" | grep -oE '`[a-z0-9.-]+\.md`' | tr -d '`' | LC_ALL=C sort -u); do
  [[ -f "$PARTS_DIR/$n" ]] || DANGLING="$DANGLING $n"
done
assert_eq "and every file its loading map names exists (a row pointing nowhere is a phase with no rules)" "$DANGLING" ""
# NON-ZERO CONTROL for the naming check: a core with one row's file name removed must be caught.
sed 's/`phase-3-4-gate.md`/`phase-3-4-GONE.md`/g' "$CORE" > "$NEW_TMPDIR/core-mutated.md"
assert_eq "NON-ZERO CONTROL: the naming check sees a file name removed from the core" \
  "$(grep -cF '`phase-3-4-gate.md`' "$NEW_TMPDIR/core-mutated.md" | tr -d ' ')" "0"
PREAMBLE_MD="$PARTS_DIR/phase-4-panel-preamble.md"
assert_eq "the renderer's preamble markers are in orchestrator/phase-4-panel-preamble.md, the one file scripts/render-panel.mjs reads" \
  "$(grep -c '^<!-- BEGIN PHASE4-PREAMBLE -->$\|^<!-- END PHASE4-PREAMBLE -->$' "$PREAMBLE_MD" | tr -d ' ')" "2"
assert_eq "and appear in no other orchestrator file (a second copy would be a preamble the renderer never renders)" \
  "$(for f in "$CORE" "$PARTS_DIR"/*.md; do [[ "$f" == "$PREAMBLE_MD" ]] || cat "$f"; done | grep -cE '^<!-- (BEGIN|END) PHASE4-PREAMBLE -->$' | tr -d ' ')" "0"
assert_eq "the renderer names that file (moving the preamble again moves this pin with it)" \
  "$(grep -cF '"orchestrator", "phase-4-panel-preamble.md"' "$PLUGIN_ROOT/scripts/render-panel.mjs" | tr -d ' ')" "1"
assert_eq "the core no longer carries the preamble (the orchestrator loads the core on every run and never acts on it)" \
  "$(grep -cF 'Phase 4 peer review for #<issue>.' "$CORE" | tr -d ' ')" "0"

suite "a phase file is not a command, and the rationale file is loaded by no prompt"

WITH_FRONTMATTER=""
for p in $PIPELINE_MD_PARTS; do
  [[ "$(head -1 "$PARTS_DIR/$p")" == "---" ]] && WITH_FRONTMATTER="$WITH_FRONTMATTER $p"
done
assert_eq "no phase file carries command frontmatter" "$WITH_FRONTMATTER" ""
subdir_md() {  # <commands dir> -> markdown files below its top level, space-separated
  find "$1" -mindepth 2 -name '*.md' 2>/dev/null | LC_ALL=C sort | tr '\n' ' ' | sed 's/ *$//'
}
assert_eq "commands/ holds no markdown below its top level (a subdirectory file can become a namespaced slash command)" \
  "$(subdir_md "$PLUGIN_ROOT/commands")" ""
# NON-ZERO CONTROL: the same check sees a planted subdirectory file.
mkdir -p "$NEW_TMPDIR/cmdtree/commands/pipeline" && printf 'x\n' > "$NEW_TMPDIR/cmdtree/commands/pipeline/phase.md"
assert_contains "NON-ZERO CONTROL: the subdirectory check finds a planted commands/pipeline/phase.md" \
  "$(subdir_md "$NEW_TMPDIR/cmdtree/commands")" "commands/pipeline/phase.md"
assert_eq "docs/rationale.md exists to hold what moved out of the prompt" \
  "$([[ -s "$PLUGIN_ROOT/docs/rationale.md" ]] && echo present || echo ABSENT)" "present"
READERS="$(grep -rniE '\b(read|load)\b[^.|]*docs/rationale\.md' "$PLUGIN_ROOT/commands" "$PLUGIN_ROOT/agents" "$SHARED_DIR" "$PLUGIN_ROOT/voice.md" "$PLUGIN_ROOT/evidence.md" "$PLUGIN_ROOT/evidence-controls.md" 2>/dev/null | cut -c1-160)"
assert_eq "no command, agent or shared rule file tells the model to read docs/rationale.md" "$READERS" ""
# NON-ZERO CONTROL: the same pattern finds a planted instruction.
printf 'Before Phase 4, read `${CLAUDE_PLUGIN_ROOT}/docs/rationale.md` now.\n' > "$NEW_TMPDIR/plant.md"
assert_eq "NON-ZERO CONTROL: the reader pattern matches a planted read instruction" \
  "$(grep -ciE '\b(read|load)\b[^.|]*docs/rationale\.md' "$NEW_TMPDIR/plant.md" | tr -d ' ')" "1"

suite "the agent contracts read their shared blocks by reference, and keep no copy of their own"

AGENT_FILES=("$PLUGIN_ROOT"/agents/*.md)
assert_eq "FIXTURE PREMISE: nine agent contracts" "${#AGENT_FILES[@]}" "9"
NO_ISO=""
for f in "${AGENT_FILES[@]}"; do
  grep -qF '${CLAUDE_PLUGIN_ROOT}/shared/tracked-write-isolation.md' "$f" || NO_ISO="$NO_ISO $(basename "$f")"
done
assert_eq "all nine point at shared/tracked-write-isolation.md" "$NO_ISO" ""
EVIDENCE_COPIES=""
NO_EV=""
for f in "${AGENT_FILES[@]}"; do
  grep -q '^## Evidence discipline' "$f" || continue
  grep -qF '${CLAUDE_PLUGIN_ROOT}/shared/evidence-discipline.md' "$f" || NO_EV="$NO_EV $(basename "$f")"
  grep -qF -- '- **A skip is not a pass.**' "$f" && EVIDENCE_COPIES="$EVIDENCE_COPIES $(basename "$f")"
done
assert_eq "every contract with an evidence-discipline section points at shared/evidence-discipline.md" "$NO_EV" ""
assert_eq "and none keeps its own copy of the compressed rules" "$EVIDENCE_COPIES" ""
assert_eq "the shared evidence file carries the compressed rules (so the pointer leads somewhere)" \
  "$(grep -cF -- '- **A skip is not a pass.**' "$SHARED_DIR/evidence-discipline.md" | tr -d ' ')" "1"
assert_eq "and still sends its reader to evidence.md and evidence-controls.md" \
  "$( { grep -qF '${CLAUDE_PLUGIN_ROOT}/evidence.md' "$SHARED_DIR/evidence-discipline.md" && grep -qF '${CLAUDE_PLUGIN_ROOT}/evidence-controls.md' "$SHARED_DIR/evidence-discipline.md"; } && echo both || echo MISSING)" "both"

suite "the property-not-the-fix block has one copy, in shared/, and every reader points at it (#164 row 4)"

# Until #164 row 4 this block sat byte-identical in the nine agent contracts and the Phase 4 panel
# preamble, ten copies held together by a sha1 digest line the model was told to maintain by hand
# and that no test read. It now lives in shared/the-property-not-the-fix.md. What can still drift is
# a prose file that KEEPS or REGROWS a copy of any paragraph of it (a partial copy drifts as surely
# as a whole one), or a reader that stops pointing at the shared file, or a digest line that comes
# back. property_block_drift reports all three for a plugin root, one line per finding, so the same
# function runs over the shipped tree and over the planted controls below.
#
# The fingerprint of a paragraph is its first 80 characters, taken from the shared file itself, so
# a rewrite of the shared text moves the fingerprints with it and no expected string lives here.
# The scan covers every agent, command and orchestrator file; the preamble is scanned like the rest,
# because it reaches the block only through its INCLUDE line and a pasted copy there would render
# the block twice.
PROPERTY_SHARED_REL="shared/the-property-not-the-fix.md"
property_block_drift() {  # <plugin root> -> COPY / NOPOINTER / NOINCLUDE / DIGEST lines, or nothing
  ROOT="$1" REL="$PROPERTY_SHARED_REL" node --input-type=module -e '
import { readFileSync, readdirSync, existsSync } from "node:fs";
import path from "node:path";
const root = process.env.ROOT, rel = process.env.REL;
const out = [];
const shared = path.join(root, rel);
if (!existsSync(shared)) { console.log("NOSHARED " + rel); process.exit(0); }
const src = readFileSync(shared, "utf8");
const body = src.slice(src.search(/^## /m));
const prints = body.split(/\n\s*\n/).map((p) => p.trim()).filter((p) => p.length >= 80 && !p.startsWith("## ")).map((p) => p.slice(0, 80));
console.log("PRINTS " + prints.length);
const list = (d) => existsSync(path.join(root, d)) ? readdirSync(path.join(root, d)).filter((f) => f.endsWith(".md")).map((f) => d + "/" + f) : [];
const files = [...list("agents"), ...list("commands"), ...list("orchestrator")];
for (const f of files) {
  const t = readFileSync(path.join(root, f), "utf8");
  prints.forEach((p, i) => { if (t.includes(p)) out.push("COPY " + f + " paragraph " + (i + 1)); });
  if (/HASHED SPAN|span.s sha1/.test(t)) out.push("DIGEST " + f);
  if (f.startsWith("agents/") && !t.includes("${CLAUDE_PLUGIN_ROOT}/" + rel)) out.push("NOPOINTER " + f);
}
const pre = path.join(root, "orchestrator/phase-4-panel-preamble.md");
const includes = existsSync(pre) ? readFileSync(pre, "utf8").split("\n").filter((l) => l === "<!-- INCLUDE " + rel + " -->").length : 0;
if (includes !== 1) out.push("NOINCLUDE orchestrator/phase-4-panel-preamble.md carries " + includes);
console.log(out.join("\n"));
'
}
DRIFT="$(property_block_drift "$PLUGIN_ROOT")"
record "property block scan over the shipped tree: $(printf '%s\n' "$DRIFT" | head -1)"
assert_eq "VACUITY: the shared file yields paragraph fingerprints (a scan with none finds no copy anywhere)" \
  "$(printf '%s\n' "$DRIFT" | awk '/^PRINTS /{print ($2 >= 5 ? "enough" : "ONLY " $2)}')" "enough"
assert_eq "no agent, command or orchestrator file carries its own copy of any paragraph, or a digest line; all nine agents point at the shared file; the preamble includes it once" \
  "$(printf '%s\n' "$DRIFT" | grep -v '^PRINTS ' | grep . | tr '\n' ';')" ""
assert_eq "the nine agents keep the section heading, so the pointer sits where the rule applies" \
  "$(grep -l '^## The property, not the fix' "$PLUGIN_ROOT"/agents/*.md | wc -l | tr -d ' ')" "9"

# NON-ZERO CONTROLS over a copy of the prose tree: each planted drift is reported by name.
new_tmpdir || exit 90
PLANT="$NEW_TMPDIR/plugin"
mkdir -p "$PLANT"
cp -R "$PLUGIN_ROOT/agents" "$PLUGIN_ROOT/commands" "$PLUGIN_ROOT/orchestrator" "$PLUGIN_ROOT/shared" "$PLANT/"
assert_eq "CONTROL premise: the unmodified copy scans clean" \
  "$(property_block_drift "$PLANT" | grep -v '^PRINTS ' | grep . | tr '\n' ';')" ""
# a paragraph pasted back into one agent contract
grep -m1 '^\*\*Measurability\.\*\*' "$PLANT/$PROPERTY_SHARED_REL" >> "$PLANT/agents/qa.md"
# the digest convention coming back in an orchestrator file
printf "\nThe span's sha1 on an undrifted tree is \`0000\`.\n" >> "$PLANT/orchestrator/phase-4-delta.md"
# a contract that stops pointing at the shared file
sed 's#shared/the-property-not-the-fix\.md#shared/elsewhere.md#g' "$PLUGIN_ROOT/agents/dev.md" > "$PLANT/agents/dev.md"
# the preamble losing its INCLUDE line
grep -v '^<!-- INCLUDE shared/the-property-not-the-fix.md -->$' "$PLUGIN_ROOT/orchestrator/phase-4-panel-preamble.md" > "$PLANT/orchestrator/phase-4-panel-preamble.md"
PLANTED="$(property_block_drift "$PLANT")"
assert_contains "NON-ZERO CONTROL: a pasted paragraph is reported as a copy, naming the file" "$PLANTED" "COPY agents/qa.md paragraph 2"
assert_contains "NON-ZERO CONTROL: a returning digest line is reported" "$PLANTED" "DIGEST orchestrator/phase-4-delta.md"
assert_contains "NON-ZERO CONTROL: an agent without the pointer is reported" "$PLANTED" "NOPOINTER agents/dev.md"
assert_contains "NON-ZERO CONTROL: a preamble without the INCLUDE line is reported" "$PLANTED" "NOINCLUDE orchestrator/phase-4-panel-preamble.md carries 0"
assert_not_contains "and the scan names only what was planted (secops.md was not touched)" "$PLANTED" "agents/secops.md"

finish
