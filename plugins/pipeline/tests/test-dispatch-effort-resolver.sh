#!/usr/bin/env bash
# The dispatch EFFORT routing table and its resolver. Issue #101.
#
# THE CLAIM THIS SUITE EXISTS TO KEEP HONEST: effort has no per-dispatch surface on the Agent
# tool. `model` is an Agent parameter, so dispatch-model.mjs resolves a value and the site emits
# it. There is no `effort` parameter. So the resolver's `agent` surface MUST print nothing, and
# a future edit that "helpfully" makes it print the table value would produce a routing table
# that lies about the routing: every reader downstream, a cost model and an incident review
# included, would reason off a value nothing ever sent. That is the regression this file is
# aimed at, and it is why the agent-surface assertions below are stated as a SET over every
# role x tier rather than spot-checked.
#
# SECOND CLAIM, from SecOps's #101 q2 ruling: there is NO RANK ORDER in the resolver. An earlier
# draft carried a raise-only floor, which needs a comparison over five levels; SecOps refused it
# because that comparison is code inside the veto trust path whose likeliest defect lowers
# silently ("max" < "medium" lexicographically). The pin replaced it. A future reintroduction of
# a rank table is a real regression and is asserted against here, with a control.

. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
require_node

make_temp_project || exit 90

PLUGIN_DIR="$PLUGIN_ROOT"
PIPELINE_MD="$PLUGIN_DIR/commands/pipeline.md"
AGENTS_DIR="$PLUGIN_DIR/agents"

suite "#101: the dispatch effort table, its surfaces, and its pins"

# ---- resolver discovery, from the dispatch-site documentation ----------------
# Discovered from commands/pipeline.md rather than hardcoded, for the same reason the model
# suite does it: whatever script the orchestrator is actually TOLD to run is the script under
# test. A resolver that exists but is documented nowhere is not wired.
RESOLVER=""
for cand in $(grep -oE 'scripts/[a-zA-Z0-9_-]+\.mjs' "$PIPELINE_MD" | sort -u); do
  case "${cand#scripts/}" in
    dispatch-effort.mjs) RESOLVER="$PLUGIN_DIR/$cand"; break ;;
  esac
done

NO_RESOLVER="ERR:no-effort-resolver-referenced-in-commands/pipeline.md"

e_stdout() { # <project-dir> <args...>
  [[ -n "$RESOLVER" ]] || { printf '%s' "$NO_RESOLVER"; return 0; }
  local pdir="$1"; shift
  ( cd "$pdir" && CLAUDE_PROJECT_DIR="$pdir" CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" \
      node "$RESOLVER" "$@" 2>/dev/null )
}
e_stderr() {
  [[ -n "$RESOLVER" ]] || { printf '%s' "$NO_RESOLVER"; return 0; }
  local pdir="$1"; shift
  ( cd "$pdir" && CLAUDE_PROJECT_DIR="$pdir" CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" \
      node "$RESOLVER" "$@" 2>&1 1>/dev/null )
}
e_rc() {
  [[ -n "$RESOLVER" ]] || { printf '%s' "$NO_RESOLVER"; return 0; }
  local pdir="$1"; shift
  ( cd "$pdir" && CLAUDE_PROJECT_DIR="$pdir" CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" \
      node "$RESOLVER" "$@" >/dev/null 2>&1 ); printf '%s' "$?"
}

# emission -> emit:<token> | omit | ERR:...
emission() {
  local out; out="$(e_stdout "$@")"
  case "$out" in
    "$NO_RESOLVER") printf '%s' "$out" ;;
    "") printf 'omit' ;;
    *) printf 'emit:%s' "$(printf '%s' "$out" | tr -d '\n')" ;;
  esac
}

new_root() { # <name> [config-json] -> echoes the dir
  local dir="$TEMP_PROJECT/$1"
  mkdir -p "$dir"
  [[ $# -gt 1 ]] && printf '%s' "$2" > "$dir/pipeline.config.json"
  printf '%s' "$dir"
}

R_NONE="$(new_root none)"
ROLES="ba dba devops secops dev qa design_review art_director librarian"
TIERS="trivial standard architectural"

assert_eq "commands/pipeline.md names an effort-resolver script at its dispatch sites" \
  "$([[ -n "$RESOLVER" ]] && echo yes || echo no)" "yes"

# ---- NON-ZERO CONTROL ------------------------------------------------------
# Every "prints nothing" assertion below is worthless unless this resolver CAN print. Observed
# first, so an `omit` result later is a fact about the surface and not about a broken script.
assert_eq "NON-ZERO CONTROL: the workflow surface DOES emit one allowlisted token" \
  "$(emission "$R_NONE" librarian standard 5 --surface workflow)" "emit:medium"

# ---- the agent surface emits nothing, as a SET -----------------------------
AGENT_EMISSIONS=""
for role in $ROLES; do
  for tier in $TIERS; do
    AGENT_EMISSIONS="$AGENT_EMISSIONS$(emission "$R_NONE" "$role" "$tier" 4)
"
  done
done
assert_eq "the agent surface emits NO effort for any role at any tier (27 cells, stated as a set)" \
  "$(printf '%s' "$AGENT_EMISSIONS" | sort -u | tr -d '\n')" "omit"
assert_eq "REPORTED so the set above cannot range over an empty population: cells observed" \
  "$(printf '%s' "$AGENT_EMISSIONS" | grep -c .)" "27"
assert_eq "the agent surface is the DEFAULT (no --surface behaves as --surface agent)" \
  "$(emission "$R_NONE" ba standard 4)" "$(emission "$R_NONE" ba standard 4 --surface agent)"
assert_contains "and it SAYS why, naming the missing parameter rather than failing silently" \
  "$(e_stderr "$R_NONE" ba standard 4)" "no effort parameter"
assert_eq "a role WITH a workflow table row still emits nothing on the agent surface" \
  "$(emission "$R_NONE" ba architectural 0.5 --site map)" "omit"
assert_eq "control: that same row DOES emit on the workflow surface" \
  "$(emission "$R_NONE" ba architectural 0.5 --site map --surface workflow)" "emit:medium"

# ---- the workflow surface ALWAYS emits (no omission, #101 q3) --------------
# Omitting is not a safe default here: the vendor doc says an omitted effort inherits the
# SESSION effort while #98 observed frontmatter, and a session at `low` makes those differ in
# the direction that matters. So a role with NO table row must still emit explicitly.
WF_OMITS=""
for role in $ROLES; do
  for tier in $TIERS; do
    [[ "$(emission "$R_NONE" "$role" "$tier" 4 --surface workflow)" == "omit" ]] && \
      WF_OMITS="$WF_OMITS $role/$tier"
  done
done
assert_eq "the workflow surface NEVER omits, for any role at any tier (the omission is the bug)" \
  "$(printf '%s' "$WF_OMITS")" ""
assert_eq "an UNROWED role emits its frontmatter value explicitly rather than omitting" \
  "$(emission "$R_NONE" librarian standard 5 --surface workflow)" "emit:medium"

# ---- effort is TIERED on the Phase 4 panel, and no role is pinned (0.40.0) ----------------
# The earlier pin (SecOps xhigh at every tier, QA high) was a security ruling from #101 q2. It
# was retired when the materiality rule took over the risk it carried: the archive showed the
# pin's cost as the largest consumer of run time. Both directions are pinned here: the tiered
# rows resolve as stated, and config can now move these two roles like any other.
assert_eq "SecOps runs xhigh on an ARCHITECTURAL panel" \
  "$(emission "$R_NONE" secops architectural 4 --surface workflow)" "emit:xhigh"
assert_eq "SecOps runs high on a STANDARD panel" \
  "$(emission "$R_NONE" secops standard 4 --surface workflow)" "emit:high"
assert_eq "SecOps runs medium on a TRIVIAL panel" \
  "$(emission "$R_NONE" secops trivial 4 --surface workflow)" "emit:medium"
assert_eq "QA runs high on an ARCHITECTURAL panel" \
  "$(emission "$R_NONE" qa architectural 4 --surface workflow)" "emit:high"
assert_eq "QA runs medium on a STANDARD panel" \
  "$(emission "$R_NONE" qa standard 4 --surface workflow)" "emit:medium"
assert_eq "DBA runs medium on a STANDARD panel (frontmatter high applies at architectural)" \
  "$(emission "$R_NONE" dba standard 4 --surface workflow)/$(emission "$R_NONE" dba architectural 4 --surface workflow)" "emit:medium/emit:high"
assert_eq "a tier row does not leak into another phase: SecOps at Phase 2 is its frontmatter" \
  "$(emission "$R_NONE" secops architectural 2 --surface workflow)" "emit:xhigh"
R_LOW_SEC="$(new_root lowsec '{"dispatchEfforts":{"secops":"low"}}')"
R_HI_QA="$(new_root hiqa '{"dispatchEfforts":{"qa":"xhigh"}}')"
assert_eq "config CAN lower secops now (the pin is gone)" \
  "$(emission "$R_LOW_SEC" secops standard 4 --surface workflow)" "emit:low"
assert_eq "and raise qa" \
  "$(emission "$R_HI_QA" qa trivial 4 --surface workflow)" "emit:xhigh"
assert_eq "no role reports itself pinned any more" \
  "$(e_stderr "$R_NONE" secops standard 4 | grep -c pinned | tr -d ' ')" "0"

# ---- non-pinned roles stay configurable in both directions -----------------
R_RAISE="$(new_root raise '{"dispatchEfforts":{"librarian":"high"}}')"
R_LOWER="$(new_root lower '{"dispatchEfforts":{"dba":"low"}}')"
assert_eq "raising a non-pinned role is honored" \
  "$(emission "$R_RAISE" librarian standard 5 --surface workflow)" "emit:high"
assert_eq "lowering a non-pinned role is honored, so the pin is not a global floor" \
  "$(emission "$R_LOWER" dba standard 4 --surface workflow)" "emit:low"

R_BAD="$(new_root bad '{"dispatchEfforts":{"librarian":"ultra"}}')"
assert_eq "an off-allowlist config value falls back to the default table" \
  "$(emission "$R_BAD" librarian standard 5 --surface workflow)" "emit:medium"
assert_contains "and the rejection is REPORTED" \
  "$(e_stderr "$R_BAD" librarian standard 5 --surface workflow)" "REJECTED"

# ---- site disambiguation, same shape as the model table --------------------
assert_eq "the two (dev, 2.5) sites carry DIFFERENT efforts and do not collapse" \
  "$(emission "$R_NONE" dev architectural 2.5 --site design-sketch --surface workflow)/$(emission "$R_NONE" dev architectural 2.5 --site bakeoff-judge --surface workflow)" \
  "emit:medium/emit:high"
R_DEV="$(new_root devcfg '{"dispatchEfforts":{"dev":"low"}}')"
assert_eq "a role-level key cannot name one of two differing sites, so it is refused there" \
  "$(emission "$R_DEV" dev architectural 2.5 --site bakeoff-judge --surface workflow)" "emit:high"
assert_contains "and that refusal is REPORTED" \
  "$(e_stderr "$R_DEV" dev architectural 2.5 --surface workflow)" "IGNORED for this phase"

# ---- caller bugs exit non-zero with empty stdout ---------------------------
assert_eq "an unknown role is a caller bug: exit 2, nothing on stdout" \
  "$(e_rc "$R_NONE" nosuchrole standard 4 --surface workflow)/$(emission "$R_NONE" nosuchrole standard 4 --surface workflow)" "2/omit"
assert_eq "a malformed tier is a caller bug" \
  "$(e_rc "$R_NONE" ba nosuchtier 4 --surface workflow)" "2"
assert_eq "a malformed phase is a caller bug" \
  "$(e_rc "$R_NONE" ba standard 99 --surface workflow)" "2"
assert_eq "an unknown SURFACE is a caller bug, not a silent fallback to agent" \
  "$(e_rc "$R_NONE" ba standard 4 --surface nosuchsurface)" "2"
assert_eq "a tiered role on the agent surface still exits 0 (frontmatter governs there)" \
  "$(e_rc "$R_NONE" secops standard 4)" "0"

# ---- THE LIVE CONSUMER: frontmatter parity ---------------------------------
# FRONTMATTER_EFFORT in the resolver is the written-down answer to "what effort does each role
# run at". On the Agent surface it is the ONLY answer that reaches inference, so it drifting
# from the files is the table quietly describing a pipeline that no longer exists.
DRIFT=""
CHECKED=0
for f in "$AGENTS_DIR"/*.md; do
  fm_name="$(awk -F': *' '/^name:/{print $2; exit}' "$f")"
  fm_effort="$(awk -F': *' '/^effort:/{print $2; exit}' "$f")"
  [[ -n "$fm_name" && -n "$fm_effort" ]] || continue
  CHECKED=$((CHECKED + 1))
  # The resolver's agent-surface stderr names the frontmatter value it believes; compare that
  # to the file itself rather than re-reading the resolver's source, so the assertion spans the
  # seam instead of checking one side against itself.
  said="$(e_stderr "$R_NONE" "$fm_name" standard 4 | grep -oE 'declares [a-z]+' | awk '{print $2}')"
  [[ "$said" == "$fm_effort" ]] || DRIFT="$DRIFT $fm_name(file=$fm_effort,resolver=$said)"
done
assert_eq "REPORTED, so the parity assertion below cannot range over an empty population: agent files checked" \
  "$CHECKED" "9"
assert_eq "the resolver's frontmatter map matches every agents/*.md file, with no drift" \
  "$(printf '%s' "$DRIFT")" ""

# CONTROL on the parity check itself: an empty hit list is only a finding if the same comparison
# can report a hit. Feed it a role whose declared value we know differs from the file.
assert_contains "CONTROL: the same comparison reports a MISMATCH when one is planted" \
  "$( said="$(e_stderr "$R_NONE" librarian standard 4 | grep -oE 'declares [a-z]+' | awk '{print $2}')"
     [[ "$said" == "high" ]] && printf 'no-mismatch' || printf "mismatch(resolver=$said,planted=high)" )" \
  "mismatch"

# ---- SecOps's ruling, enforced: no rank order in the resolver ---------------
assert_eq "there is NO rank table in the resolver (SecOps refused the raise-only clamp)" \
  "$(grep -cE 'EFFORT_RANK|floorFor|ROLE_FLOORS' "$RESOLVER" | tr -d ' ')" "0"
RANK_PROBE="$TEMP_PROJECT/rank-probe.mjs"
printf '%s\n' 'export const EFFORT_RANK = { low: 0 };' > "$RANK_PROBE"
assert_eq "CONTROL: the same grep DOES find a byte-identical rank table when one exists" \
  "$(grep -cE 'EFFORT_RANK|floorFor|ROLE_FLOORS' "$RANK_PROBE" | tr -d ' ')" "1"

# ---- no dispatch site grew an effort: key -----------------------------------
assert_eq "no Agent({...}) dispatch carries an inline effort: key (there is no such parameter)" \
  "$(grep -c 'Agent({.*effort:' "$PIPELINE_MD" | tr -d ' ')" "0"
EFFORT_PROBE="$TEMP_PROJECT/effort-literal-probe.md"
printf '%s\n' 'Agent({subagent_type: "ba", effort: "high", description: "x"})' > "$EFFORT_PROBE"
assert_eq "CONTROL: the same grep DOES find a byte-identical inline effort key" \
  "$(grep -c 'Agent({.*effort:' "$EFFORT_PROBE" | tr -d ' ')" "1"

finish
