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
assert_eq "the renderer's preamble markers stay in the core, the one file scripts/render-panel.mjs reads" \
  "$(grep -c '^<!-- BEGIN PHASE4-PREAMBLE -->$\|^<!-- END PHASE4-PREAMBLE -->$' "$CORE" | tr -d ' ')" "2"
assert_eq "and appear in no phase file (a second copy would be a preamble the renderer never renders)" \
  "$(cat "$PARTS_DIR"/*.md | grep -cE '^<!-- (BEGIN|END) PHASE4-PREAMBLE -->$' | tr -d ' ')" "0"

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

finish
