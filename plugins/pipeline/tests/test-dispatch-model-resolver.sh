#!/usr/bin/env bash
# The dispatch model routing table and its resolver. Issue #17.
#
# THE FAIL DIRECTION HERE IS THE OPPOSITE OF THE TRIPWIRE'S, AND THAT IS DELIBERATE (C1).
# The mis-tier tripwire fails CLOSED: an unevaluable module HALTS the run. This resolver fails
# OPEN TO FRONTMATTER: any cannot-run failure means the dispatch OMITS the `model:` key so the
# agent's own frontmatter governs. Never an empty literal, never a fall-through to the session
# model (which commands/pipeline.md:359 already documents can be below opus). An implementer
# who makes the two consumers "consistent" breaks one of them; test-mis-tier-tripwire.sh's
# AC38 block asserts both directions in one run for exactly that reason.
#
# WHAT DEV MUST PROVIDE FOR THIS SUITE TO GO GREEN
# ------------------------------------------------
# A resolver script under plugins/pipeline/scripts/, REFERENCED BY THE REWIRED DISPATCH SITES
# in commands/pipeline.md (this suite discovers it from there rather than guessing a filename,
# so whatever script the orchestrator is actually told to run is the script under test),
# invoked as:
#     node <resolver> <role> <risk_tier> <phase>
# and behaving as:
#   * a NON-PINNED role resolves to exactly one allowlisted token on stdout {opus|sonnet|haiku},
#     exit 0;
#   * a PINNED role (secops, qa) prints NOTHING to stdout, exits 0, and reports
#     "pinned" on stderr -- at every tier, every phase, and under every config, including no
#     config file at all;
#   * a caller bug (unknown role, malformed risk_tier, malformed phase) exits NON-ZERO with an
#     empty stdout and a stderr diagnostic naming the bad argument;
#   * a bad CONFIG VALUE falls back to the built-in default table and REPORTS the fallback.
#
# WHY THE PIN IS "EMIT NO KEY" RATHER THAN "RESOLVE TO OPUS" (R14/SEC-12): emitting the token
# would put the resolver inside the trust path for the only two roles whose model is a security
# control, so any resolver defect returning a different ALLOWLISTED token would silently
# override frontmatter -- and the omit-on-failure backstop only helps when the key is ABSENT.
# Emitting nothing collapses that whole class and leaves exactly one way to lower them: editing
# agents/secops.md:6 or agents/qa.md:6, which the composite assertions below make load-bearing.
#
# A SPEC CONTRADICTION FOUND WHILE AUTHORING, ROUTED TO BA RATHER THAN RESOLVED HERE:
# AC18 requires the resolver to reproduce today's model "for every (role, phase) pair present
# at the seven pin sites", but two of those sites COLLIDE on one pair. The design sketches
# (pipeline.md:359) and the bake-off judge (:360) are both dispatched with
# subagent_type "dev" in Phase 2.5, pinned to "sonnet" and "opus" respectively. A resolver
# keyed on (role, risk_tier, phase) cannot return two values for (dev, architectural, 2.5), so
# that pair is UNTESTED below on purpose -- writing an assertion for it would be picking a
# resolution BA has not made. The other five pairs are asserted.

. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
require_node

make_temp_project || exit 90

PLUGIN_DIR="$PLUGIN_ROOT"
PIPELINE_MD="$PLUGIN_DIR/commands/pipeline.md"

# ---- resolver discovery, from the rewired dispatch sites --------------------
RESOLVER=""
for cand in $(grep -oE 'scripts/[a-zA-Z0-9_-]+\.mjs' "$PIPELINE_MD" | sort -u); do
  base="${cand#scripts/}"
  case "$base" in
    frontend-surface.mjs|gate-pre-phase4.mjs|gate-pre-phase4-frontend.mjs|merge-peer-review.mjs) continue ;;
    archive-pipeline.mjs|knowledge-store.mjs|validate-pipeline-artifact.mjs|voice-lint.mjs) continue ;;
    pipeline-status.mjs|config-doctor.mjs|lib.mjs|sync-manifests.mjs) continue ;;
  esac
  # The data-layer surface module is referenced from the same file by R3; it is not this.
  grep -q 'migrationGlobsForTripwire' "$PLUGIN_DIR/$cand" 2>/dev/null && continue
  RESOLVER="$PLUGIN_DIR/$cand"
  break
done

new_root() { # <name> [config-json] -> echoes the dir
  local dir="$TEMP_PROJECT/$1"
  mkdir -p "$dir"
  [[ $# -gt 1 ]] && printf '%s' "$2" > "$dir/pipeline.config.json"
  printf '%s' "$dir"
}

# Every probe below is GUARDED on the resolver existing. Without the guard, an unwired
# resolver makes `node <empty>` exit non-zero with empty stdout, and every "omits the key" and
# "prints nothing" assertion passes -- a green proving only that a path nobody built does not
# work. The guard turns the unwired state into its own visible answer.
NO_RESOLVER="ERR:no-resolver-referenced-in-commands/pipeline.md"

r_stdout() { # <project-dir> <role> <tier> <phase>
  [[ -n "$RESOLVER" ]] || { printf '%s' "$NO_RESOLVER"; return 0; }
  local pdir="$1"; shift
  ( cd "$pdir" && CLAUDE_PROJECT_DIR="$pdir" CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" \
      node "$RESOLVER" "$@" 2>/dev/null )
}
r_stderr() {
  [[ -n "$RESOLVER" ]] || { printf '%s' "$NO_RESOLVER"; return 0; }
  local pdir="$1"; shift
  ( cd "$pdir" && CLAUDE_PROJECT_DIR="$pdir" CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" \
      node "$RESOLVER" "$@" 2>&1 1>/dev/null )
}
r_rc() {
  [[ -n "$RESOLVER" ]] || { printf '%s' "$NO_RESOLVER"; return 0; }
  local pdir="$1"; shift
  ( cd "$pdir" && CLAUDE_PROJECT_DIR="$pdir" CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" \
      node "$RESOLVER" "$@" >/dev/null 2>&1 ); printf '%s' "$?"
}

# emission <project-dir> <role> <tier> <phase> -> emit:<token> | omit | ERR:...
# The dispatch site's rule, stated once: emit `model:` ONLY IF the resolver exited 0 AND
# printed exactly one token. Everything else omits the key entirely.
emission() {
  local rc out
  rc=$(r_rc "$@"); out=$(r_stdout "$@")
  case "$rc$out" in *ERR:*) printf '%s' "$NO_RESOLVER"; return 0 ;; esac
  if [[ "$rc" == "0" && "$(printf '%s' "$out" | wc -w | tr -d ' ')" == "1" ]]; then
    printf 'emit:%s' "$out"
  else
    printf 'omit'
  fi
}

# rc_class <project-dir> <role> <tier> <phase> -> nonzero | zero | ERR:...
# An unwired resolver makes r_rc return the ERR token, which is not "0" -- so a bare
# `!= "0"` test would read the ABSENCE of the resolver as the loud failure the criterion
# wants. The class function keeps the two apart.
rc_class() {
  local rc; rc=$(r_rc "$@")
  case "$rc" in ERR:*) printf '%s' "$rc" ;; 0) printf 'zero' ;; *) printf 'nonzero' ;; esac
}

R_NONE=$(new_root cfg-none)

suite "the resolver is wired in at all (the harness's own precondition)"

assert_eq "commands/pipeline.md names a model-resolver script at its dispatch sites" \
  "$([[ -n "$RESOLVER" ]] && echo yes || echo "$NO_RESOLVER")" "yes"
# NON-ZERO CONTROL for every "omit" and "prints nothing" assertion in this file: a healthy
# resolver must be OBSERVED emitting a token first, or the whole omit column is satisfied by a
# resolver that can never emit anything at all.
assert_eq "non-zero control: a non-pinned role on a healthy resolver EMITS one allowlisted token" \
  "$(emission "$R_NONE" ba standard 4)" "emit:sonnet"

# =============================================================================
# AC20 -- THE PINNED ROLES EMIT NO MODEL KEY. {secops, qa} x {4 config states} x {3 tiers}.
# =============================================================================
suite "AC20: secops and qa emit NO model: key, in every cell"

R_HAIKU=$(new_root cfg-haiku '{"dispatchModels":{"secops":"haiku","qa":"haiku"}}')
R_SONNET=$(new_root cfg-sonnet '{"dispatchModels":{"secops":"sonnet","qa":"sonnet"}}')
R_FULLID=$(new_root cfg-fullid '{"dispatchModels":{"secops":"claude-haiku-4-5-20251001","qa":"claude-haiku-4-5-20251001"}}')

for role in secops qa; do
  for tier in trivial standard architectural; do
    # The no-config cell is MANDATORY and is the cell that proves the guarantee is a PIN
    # rather than a config filter: with no config file at all there is nothing to filter.
    # trivial is where a cost-minded editor reaches first, and its entire panel is "qa secops".
    assert_eq "no config at all: $role on the $tier tier emits no model key" \
      "$(emission "$R_NONE" "$role" "$tier" 4)" "omit"
    assert_eq "config says haiku: $role on the $tier tier still emits no model key" \
      "$(emission "$R_HAIKU" "$role" "$tier" 4)" "omit"
    assert_eq "config says sonnet: $role on the $tier tier still emits no model key" \
      "$(emission "$R_SONNET" "$role" "$tier" 4)" "omit"
    assert_eq "config says an unranked full model ID: $role on the $tier tier still emits no model key" \
      "$(emission "$R_FULLID" "$role" "$tier" 4)" "omit"
  done
done

suite "AC20: the pin exits 0 and REPORTS, so an ignored config entry is never silent"

assert_eq "a pinned role exits 0 (it is not a failure, it is a decision)" "$(rc_class "$R_NONE" secops standard 4)" "zero"
assert_contains "a pinned role reports 'pinned' on stderr" "$(r_stderr "$R_NONE" secops standard 4)" "pinned"
assert_contains "an IGNORED config entry for a pinned role is reported, never silently honored" \
  "$(r_stderr "$R_HAIKU" secops standard 4)" "secops"
assert_contains "the same for qa" "$(r_stderr "$R_HAIKU" qa standard 4)" "qa"

suite "AC20 COMPOSITE: with no key emitted, the two roles run on opus BECAUSE frontmatter pins it"

# Asserted directly, because it is what makes the omission SAFE. If either frontmatter line is
# ever lowered, the pin becomes a silent downgrade of the veto and the binding test verdict,
# and this assertion is the only thing that would say so.
assert_eq "agents/secops.md frontmatter pins model: opus" \
  "$(grep -c '^model: opus$' "$PLUGIN_DIR/agents/secops.md" | tr -d ' ')" "1"
assert_eq "agents/qa.md frontmatter pins model: opus" \
  "$(grep -c '^model: opus$' "$PLUGIN_DIR/agents/qa.md" | tr -d ' ')" "1"

# =============================================================================
# AC44 -- ROLE-KEY NORMALIZATION CANNOT LEAK INTO A PINNED ROLE.
# The defeat this guards: an accepted-role-set exclusion applied to RAW config keys with
# normalization running afterwards, so {"dispatchModels":{"SecOps":"haiku"}} survives the
# exclusion and normalizes INTO the pinned role. Every lowercase cell stays green under that
# defect, which is exactly how it hides. Role-key variance is LIVE in this repo already
# (design/design_review, art-director/art_director).
# =============================================================================
suite "AC44: the ROLE ARGUMENT is normalized before the pin is consulted"

for v in secops SecOps SECOPS sec_ops sec-ops; do
  assert_eq "role argument '$v' resolves to the pinned role and emits no model key" \
    "$(emission "$R_NONE" "$v" standard 4)" "omit"
done
for v in qa QA Qa; do
  assert_eq "role argument '$v' resolves to the pinned role and emits no model key" \
    "$(emission "$R_NONE" "$v" standard 4)" "omit"
done

suite "AC44: the CONFIG KEY is normalized too -- a different call path into the same normalizer"

for v in secops SecOps SECOPS sec_ops sec-ops; do
  RV=$(new_root "cfg-key-$v" "{\"dispatchModels\":{\"$v\":\"haiku\"}}")
  assert_eq "config keyed '$v' cannot reach the pinned role" "$(emission "$RV" secops standard 4)" "omit"
  assert_contains "and the ignored entry keyed '$v' is REPORTED" "$(r_stderr "$RV" secops standard 4)" "secops"
done
for v in qa QA Qa; do
  RV=$(new_root "cfg-key-qa-$v" "{\"dispatchModels\":{\"$v\":\"haiku\"}}")
  assert_eq "config keyed '$v' cannot reach the pinned qa role" "$(emission "$RV" qa standard 4)" "omit"
done

# =============================================================================
# AC21 -- THE OVER-REFUSAL GUARD. The pin must not become a global ceiling, a global floor,
# or "emit no key for anyone".
# =============================================================================
suite "AC21: a NON-pinned role stays freely configurable in BOTH directions"

R_RAISE=$(new_root cfg-raise '{"dispatchModels":{"design_review":"opus"}}')
R_LOWER=$(new_root cfg-lower '{"dispatchModels":{"ba":"haiku"}}')

assert_eq "raising design_review from its default to opus is HONORED (not clamped down)" \
  "$(emission "$R_RAISE" design_review standard 4)" "emit:opus"
assert_eq "lowering ba to an allowlisted haiku is HONORED (the pin is not a global floor)" \
  "$(emission "$R_LOWER" ba standard 4)" "emit:haiku"
assert_eq "and the no-key rule did NOT become 'emit no key for anyone'" \
  "$(emission "$R_NONE" dev 4 4 2>/dev/null; emission "$R_NONE" ba standard 4)" "emit:sonnet"

# =============================================================================
# AC30 -- RESOLVER FAILURE OMITS THE MODEL KEY. One rule, five failure classes.
# =============================================================================
suite "AC30: a CALLER bug fails LOUDLY (non-zero + stderr naming the bad argument) and still omits"

R_UNPARSEABLE=$(new_root cfg-unparseable '{"dispatchModels": { this is not json')

assert_eq "(b) an unparseable pipeline.config.json still resolves a non-pinned role from the defaults" \
  "$(emission "$R_UNPARSEABLE" ba standard 4)" "emit:sonnet"
assert_eq "(c) an UNKNOWN role exits non-zero" "$(rc_class "$R_NONE" nonsense standard 4)" "nonzero"
assert_eq "(c) an unknown role prints NOTHING to stdout, so the key is omitted" \
  "$(emission "$R_NONE" nonsense standard 4)" "omit"
assert_contains "(c) and names the bad argument on stderr" "$(r_stderr "$R_NONE" nonsense standard 4)" "nonsense"

# A valid role with a malformed risk_tier or phase is a CALLER bug too, exactly like an unknown
# role. It must NEVER silently resolve against a different row: the seven call sites are
# authored once, so a wrong row would be permanent and invisible.
assert_eq "(c) a valid role with a MALFORMED risk_tier exits non-zero" "$(rc_class "$R_NONE" ba nonsense-tier 4)" "nonzero"
assert_eq "(c) ...and omits the key rather than silently selecting the 'standard' row" \
  "$(emission "$R_NONE" ba nonsense-tier 4)" "omit"
assert_contains "(c) ...naming the bad argument" "$(r_stderr "$R_NONE" ba nonsense-tier 4)" "nonsense-tier"
assert_eq "(c) a valid role with a MALFORMED phase exits non-zero" "$(rc_class "$R_NONE" ba standard 99-not-a-phase)" "nonzero"
assert_eq "(c) ...and omits the key" "$(emission "$R_NONE" ba standard 99-not-a-phase)" "omit"
assert_contains "(c) ...naming the bad argument" "$(r_stderr "$R_NONE" ba standard 99-not-a-phase)" "99-not-a-phase"

suite "AC30(d): stdout that is not EXACTLY one allowlisted token omits the key"

# Asserted through the emission rule rather than by mocking the resolver's stdout: the rule the
# dispatch site implements is the conjunction (exit 0 AND exactly one token), and these two
# cases pin the "exactly one token" half from both sides.
assert_eq "empty stdout omits (never an empty literal, never a session-model fall-through)" \
  "$(emission "$R_NONE" secops standard 4)" "omit"
assert_eq "a real single token emits" "$(emission "$R_NONE" ba standard 4)" "emit:sonnet"

suite "AC30(a): with the resolver ABSENT, secops and qa still run opus -- via frontmatter"

# The composite backstop, and (d) in the mutation list is a structural check: delete the
# frontmatter pin from agents/secops.md and this assertion is what reddens.
# The absent case is exercised by pointing at a script that is really not there, NOT by
# blanking the discovery variable: blanking it would test the harness's own guard rather than
# the resolver's behavior, and would pass identically before and after Dev writes anything.
assert_eq "non-zero control: the DISCOVERED resolver emits, so 'absent omits' is not vacuous" \
  "$(emission "$R_NONE" ba standard 4)" "emit:sonnet"
assert_eq "resolver script ABSENT: the dispatch omits the model key rather than halting" \
  "$( RESOLVER="$TEMP_PROJECT/not-installed-resolver.mjs"; emission "$R_NONE" ba standard 4 )" "omit"
assert_eq "resolver absent: secops therefore runs on opus, from agents/secops.md:6" \
  "$(grep -c '^model: opus$' "$PLUGIN_DIR/agents/secops.md" | tr -d ' ')" "1"

# =============================================================================
# AC31 -- A MALFORMED TABLE FAILS SOFT, AND REPORTS. Fail-soft without a report is how a
# config typo becomes permanent.
# =============================================================================
suite "AC31: a bad CONFIG VALUE falls back to the default table and says so"

R_WRONGTYPE=$(new_root cfg-dm-wrongtype '{"dispatchModels":"not-an-object"}')
R_UNKNOWNROLE=$(new_root cfg-dm-unknownrole '{"dispatchModels":{"nonsense_role":"opus"}}')
R_BADVALUE=$(new_root cfg-dm-badvalue '{"dispatchModels":{"ba":"sonnnet"}}')
R_NULLVALUE=$(new_root cfg-dm-null '{"dispatchModels":{"ba":null}}')
R_NUMVALUE=$(new_root cfg-dm-num '{"dispatchModels":{"ba":3}}')
R_EMPTYVALUE=$(new_root cfg-dm-empty '{"dispatchModels":{"ba":""}}')
R_FULLIDBA=$(new_root cfg-dm-fullid '{"dispatchModels":{"ba":"claude-haiku-4-5-20251001"}}')

assert_eq "dispatchModels is the wrong type: ba resolves from the DEFAULT table" "$(emission "$R_WRONGTYPE" ba standard 4)" "emit:sonnet"
assert_eq "an unknown role KEY does not wedge a known role" "$(emission "$R_UNKNOWNROLE" ba standard 4)" "emit:sonnet"
assert_eq "a typo'd model value falls back to the default" "$(emission "$R_BADVALUE" ba standard 4)" "emit:sonnet"
assert_eq "a null value falls back" "$(emission "$R_NULLVALUE" ba standard 4)" "emit:sonnet"
assert_eq "a numeric value falls back" "$(emission "$R_NUMVALUE" ba standard 4)" "emit:sonnet"
assert_eq "an empty-string value falls back" "$(emission "$R_EMPTYVALUE" ba standard 4)" "emit:sonnet"
# The allowlist is over the RESOLVED value, not a three-row rank table over three spellings:
# the harness resolves aliases, so a full model ID is a value that gets transformed before it
# acts. Rejecting it here is the guard-where-it-landed rule.
assert_eq "a pinned full model ID is REJECTED by the allowlist and falls back" "$(emission "$R_FULLIDBA" ba standard 4)" "emit:sonnet"
assert_contains "the rejection is REPORTED, not silent" "$(r_stderr "$R_BADVALUE" ba standard 4)" "sonnnet"
assert_contains "the full-ID rejection is REPORTED too" "$(r_stderr "$R_FULLIDBA" ba standard 4)" "claude-haiku-4-5-20251001"
assert_eq "and the run is not wedged: exit stays 0 for a bad config value" "$(rc_class "$R_BADVALUE" ba standard 4)" "zero"

# =============================================================================
# AC18 -- BEHAVIOR-NEUTRAL DEFAULTS, asserted PAIR BY PAIR, not claimed in prose.
# =============================================================================
suite "AC18: the default table reproduces today's assignment at each pin site"

assert_eq "the Phase 0.5 map dispatch stays sonnet"       "$(emission "$R_NONE" ba architectural 0.5)" "emit:sonnet"
assert_eq "the BA Phase 4 lens stays sonnet"              "$(emission "$R_NONE" ba architectural 4)" "emit:sonnet"
assert_eq "the Dev Phase 4 lens stays sonnet"             "$(emission "$R_NONE" dev architectural 4)" "emit:sonnet"
assert_eq "the SecOps Phase 4 lens carries no override"   "$(emission "$R_NONE" secops architectural 4)" "omit"
assert_eq "the QA Phase 4 lens carries no override"       "$(emission "$R_NONE" qa architectural 4)" "omit"
# (dev, architectural, 2.5) is deliberately NOT asserted: the sketches pin sonnet and the judge
# pins opus at the same (role, tier, phase), which a resolver on that signature cannot satisfy.
# Routed to BA as a spec contradiction rather than resolved by QA picking a winner.

suite "AC18: the roles with no pin site keep their FRONTMATTER model unchanged"

# "Unchanged" is a statement about the EFFECTIVE model, so it is asserted that way: the token
# the resolver emits if it emits one, otherwise the frontmatter value. Asserting only "the
# resolver emits nothing" would pass a table that had silently started overriding them.
effective() { # <project-dir> <role> <tier> <phase> <frontmatter-file>
  local e; e=$(emission "$1" "$2" "$3" "$4")
  case "$e" in
    emit:*) printf '%s' "${e#emit:}" ;;
    omit) grep -m1 '^model: ' "$5" | sed 's/^model: //' ;;
    *) printf '%s' "$e" ;;
  esac
}
assert_eq "dba's effective Phase 4 model is still opus"     "$(effective "$R_NONE" dba architectural 4 "$PLUGIN_DIR/agents/dba.md")" "opus"
assert_eq "devops's effective Phase 4 model is still sonnet" "$(effective "$R_NONE" devops architectural 4 "$PLUGIN_DIR/agents/devops.md")" "sonnet"
assert_eq "design_review's effective Phase 4 model is still sonnet" "$(effective "$R_NONE" design_review architectural 4 "$PLUGIN_DIR/agents/design.md")" "sonnet"
assert_eq "art_director's effective Phase 4 model is still opus" "$(effective "$R_NONE" art_director architectural 4 "$PLUGIN_DIR/agents/art-director.md")" "opus"
assert_eq "librarian's effective Phase 5 model is still sonnet"  "$(effective "$R_NONE" librarian architectural 5 "$PLUGIN_DIR/agents/librarian.md")" "sonnet"

# =============================================================================
# AC22 / AC19 -- the shipped defaults and the removal of the inline literals.
# =============================================================================
suite "AC22: 'haiku' appears nowhere in the shipped DEFAULT routing table"

# Asserted against the resolved output over the whole role x tier x phase space the pipeline
# can emit, not by grepping a source file: a source grep is defeated by a computed string,
# and AC21 above proves haiku is still REACHABLE via config, so this is a statement about the
# defaults and not about the allowlist.
# A cell that returns something UNUSABLE counts as a violation, not as a non-haiku: a sweep
# over 189 error strings would otherwise report a confident zero about a table that does not
# exist. This is the same vacuity the non-zero control below guards from the other side.
HAIKU_DEFAULTS=0
SWEEP_BAD=0
for role in ba dba devops secops dev qa design_review art_director librarian; do
  for tier in trivial standard architectural; do
    for ph in 0.5 1 2 2.5 3 4 5; do
      out=$(r_stdout "$R_NONE" "$role" "$tier" "$ph")
      case "$out" in
        haiku) HAIKU_DEFAULTS=$((HAIKU_DEFAULTS + 1)) ;;
        opus|sonnet|"") ;;
        *) SWEEP_BAD=$((SWEEP_BAD + 1)) ;;
      esac
    done
  done
done
assert_eq "every swept cell returned a usable answer (without this, the zero below is vacuous)" "$SWEEP_BAD" "0"
assert_eq "no (role, tier, phase) cell resolves to haiku under the shipped defaults" "$HAIKU_DEFAULTS" "0"
# NON-ZERO CONTROL for that zero: the same sweep must be able to SEE a haiku when one exists,
# or "0" is a statement about a loop that never looked.
assert_eq "control: the same probe DOES report haiku when a config sets it" \
  "$(r_stdout "$R_LOWER" ba standard 4)" "haiku"

suite "AC19: no inline model literal survives in a dispatch block"

# NON-ZERO CONTROL, observed at origin/main before the fix: this grep returns 4 at HEAD
# (commands/pipeline.md:359, :360, :669, :673). The assertion therefore starts RED, and its
# going green is an observation rather than an assumption about a pattern that never matched.
assert_eq "no Agent({...}) dispatch carries an inline model: literal" \
  "$(grep -c 'Agent({.*model: "' "$PIPELINE_MD" | tr -d ' ')" "0"
PROBE="$TEMP_PROJECT/model-literal-probe.md"
printf '%s\n' 'Agent({subagent_type: "ba", model: "sonnet", description: "x"})' > "$PROBE"
assert_eq "control: the same grep DOES find a byte-identical inline literal" \
  "$(grep -c 'Agent({.*model: "' "$PROBE" | tr -d ' ')" "1"

finish
