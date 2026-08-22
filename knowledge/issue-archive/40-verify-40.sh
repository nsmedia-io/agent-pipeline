#!/usr/bin/env bash
# =============================================================================
# verify-40.sh -- the QA Phase 3a verification battery for issue #40.
#
# THIS IS A COMMAND, NOT A CI GATE. Nothing runs it automatically. It is not
# registered anywhere, it is not globbed by plugins/pipeline/tests/run.sh, and
# it lives in a gitignored artifact directory on purpose: this change may not
# add a file under tests/, hooks/, .github/workflows/ or scripts/ (AC5), so the
# strongest control available is a command a human runs. It is strictly better
# than reviewer eyes and strictly weaker than a test. Read that sentence twice
# before you cite a green run of this file as evidence of anything.
#
# RUN IT:
#     bash .pipeline/40/verify-40.sh                  # every cell, against this worktree
#     bash .pipeline/40/verify-40.sh --only 'AC4.*'   # one cell or one glob of cells
#     bash .pipeline/40/verify-40.sh --controls       # the non-zero control battery
#
# EXIT: 0 only when every cell PASSes and no cell SKIPs. A SKIP is not a pass
# and never contributes to a zero exit.
#
# EACH CELL declares the state it is EXPECTED to be in at the merge base, before
# Dev implements anything: [base:RED] means the implementation is absent so the
# cell must fail now; [base:GREEN] means the cell passes at the merge base and
# is a NON-REGRESSION check, not coverage. A cell that fails while declaring
# base:GREEN is the loud one: something unrelated to the missing implementation
# is wrong (a broken harness, a stale rebase, a fixture that rotted).
#
# WHAT THIS BATTERY DOES NOT DISCHARGE is printed at the end, every run, under
# MANUAL. AC3's two-reader classification, AC13's loaded-command rendering.
# Do not read a zero exit as covering them.
# =============================================================================

set -uo pipefail

# ---- location ---------------------------------------------------------------
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/../.." && pwd)"
SRC="$REPO"                # content root for file-content cells (--src overrides)
ONLY='*'
SKIPPAT=''   # --skip <glob>: a matched cell reports SKIP, which is NOT a pass and
             # keeps the exit non-zero. Provided for `--skip 'AC5.suite'`, which
             # takes several minutes; it is a way to defer a cell, never to drop it.
MODE=run

while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; SRC="$2"; shift 2;;
    --src) SRC="$2"; shift 2;;
    --only) ONLY="$2"; shift 2;;
    --skip) SKIPPAT="$2"; shift 2;;
    --controls) MODE=controls; shift;;
    -h|--help) sed -n '2,30p' "${BASH_SOURCE[0]}"; exit 0;;
    *) echo "unknown argument: $1" >&2; exit 64;;
  esac
done

PP="$SRC/plugins/pipeline"
RS="$PP/schemas/review.schema.json"
PS="$PP/schemas/peer-review.schema.json"
CMD="$PP/commands/pipeline.md"
TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/verify40.XXXXXX")"
trap 'rm -rf "$TMPROOT"' EXIT

# ---- reporting --------------------------------------------------------------
PASS_N=0; FAIL_N=0; SKIP_N=0; SURPRISE_N=0
FAILED=""
B=RED   # per-cell expected state at the merge base; set before each cell

ok()   { printf 'PASS  [base:%-5s] %-26s %s\n' "$B" "$1" "$2"; PASS_N=$((PASS_N+1)); }
no()   { printf 'FAIL  [base:%-5s] %-26s %s\n' "$B" "$1" "$2"; FAIL_N=$((FAIL_N+1)); FAILED="$FAILED $1"
         if [ "$B" = GREEN ]; then SURPRISE_N=$((SURPRISE_N+1)); fi; }
skip() { printf 'SKIP  [base:%-5s] %-26s %s\n' "$B" "$1" "$2"; SKIP_N=$((SKIP_N+1)); FAILED="$FAILED $1(skip)"; }
detail(){ printf '                     | %s\n' "$1"; }
want() {
  case "$1" in $ONLY) ;; *) return 1;; esac
  if [ -n "$SKIPPAT" ]; then
    case "$1" in $SKIPPAT) skip "$1" 'deferred by --skip (a deferral is not a pass; exit stays non-zero)'; return 1;; esac
  fi
  return 0
}

assert_eq() { # id label got expected
  if [ "$3" = "$4" ]; then ok "$1" "$2"
  else no "$1" "$2"; detail "expected: $4"; detail "got     : $3"; fi
}
assert_has() { # id label file needle
  if grep -qF -- "$4" "$3" 2>/dev/null; then ok "$1" "$2"
  else no "$1" "$2"; detail "missing literal: $4"; detail "in: $3"; fi
}
assert_hasnt() { # id label file needle
  if grep -qF -- "$4" "$3" 2>/dev/null; then no "$1" "$2"; detail "present but must be gone: $4"; detail "in: $3"
  else ok "$1" "$2"; fi
}

# ---- shared helpers ---------------------------------------------------------

# The canonical block's fixed anchor and fixed terminator. Extraction by these two
# lines (not by eye, not by the next `## `) is what makes the ten-copy census a
# single command and what makes a broken anchor visible as an EMPTY extraction.
extract_block() {
  awk '/^## The property, not the fix \(identical for every pipeline agent\)$/{f=1}
       f{print}
       f&&/^This block is replicated verbatim in ten files\./{exit}' "$1"
}

ten_files() {
  ls "$PP"/agents/*.md 2>/dev/null
  echo "$CMD"
}

# Read a JSON value out of a schema file. `d` is the parsed document.
#
# OUTPUT CONVENTION, AND IT IS LOAD-BEARING. A JSON *string* value is printed
# BARE, without quotes; anything else is JSON.stringify'd; `undefined` prints
# `<undefined>`; a path that THROWS on the way (an absent parent) prints
# `<error>`. So `.type` on a string-typed field prints  string  and NOT
# "string", and a cell that compares it against the shell literal '"string"'
# can never be equal, for any input, in any document.
#
# THREE CELLS SHIPPED WITH EXACTLY THAT BUG (R3.a, R3.rnc, AC6.typed) and were
# STUCK RED through the whole of Phase 3a. Their red was not a reading of the
# schema; it was a constant. That is the same shape as the always-fires
# guardrail: a check whose output does not depend on its subject is a zero
# result about the harness, and it is worse than no check, because a reader
# takes the red for a finding and Dev burns a pass chasing it. The convention
# is now ASSERTED by H.jnode below rather than left to each author to recall.
jnode() { # file expr
  node -e 'const d=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
           const v=(function(){return eval(process.argv[2]);})();
           process.stdout.write(v===undefined?"<undefined>":(typeof v==="string"?v:JSON.stringify(v)));' \
    "$1" "$2" 2>/dev/null || printf '<error>'
}

# Extract the EXPOSURE NOTE out of a field description, instead of grepping the
# whole description for a word that neighbouring prose also carries. The note is
# the sentence about PASTING; at HEAD each of the three fields carries exactly
# one such sentence and it IS the note. Prints ONE LINE PER candidate sentence,
# and the empty string when the field carries none - which is what makes
# deleting the note visible. Per-sentence and not joined, because a caller that
# tested the joined text could have leg 1 satisfied by one sentence and leg 2 by
# another: that is the same cross-sentence satisfaction that blinded this cell in
# the first place, one level up.
exposure_note() { # file expr
  node -e 'const d=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
           const v=(function(){return eval(process.argv[2]);})();
           if(typeof v!=="string"){process.stdout.write("");process.exit(0)}
           const hits=v.split(/(?<=\.)\s+/).filter(x=>/paste/i.test(x));
           process.stdout.write(hits.map(x=>x.replace(/\s+/g," ")).join("\n"));' \
    "$1" "$2" 2>/dev/null || printf ''
}

# THE OVERCLAIM SCAN, AS A CLASS AND NOT A PHRASE LIST (QA-N1, round 4).
# The old check was a four-phrase blocklist over WORDING, and QA's CM7 walked
# straight past it: an INVERTED note that claims the archiver strips credential
# material, phrased in none of the four. A blocklist is an enumeration of
# examples; this is the enumeration of the CLASS the note may not assert -
# something on this path REMOVING, STRIPPING, REDACTING or FILTERING credential
# material - keyed on the grammatical relation rather than on proximity.
#
# WHY NOT PROXIMITY: a first cut flagged the field's own redactor caveat
# ("under both redactor forms"), which sits within 80 characters of the word
# `token` and says nothing about credentials. So a hit needs the credential word
# to be the verb's OBJECT (`strips credential material`) or, passively, its
# SUBJECT (`a pasted secret is removed`), with no sentence punctuation crossed,
# and a negator within 25 characters exempts it (`no credential material is
# stripped` is the honest form of the same words).
#
# WHAT IT STILL WILL NOT CATCH, stated so the next reader does not overread it:
# an overclaim built on a verb outside the list ("the archiver takes care of
# credentials for you"). The phrase blocklist in the cell stays beside it for
# the assurance wording that carries no verb at all ("it is safe to paste",
# QA's CM8), and the two are read together.
overclaim_hits() { # file expr -> one line per affirmative protection claim, empty when clean
  node -e 'const d=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
           const v=(function(){return eval(process.argv[2]);})();
           if(typeof v!=="string"){process.stdout.write("");process.exit(0)}
           const s=v.replace(/\s+/g," ");
           const VERB=/\b(redact(s|ed|ing)?|strip(s|ped|ping)?|scrub(s|bed|bing)?|saniti[sz]e[sd]?|saniti[sz]ing|filter(s|ed|ing)?|mask(s|ed|ing)?|remove[sd]?|removing|purge[sd]?|purging|elide[sd]?|censor(s|ed|ing)?|protect(s|ed|ing)?|guard(s|ed|ing)?|prevent(s|ed|ing)?|reject(s|ed|ing)?)\b/gi;
           const NEG=/(^|[^a-z])(no|not|never|nothing|neither|nor|without|cannot)([^.;:]{0,25})$/i;
           const OBJ=/^[^.;:]{0,40}?(credential|secret|token|password|passphrase)/i;
           const SUBJ=/(credential|secret|token|password|passphrase)[^.;:]{0,45}\b(is|are|was|were|gets?|being|be)\s+$/i;
           const out=[];let m;
           while((m=VERB.exec(s))){
             const i=m.index,e=i+m[0].length,before=s.slice(Math.max(0,i-90),i);
             if(!OBJ.test(s.slice(e,e+60))&&!SUBJ.test(before.slice(-70))) continue;
             if(NEG.test(before)) continue;
             out.push(m[0]+": ..."+s.slice(Math.max(0,i-50),e+50)+"...");
           }
           process.stdout.write(out.join("\n"));' \
    "$1" "$2" 2>/dev/null || printf ''
}

# LEG 3, AS THE SUBSTANCE AND NOT THE FRAMING (QA-N1, round 4). The old leg
# accepted "a rule you honor" / "not a control", which is the note's FRAMING,
# and CM7 kept exactly that framing while reversing what followed it. What a
# reader is owed is the negated-protection clause itself: some protection this
# path does NOT perform, named and negated, in the same sentence. The negator
# must be within 25 characters and may not cross `.`, `;` or `:` - that
# punctuation rule is what stops CM7's "not a control that protects you: the
# archiver strips ..." from satisfying it through a negator in the clause before.
negated_protection() { # sentence -> exit 0 when it names a protection this path does not perform
  printf '%s\n' "$1" | grep -Eiq '(^|[^[:alnum:]])(no|not|never|nothing|neither|nor|without)([^.;:]{0,25})(length check|pattern check|redact|strip|scrub|sanitis|sanitiz|filter|mask|remov|purge)'
}

RET=""
# Build an isolated plugin root. $1 = tag, $2 = optional git ref whose schemas
# replace the worktree's (used for the PRE-CHANGE control and the AC10 down
# direction). Isolated because a mutating battery that edits the tree it is
# reviewing loses work: an interrupted run leaves a planted defect behind.
mk_plugin() {
  local dest="$TMPROOT/plugin-$1"
  rm -rf "$dest"; mkdir -p "$dest"
  cp -R "$PP/scripts" "$dest/scripts"
  cp -R "$PP/schemas" "$dest/schemas"
  cp -R "$PP/hooks"   "$dest/hooks"
  if [ -n "${2:-}" ]; then
    git -C "$REPO" show "$2:plugins/pipeline/schemas/review.schema.json"      > "$dest/schemas/review.schema.json" || return 1
    git -C "$REPO" show "$2:plugins/pipeline/schemas/peer-review.schema.json" > "$dest/schemas/peer-review.schema.json" || return 1
  fi
  RET="$dest"
}

# Build a throwaway project holding ONE .pipeline/9401 artifact, fresh mtime.
mk_sandbox() { # tag artifact-filename json
  local d="$TMPROOT/proj-$1"
  rm -rf "$d"; mkdir -p "$d/.pipeline/9401"
  printf '{"issue_number":9401}' > "$d/.pipeline/9401/status.json"
  printf '%s' "$3" > "$d/.pipeline/9401/$2"
  RET="$d"
}

# Drive the SHIPPED hook, not the validator directly: the hook is the thing a
# reviewer's stop actually runs, and it carries three fail-open guards of its own.
# NOTE ON THE SIGNAL: hooks/subagent-stop.sh ALWAYS exits 0 by contract ("a
# validation hook must never wedge an agent stop"). So `exit 0` alone is a
# vacuous assertion that passes on every input. The discriminator is STDOUT:
# empty = allowed, a decision:block JSON = refused. Both are asserted below.
HOOK_OUT=""; HOOK_RC=""
run_hook() { # plugin_root agent_type sandbox
  HOOK_OUT="$( cd "$3" && printf '{"agent_type":"%s","cwd":"%s","active_issue":"9401"}' "$2" "$3" \
      | CLAUDE_PLUGIN_ROOT="$1" CLAUDE_PROJECT_DIR="$3" bash "$1/hooks/subagent-stop.sh" 2>/dev/null )"
  HOOK_RC=$?
}
hook_blocks() { # id label plugin agent sandbox needle
  run_hook "$3" "$4" "$5"
  if [ "$HOOK_RC" != "0" ]; then no "$1" "$2"; detail "hook exited $HOOK_RC (contract says always 0)"; return; fi
  case "$HOOK_OUT" in
    *'"decision":"block"'*)
      case "$HOOK_OUT" in
        *"$6"*) ok "$1" "$2";;
        *) no "$1" "$2"; detail "blocked, but the reason never names: $6"; detail "reason: $(printf '%s' "$HOOK_OUT" | head -c 400)";;
      esac;;
    "") no "$1" "$2"; detail "SILENT: the hook emitted nothing (no refusal)";;
    *)  no "$1" "$2"; detail "unexpected stdout: $(printf '%s' "$HOOK_OUT" | head -c 300)";;
  esac
}
hook_silent() { # id label plugin agent sandbox
  run_hook "$3" "$4" "$5"
  if [ "$HOOK_RC" != "0" ]; then no "$1" "$2"; detail "hook exited $HOOK_RC (contract says always 0)"; return; fi
  if [ -z "$HOOK_OUT" ]; then ok "$1" "$2"
  else no "$1" "$2"; detail "expected silence, got: $(printf '%s' "$HOOK_OUT" | head -c 400)"; fi
}

# ---- fixtures ---------------------------------------------------------------
# Behavioural fixtures only: a reviewer's shard as the contract tells it to write
# one. No fixture is derived from anything Dev might type.
TS='2026-08-21T18:00:00Z'
dba_shard() { # $1 = the must_satisfy key/value fragment, or empty
  printf '{"verdict":"REQUEST_CHANGES","reviewed_at":"%s","concerns":[{"severity":"blocker","description":"The down region of the migration runs inline on the deploy path.","location":"db/migrations/003.sql:12"%s}],"notes":"n"}' "$TS" "$1"
}
secops_shard() { # $1 = remediation fragment on the vulnerability row
  printf '{"verdict":"VETO","reviewed_at":"%s","concerns":[],"notes":"n","compliance_flags":[],"vulnerabilities":[{"severity":"critical","category":"auth","description":"Auth bypass: /v1/admin accepts an unsigned session cookie.","location":"api/admin.ts:44"%s}]}' "$TS" "$1"
}
secops_concern_shard() { # $1 = must_satisfy fragment on the concern row
  printf '{"verdict":"REQUEST_CHANGES","reviewed_at":"%s","concerns":[{"severity":"high","description":"Token comparison is byte-wise and short-circuits.","location":"api/auth.ts:88"%s}],"notes":"n","vulnerabilities":[],"compliance_flags":[]}' "$TS" "$1"
}
# The UNGUARDED third channel, written exactly as SecOps's veto protocol permits:
# no statute, no concern, no action. This must stay SILENT before AND after.
secops_veto_empty_flag() {
  printf '{"verdict":"VETO","reviewed_at":"%s","concerns":[],"notes":"n","vulnerabilities":[],"compliance_flags":[{}]}' "$TS"
}
# The harness's own non-zero control: malformed in a way the CURRENT schema
# already refuses. If this does not block, every silent cell below is a zero
# result about the harness rather than about the schema.
dba_bad_verdict() {
  printf '{"verdict":"NOPE","reviewed_at":"%s","concerns":[],"notes":"n"}' "$TS"
}
# AC10's down-direction shard: written under the NEW contract AND carrying the
# undeclared keys the live corpus actually contains, so it can EXHIBIT the
# openness property rather than be silent about it.
down_review_shard() {
  printf '{"verdict":"REQUEST_CHANGES","reviewed_at":"%s","concerns":[{"severity":"blocker","description":"d","location":"l","must_satisfy":"p","rationale_not_checked":"m","id":"D1","title":"t","evidence":"e","must_fix_before_merge":true}],"notes":"n"}' "$TS"
}
down_secops_shard() {
  printf '{"verdict":"VETO","reviewed_at":"%s","concerns":[{"severity":"high","description":"d","must_satisfy":"p","rationale_not_checked":"m","ask":"a"}],"notes":"n","compliance_flags":[{"statute":"s","concern":"c","action":"block"}],"vulnerabilities":[{"severity":"critical","category":"auth","description":"d","location":"l","remediation":"p","rationale_not_checked":"m","resolved":true,"resolution":"fixed in 3fa1c0"}]}' "$TS"
}
down_peer_shard() {
  printf '{"verdict":"REQUEST_CHANGES","reviewed_at":"%s","concerns":[{"severity":"major","description":"d","must_satisfy":"p","rationale_not_checked":"m","detail":"x","proposed_anchor":"y"}],"notes":"n"}' "$TS"
}

# ---- the ROLE axis, DERIVED (added in the panel fix round; see AC4.matrix) ---
# Enforcement is a CONJUNCTION: (the stopping agent's type has an AGENT_RULES
# entry reaching the artifact) AND (that artifact's subschema requires the
# field). A matrix quantified over LOCATIONS alone puts every fixture in the
# role-PRESENT cell, so the role-absent branch never runs -- which is how a
# sentence false for seven of its ten recipients shipped past a green battery.
#
# THE ROLE SET IS NEVER HAND-WRITTEN. A hand-added `design` row would re-encode
# the same unlicensed generalisation one row larger. It is derived from the
# files that CARRY the block, and cross-checked against the Phase 2 shards the
# orchestrator actually names, so a role added to either set later appears as a
# new row rather than as a silence.
block_roles() { # prints "role<TAB>file" for every file carrying the block
  while IFS= read -r f; do
    [ -n "$(extract_block "$f")" ] || continue
    case "$f" in
      */agents/*.md) printf '%s\t%s\n' "$(basename "$f" .md)" "$f";;
      *)             printf 'ORCHESTRATOR\t%s\n' "$f";;
    esac
  done < <(ten_files)
}

# The Phase 2 artifact a role writes, read out of that role's OWN contract file
# (design.md names review.design_review.json, art-director.md names
# review.art_director.json: neither is review.<role>.json, and hard-coding that
# pattern is what hides them).
role_artifact() { # role file
  # review.schema.json matches the same shape and is not a shard: a role whose
  # contract merely cites the schema would otherwise be given it as an artifact.
  local a; a="$(grep -oE 'review\.[a-z_]+\.json' "$2" | grep -v '^review\.schema\.json$' | head -1)"
  if [ -n "$a" ]; then printf '%s' "$a"; else printf 'review.%s.json' "$1"; fi
}

# The two parenthesised role lists out of ONE FILE'S OWN copy of the block. Per
# file on purpose: the claim under test is what the copy DELIVERED TO THAT ROLE
# asserts, so reading one canonical copy would defeat the cell.
block_list() { # file marker
  extract_block "$1" | tr '\n' ' ' \
    | awk -v m="$2" '{i=index($0,m); if(i==0)exit; s=substr($0,i+length(m)); j=index(s,")"); if(j==0)exit; print substr(s,1,j-1)}' \
    | grep -oE '`[a-z-]+`' | tr -d '`' | sort -u | tr '\n' ' '
}

# THREE LOCATION FIXTURES, one body each, identical for every role. verdict is
# REQUEST_CHANGES in all three because VETO is in the SecOps enum union only: a
# VETO body would block every non-SecOps role on the ENUM and be read as the
# property refusing. vulnerabilities[] and compliance_flags[] are carried on
# every role's shard deliberately -- on agentBlock they are undeclared extra
# keys, and the point of the cell is what the walker does NOT reach.
mx_concerns() { printf '{"verdict":"REQUEST_CHANGES","reviewed_at":"%s","concerns":[{"severity":"blocker","description":"The handler accepts an unsigned payload.","location":"api/x.ts:1"}],"notes":"n","vulnerabilities":[],"compliance_flags":[]}' "$TS"; }
mx_vuln()     { printf '{"verdict":"REQUEST_CHANGES","reviewed_at":"%s","concerns":[],"notes":"n","vulnerabilities":[{"severity":"critical","category":"auth","description":"Auth bypass.","location":"api/x.ts:1"}],"compliance_flags":[]}' "$TS"; }
mx_flags()    { printf '{"verdict":"REQUEST_CHANGES","reviewed_at":"%s","concerns":[],"notes":"n","vulnerabilities":[],"compliance_flags":[{}]}' "$TS"; }

# BLOCK<needle> / BLOCK / SILENT for one (role, artifact, body) triple.
mx_probe() { # plugin agent artifact body needle
  mk_sandbox mx "$3" "$4" >/dev/null
  run_hook "$1" "$2" "$RET"
  case "$HOOK_OUT" in
    "") printf 'SILENT';;
    *'"decision":"block"'*) case "$HOOK_OUT" in *"$5"*) printf 'BLOCK';; *) printf 'BLOCK-OTHER';; esac;;
    *) printf 'ODD';;
  esac
}

# =============================================================================
# THE NON-ZERO CONTROL BATTERY (--controls)
# =============================================================================
# A cell that has only ever printed the answer you wanted is a zero result about
# your own harness. Every cell that asserts an ABSENCE or a CLEANLINESS gets the
# defect planted and is watched going red.
#
# NOTHING IN THE REAL WORKTREE IS EVER MUTATED. Each control copies
# plugins/pipeline into a throwaway directory, plants there, and re-invokes this
# battery with --src pointed at the copy. Restoration is `rm -rf` of the copy,
# never `git checkout` of a tracked file: an interrupted mutating battery that
# restores by checkout discards uncommitted work, and one that plants into an
# UNTRACKED file leaves the defect behind entirely.
#
# EACH CONTROL IS TWO OBSERVATIONS, NOT ONE:
#   1. the cell is GREEN on the unmutated copy -- otherwise the control cannot
#      discriminate and reports CONTROL-N/A rather than a misleading OK;
#   2. the cell is RED on the mutated copy.
# A control that reports OK without (1) is proving nothing.
SELF="$SELF_DIR/$(basename "${BASH_SOURCE[0]}")"

plant_addprops() { node -e '
  const f=process.argv[1],fs=require("fs"),d=JSON.parse(fs.readFileSync(f,"utf8"));
  d.definitions.agentBlock.properties.concerns.items.additionalProperties=false;
  fs.writeFileSync(f,JSON.stringify(d,null,2));
  console.log("agentBlock concerns.items.additionalProperties = false");' "$1/plugins/pipeline/schemas/review.schema.json"; }

plant_peerreq() { node -e '
  const f=process.argv[1],fs=require("fs"),d=JSON.parse(fs.readFileSync(f,"utf8"));
  d.definitions.panelVerdict.properties.concerns.items.required=["severity","description"];
  fs.writeFileSync(f,JSON.stringify(d,null,2));
  console.log("panelVerdict concerns.items.required = [severity,description]");' "$1/plugins/pipeline/schemas/peer-review.schema.json"; }

# De-sync definition 2 from definition 1 by ONE character, whichever argument
# form is shipped. A form-specific planter would silently become a no-op the day
# the form changes, which is the mutation-that-was-not-the-one-you-meant defect.
plant_brace() { node -e '
  const f=process.argv[1],fs=require("fs");let L=fs.readFileSync(f,"utf8").split("\n");
  const idx=[];L.forEach((l,i)=>{if(l.indexOf("surface_probe() {")===0)idx.push(i)});
  if(idx.length<2){console.log("PLANT-FAILED: fewer than two definitions");process.exit(3)}
  const t=idx[1]+1, before=L[t];
  L[t]=L[t]+" ";
  if(L[t]===before){console.log("PLANT-FAILED: line unchanged");process.exit(3)}
  fs.writeFileSync(f,L.join("\n"));
  console.log("definition 2 line "+(t+1)+" tail: ["+before.slice(-14)+"] -> ["+L[t].slice(-14)+"] (+1 char, len "+before.length+"->"+L[t].length+")");
  ' "$1/plugins/pipeline/commands/pipeline.md"; }

plant_probe20() { node -e '
  const f=process.argv[1],fs=require("fs");const s=fs.readFileSync(f,"utf8");
  const n=(s.match(/\?0:20\)/g)||[]).length;
  fs.writeFileSync(f,s.split("?0:20)").join("?0:1)"));
  console.log("replaced "+n+" occurrence(s) of ?0:20) with ?0:1)");' "$1/plugins/pipeline/commands/pipeline.md"; }

plant_qanarrow() { node -e '
  const f=process.argv[1],fs=require("fs");const L=fs.readFileSync(f,"utf8").split("\n");
  const i=L.findIndex(l=>l.indexOf("You name the problem and the fix")>=0);
  console.log("deleted qa.md line "+(i+1)+": "+L[i].slice(0,70));
  L.splice(i,1); fs.writeFileSync(f,L.join("\n"));' "$1/plugins/pipeline/agents/qa.md"; }

plant_stdtier() { node -e '
  const f=process.argv[1],fs=require("fs");const L=fs.readFileSync(f,"utf8").split("\n");
  const i=L.findIndex(l=>l.indexOf("Do not loosen the CORS origin allowlist")>=0);
  console.log("deleted secops.md line "+(i+1)+": "+L[i].slice(0,70));
  L.splice(i,1); fs.writeFileSync(f,L.join("\n"));' "$1/plugins/pipeline/agents/secops.md"; }

plant_inspection() { node -e '
  const f=process.argv[1],fs=require("fs");const L=fs.readFileSync(f,"utf8").split("\n");
  const i=L.findIndex(l=>l.indexOf("Are timing-safe comparisons used")>=0);
  console.log("deleted secops.md line "+(i+1)+": "+L[i].slice(0,70));
  L.splice(i,1); fs.writeFileSync(f,L.join("\n"));' "$1/plugins/pipeline/agents/secops.md"; }

plant_census_word() { node -e '
  const f=process.argv[1],fs=require("fs");const s=fs.readFileSync(f,"utf8");
  if(s.indexOf("is refused")<0){console.log("PLANT-FAILED: the phrase is not in this file");process.exit(3)}
  fs.writeFileSync(f,s.replace("is refused","is usually refused"));
  console.log("ba.md: \"is refused\" -> \"is usually refused\" (one word, one copy)");' "$1/plugins/pipeline/agents/ba.md"; }

plant_census_anchor() { node -e '
  const f=process.argv[1],fs=require("fs");const s=fs.readFileSync(f,"utf8");
  const a="## The property, not the fix (identical for every pipeline agent)";
  if(s.indexOf(a)<0){console.log("PLANT-FAILED: no anchor in this file");process.exit(3)}
  fs.writeFileSync(f,s.replace(a,"## The property, not the fix"));
  console.log("dba.md: anchor heading truncated (extraction becomes EMPTY)");' "$1/plugins/pipeline/agents/dba.md"; }

plant_reposcope() { node -e '
  const f=process.argv[1],fs=require("fs");const s=fs.readFileSync(f,"utf8");
  const t="This block is replicated verbatim in ten files.";
  if(s.indexOf(t)<0){console.log("PLANT-FAILED: no terminator in this file");process.exit(3)}
  fs.writeFileSync(f,s.replace(t,"The refusal is proven in adopting projects. "+t));
  console.log("devops.md: planted the prohibited repository-identity warranty");' "$1/plugins/pipeline/agents/devops.md"; }

plant_middleware() { node -e '
  const f=process.argv[1],fs=require("fs");const s=fs.readFileSync(f,"utf8");
  fs.writeFileSync(f,s.replace(/"remediation": "[^"]*"/,"\"remediation\": \"Wrap with the global rate-limit middleware (10 req/min).\""));
  console.log("secops.md: the mechanism string re-planted in the example row");' "$1/plugins/pipeline/agents/secops.md"; }

plant_ms_review_drop() { node -e '
  const f=process.argv[1],fs=require("fs"),d=JSON.parse(fs.readFileSync(f,"utf8"));
  const P=d.definitions.agentBlock.properties.concerns.items.properties;
  if(!P.must_satisfy){console.log("PLANT-FAILED: must_satisfy absent already");process.exit(3)}
  delete P.must_satisfy; fs.writeFileSync(f,JSON.stringify(d,null,2));
  console.log("review agentBlock concerns.items.properties.must_satisfy DELETED -> jnode path now prints <error>");' "$1/plugins/pipeline/schemas/review.schema.json"; }

plant_ms_review_type() { node -e '
  const f=process.argv[1],fs=require("fs"),d=JSON.parse(fs.readFileSync(f,"utf8"));
  const P=d.definitions.agentBlock.properties.concerns.items.properties;
  const was=P.must_satisfy.type; P.must_satisfy.type="number";
  fs.writeFileSync(f,JSON.stringify(d,null,2));
  console.log("review must_satisfy.type: "+JSON.stringify(was)+" -> \"number\" (key PRESENT, so <error> is not the mechanism)");' "$1/plugins/pipeline/schemas/review.schema.json"; }

plant_ms_peer_drop() { node -e '
  const f=process.argv[1],fs=require("fs"),d=JSON.parse(fs.readFileSync(f,"utf8"));
  const P=d.definitions.panelVerdict.properties.concerns.items.properties;
  if(!P.must_satisfy){console.log("PLANT-FAILED: must_satisfy absent already");process.exit(3)}
  delete P.must_satisfy; fs.writeFileSync(f,JSON.stringify(d,null,2));
  console.log("peer-review panelVerdict concerns.items.properties.must_satisfy DELETED");' "$1/plugins/pipeline/schemas/peer-review.schema.json"; }

plant_rnc_drop() { node -e '
  const f=process.argv[1],fs=require("fs"),d=JSON.parse(fs.readFileSync(f,"utf8"));
  const P=d.properties.secops.allOf[1].properties.vulnerabilities.items.properties;
  if(!P.rationale_not_checked){console.log("PLANT-FAILED: rationale_not_checked absent already");process.exit(3)}
  delete P.rationale_not_checked; fs.writeFileSync(f,JSON.stringify(d,null,2));
  console.log("secops vulnerabilities.items.properties.rationale_not_checked DELETED (1 of the 3 sites)");' "$1/plugins/pipeline/schemas/review.schema.json"; }

plant_credential_drop() { node -e '
  const f=process.argv[1],fs=require("fs"),d=JSON.parse(fs.readFileSync(f,"utf8"));
  const t=d.definitions.agentBlock.properties.concerns.items.properties.must_satisfy;
  const before=t.description.length;
  t.description=t.description.replace(/Because that copy is verbatim[^.]*\./,"");
  if(t.description.length===before){console.log("PLANT-FAILED: the exposure sentence was not found");process.exit(3)}
  fs.writeFileSync(f,JSON.stringify(d,null,2));
  console.log("review must_satisfy: exposure sentence removed ("+before+" -> "+t.description.length+" chars)");' "$1/plugins/pipeline/schemas/review.schema.json"; }

plant_credential_overclaim() { node -e '
  const f=process.argv[1],fs=require("fs"),d=JSON.parse(fs.readFileSync(f,"utf8"));
  const t=d.definitions.agentBlock.properties.concerns.items.properties.must_satisfy;
  t.description+=" Any credential you paste here is automatically redacted before it is archived.";
  fs.writeFileSync(f,JSON.stringify(d,null,2));
  console.log("review must_satisfy: appended an OVERCLAIM (\"automatically redacted\")");' "$1/plugins/pipeline/schemas/review.schema.json"; }

# THE THREE MUTATIONS QA RAN IN ROUND 3, MADE PERMANENT. The two controls above
# both plant in ONE of the three fields AC15.52.replaced asserts over
# (review/must_satisfy), and QA measured the cell BLIND on a second
# (review/remediation): the entire exposure note could be deleted from SecOps's
# own field and the cell stayed green. A cell asserting a warning over three
# fields needs a planted defect in each of the three.
plant_credential_drop_rem() { node -e '
  const f=process.argv[1],fs=require("fs"),d=JSON.parse(fs.readFileSync(f,"utf8"));
  const t=d.properties.secops.allOf[1].properties.vulnerabilities.items.properties.remediation;
  const before=t.description.length, i=t.description.indexOf("Because that copy is public");
  if(i<0){console.log("PLANT-FAILED: the exposure sentence was not found");process.exit(3)}
  t.description=t.description.slice(0,i).replace(/\s+$/,"");
  fs.writeFileSync(f,JSON.stringify(d,null,2));
  console.log("review remediation: WHOLE exposure note removed ("+before+" -> "+t.description.length+" chars)");' "$1/plugins/pipeline/schemas/review.schema.json"; }

plant_credential_drop_peer() { node -e '
  const f=process.argv[1],fs=require("fs"),d=JSON.parse(fs.readFileSync(f,"utf8"));
  const t=d.definitions.panelVerdict.properties.concerns.items.properties.must_satisfy;
  const before=t.description.length;
  t.description=t.description.replace(/Because that copy is verbatim[^.]*\./,"");
  if(t.description.length===before){console.log("PLANT-FAILED: the exposure sentence was not found");process.exit(3)}
  fs.writeFileSync(f,JSON.stringify(d,null,2));
  console.log("peer-review must_satisfy: exposure sentence removed ("+before+" -> "+t.description.length+" chars)");' "$1/plugins/pipeline/schemas/peer-review.schema.json"; }

# THE EXPECTED SURVIVOR, and the battery needs one. A battery where every
# mutation reddens cannot tell coverage from a rubber stamp. This is QA's own
# MQ5: the note is REWORDED with its meaning intact, and the cell must stay
# GREEN. If it ever reddens, the cell has become a frozen-string check and the
# next honest rewording of the note will be reported as a missing warning.
plant_credential_reword() { node -e '
  const f=process.argv[1],fs=require("fs"),d=JSON.parse(fs.readFileSync(f,"utf8"));
  const t=d.properties.secops.allOf[1].properties.vulnerabilities.items.properties.remediation;
  const a="never paste credential material into this field";
  if(t.description.indexOf(a)<0){console.log("PLANT-FAILED: the note phrase was not found");process.exit(3)}
  t.description=t.description.split(a).join("under no circumstances paste credential material into this field");
  fs.writeFileSync(f,JSON.stringify(d,null,2));
  console.log("review remediation: note REWORDED, meaning kept (\"never paste\" -> \"under no circumstances paste\")");' "$1/plugins/pipeline/schemas/review.schema.json"; }

# THE SAME DEFECT ONE LEVEL UP: a note whose legs are satisfied by DIFFERENT
# sentences. The warning survives as words while ceasing to be one statement -
# the "never paste" half loses its reason, and the reason loses its imperative.
# Only a single-sentence scope can see this.
plant_credential_split() { node -e '
  const f=process.argv[1],fs=require("fs"),d=JSON.parse(fs.readFileSync(f,"utf8"));
  const t=d.properties.secops.allOf[1].properties.vulnerabilities.items.properties.remediation;
  const i=t.description.indexOf("Because that copy is public");
  if(i<0){console.log("PLANT-FAILED: the exposure sentence was not found");process.exit(3)}
  t.description=t.description.slice(0,i)+"Never paste credential material into this field. "
    +"That copy is public and archived as written, and there is no length check, no pattern check and no redaction on this path.";
  fs.writeFileSync(f,JSON.stringify(d,null,2));
  console.log("review remediation: note SPLIT so no one sentence carries it whole");' "$1/plugins/pipeline/schemas/review.schema.json"; }

# The eleventh copy of the citation rule, flipped. review.schema.json is the one
# location the ten-copy census cannot see, and it is where round 3 promoted the
# defective exemplar to the rule oracle.
plant_pairflip() { node -e '
  const f=process.argv[1],fs=require("fs"),d=JSON.parse(fs.readFileSync(f,"utf8"));
  const t=d.properties.secops.allOf[1].properties.vulnerabilities.items.properties.remediation;
  const a="card-data standard\u2019s".replace("\u2019","'"'"'");
  const needle="per the applicable card-data standard'"'"'s authentication requirements'"'"' is OUT one step earlier";
  if(t.description.indexOf(needle)<0){console.log("PLANT-FAILED: the OUT sorting was not found");process.exit(3)}
  t.description=t.description.split(needle).join("per the applicable card-data standard'"'"'s authentication requirements'"'"' is IN");
  fs.writeFileSync(f,JSON.stringify(d,null,2));
  console.log("review.schema.json: the card-data case flipped from OUT to IN in the ELEVENTH copy");' "$1/plugins/pipeline/schemas/review.schema.json"; }

# QA'S CM7, MADE PERMANENT: the note INVERTED into a false assurance, phrased off
# the old blocklist and keeping the framing phrase the old leg 3 accepted. This
# is the sharpest mutation this cell has seen - it makes the shipped text CLAIM
# MORE than the code knows, on a security exposure - and it SURVIVED round 4.
# Each planter below asserts its literal occurs exactly once before replacing it,
# and prints what it replaced, so a silently-missed plant cannot read as a pass.
plant_credential_invert() { node -e '
  const f=process.argv[1],fs=require("fs"),d=JSON.parse(fs.readFileSync(f,"utf8"));
  const t=d.properties.secops.allOf[1].properties.vulnerabilities.items.properties.remediation;
  const a="there is no length check, no pattern check and no redaction of credential material on this path, so a pasted secret validates clean and is archived as written";
  const b="the archiver strips credential material on this path, so a pasted secret is removed before the row is written";
  const n=t.description.split(a).length-1;
  if(n!==1){console.log("PLANT-FAILED: the negated-protection clause occurs "+n+" times, expected exactly 1");process.exit(3)}
  t.description=t.description.split(a).join(b);
  fs.writeFileSync(f,JSON.stringify(d,null,2));
  console.log("review remediation: INVERTED -> ..." + b.slice(0,64) + "...");' "$1/plugins/pipeline/schemas/review.schema.json"; }

# QA'S CM8, MADE PERMANENT and kept BESIDE CM7. It carries no protection verb at
# all, so the class scan cannot see it and the phrase list must. Two controls,
# two mechanisms: drop either mechanism and one of these two goes green.
plant_credential_safe() { node -e '
  const f=process.argv[1],fs=require("fs"),d=JSON.parse(fs.readFileSync(f,"utf8"));
  const t=d.properties.secops.allOf[1].properties.vulnerabilities.items.properties.remediation;
  const before=t.description.length;
  t.description+=" In practice it is safe to paste whatever you have to hand.";
  fs.writeFileSync(f,JSON.stringify(d,null,2));
  console.log("review remediation: appended the ASSURANCE wording (safe to paste), "+before+" -> "+t.description.length+" chars");' "$1/plugins/pipeline/schemas/review.schema.json"; }

# QA'S QM4: the IN exemplar's CITED LITERAL drifted in the ELEVENTH copy alone.
# The same edit in one of the ten is caught by AC1.census; this one is the file
# no census covers, and it survived round 4 because every leg matched on text
# after the number.
plant_pairlit() { node -e '
  const f=process.argv[1],fs=require("fs"),d=JSON.parse(fs.readFileSync(f,"utf8"));
  const t=d.properties.secops.allOf[1].properties.vulnerabilities.items.properties.remediation;
  const a="must be the 30 seconds RFC 6238", b="must be the 60 seconds RFC 6238";
  const n=t.description.split(a).length-1;
  if(n!==1){console.log("PLANT-FAILED: the cited literal occurs "+n+" times, expected exactly 1");process.exit(3)}
  t.description=t.description.split(a).join(b);
  fs.writeFileSync(f,JSON.stringify(d,null,2));
  console.log("review.schema.json: cited literal 30 -> 60 seconds in the ELEVENTH copy only (" + a + " -> " + b + ")");' "$1/plugins/pipeline/schemas/review.schema.json"; }

# THE CONTROL FOR THE ENUMERATION THIS PASS SHIPPED. A TWELFTH file acquires a
# statement of the citation rule - which is what "somebody states the rule in a
# fifth place" looks like from the outside - and the schema sentence that names
# four loci is silently false from that moment. README.md is used because it is
# in this change's own diff surface and is NOT one of the ten, so the plant
# cannot be confused with block drift.
plant_loci() { node -e '
  const f=process.argv[1],fs=require("fs");const s=fs.readFileSync(f,"utf8");
  const a="## Upgrading";
  if(s.indexOf(a)<0){console.log("PLANT-FAILED: no anchor heading in this file");process.exit(3)}
  fs.writeFileSync(f,s.replace(a,"State the bound with a source a reader can OPEN AND FIND THAT LITERAL IN.\n\n"+a));
  console.log("README.md: a TWELFTH statement of the citation rule planted, named by no propagation sentence");' "$1/plugins/pipeline/README.md"; }

# THE SAME CELL FROM THE OTHER DIRECTION: a named locus DISAPPEARS. Two controls
# in opposite directions, because a count check that only ever sees additions is
# half a check - and this is the half SecOps's M6/M7 sat in.
plant_loci_drop() { node -e '
  const f=process.argv[1],fs=require("fs");const L=fs.readFileSync(f,"utf8").split("\n");
  const i=L.findIndex(x=>x.indexOf("That is the same umbrella test the block above states")>=0);
  if(i<0){console.log("PLANT-FAILED: the Style bullet is not in this file");process.exit(3)}
  L.splice(i,1); fs.writeFileSync(f,L.join("\n"));
  console.log("secops.md: the Style bullet DELETED (a named locus disappears; 3 occurrences -> 2)");' "$1/plugins/pipeline/agents/secops.md"; }

# QA'S QM5, THE EXPECTED SURVIVOR AC3.pairsort WAS SAID TO LACK. Prose NEXT TO
# the sorted cases is reworded and the sorting is untouched, so the cell must
# stay GREEN. If it ever reddens, the cell has become a frozen-paragraph check
# on the one copy no census pins, and the next honest edit to review.schema.json
# will be reported as a sorting defect.
plant_pairsort_reword() { node -e '
  const f=process.argv[1],fs=require("fs"),d=JSON.parse(fs.readFileSync(f,"utf8"));
  const t=d.properties.secops.allOf[1].properties.vulnerabilities.items.properties.remediation;
  const a="Those three worked cases are the check on this sentence";
  const b="These three worked cases together are the check on this sentence";
  const n=t.description.split(a).length-1;
  if(n!==1){console.log("PLANT-FAILED: the neighbouring sentence occurs "+n+" times, expected exactly 1");process.exit(3)}
  t.description=t.description.split(a).join(b);
  fs.writeFileSync(f,JSON.stringify(d,null,2));
  console.log("review.schema.json: neighbouring prose reworded (" + a.slice(0,32) + "... -> " + b.slice(0,32) + "...), sorting untouched");' "$1/plugins/pipeline/schemas/review.schema.json"; }

# THE PANEL'S BLOCKER, RE-PLANTED. design.md's own copy is edited to claim the
# refusal that SecOps, DBA and QA each measured does not happen for `design`.
# This is the mutation the location-quantified matrix could not see.
plant_matrix_lie() { node -e '
  const f=process.argv[1],fs=require("fs");let s=fs.readFileSync(f,"utf8");
  const a="REFUSED AT (`dba`, `devops`, `secops`)", b="NOT REFUSED AT (`art-director`, `ba`, `design`, `dev`, `librarian`, `qa`)";
  if(s.indexOf(a)<0||s.indexOf(b)<0){console.log("PLANT-FAILED: the two role lists are not in this file");process.exit(3)}
  s=s.split(a).join("REFUSED AT (`dba`, `design`, `devops`, `secops`)")
     .split(b).join("NOT REFUSED AT (`art-director`, `ba`, `dev`, `librarian`, `qa`)");
  fs.writeFileSync(f,s);
  console.log("design.md: `design` moved from the NOT-REFUSED list to the REFUSED list");' "$1/plugins/pipeline/agents/design.md"; }

# A ROLE ADDED TO THE SET LATER. The census denominator grows and the role lists
# do not, which is the silence AC4.matrix.roles exists to make visible.
plant_newrole() { node -e '
  const fs=require("fs"),src=process.argv[1]+"/plugins/pipeline/agents/librarian.md";
  const dst=process.argv[1]+"/plugins/pipeline/agents/zz-newrole.md";
  const s=fs.readFileSync(src,"utf8");
  if(s.indexOf("REFUSED AT (")<0){console.log("PLANT-FAILED: source carries no block");process.exit(3)}
  fs.writeFileSync(dst,s);
  console.log("added agents/zz-newrole.md carrying the block, named in neither role list");' "$1"; }

# A BLOCK EDITED WITHOUT ITS DIGEST. One hex character in one file, which is what
# a stale published digest looks like from the outside.
plant_digest() { node -e '
  const f=process.argv[1],fs=require("fs");const s=fs.readFileSync(f,"utf8");
  const m=s.match(/The span.s sha1 on an undrifted tree is `([0-9a-f]{40})`/);
  if(!m){console.log("PLANT-FAILED: no digest line in this file");process.exit(3)}
  const was=m[1], now=(was[0]==="a"?"b":"a")+was.slice(1);
  fs.writeFileSync(f,s.split("`"+was+"`").join("`"+now+"`"));
  console.log("qa.md: digest "+was.slice(0,12)+"... -> "+now.slice(0,12)+"... (1 char)");' "$1/plugins/pipeline/agents/qa.md"; }

# LEG 2 OF THE DIGEST CELL, which had no control until QA supplied this one.
# plant_digest exercises "the ten copies disagree about the digest". This is the
# other shape: the BLOCK BODY moves in all ten files and the ten digest lines do
# not, so the ten copies still agree with each other (AC1.census stays GREEN) and
# the published number is silently STALE. That is the failure mode a reader who
# trusts the shipped digest over their own run would inherit, and only AC1.digest
# leg 2 catches it.
#
# THE SAME MUTATION IS AN EXPECTED SURVIVOR OF AC1.census, and that is the point
# rather than a hole: the census asks "do the ten copies agree", which they still
# do. It is registered against AC1.digest only, because a control registered
# against a cell it is expected to survive would report CONTROL-BROKEN. Run
# `--only AC1.census` on the mutated copy by hand if you want to watch it stay
# green; the reason it stays green is written above.
plant_digest_body() { node -e '
  const fs=require("fs"),path=require("path"),root=process.argv[1];
  const dir=root+"/plugins/pipeline/agents";
  const files=fs.readdirSync(dir).map(f=>path.join(dir,f)).filter(f=>f.endsWith(".md"));
  files.push(root+"/plugins/pipeline/commands/pipeline.md");
  let n=0;
  for (const f of files) {
    const s=fs.readFileSync(f,"utf8");
    if(s.indexOf("is refused.")<0) continue;
    fs.writeFileSync(f,s.replace("is refused.","is usually refused."));
    n++;
  }
  if(n<10){console.log("PLANT-FAILED: edited "+n+" of 10 copies");process.exit(3)}
  console.log("all "+n+" copies: \"is refused.\" -> \"is usually refused.\", digest lines untouched");' "$1"; }

control() { # id cell description planter
  local id="$1" cell="$2" desc="$3" planter="$4"
  local c="$TMPROOT/ctl-$id"
  rm -rf "$c"; mkdir -p "$c/plugins"
  cp -R "$REPO/plugins/pipeline" "$c/plugins/pipeline"
  bash "$SELF" --src "$c" --only "$cell" > "$TMPROOT/c0.txt" 2>&1
  if grep -qE '^(FAIL|SKIP)' "$TMPROOT/c0.txt" || ! grep -qE '^PASS' "$TMPROOT/c0.txt"; then
    printf 'CONTROL-N/A    %-22s %s\n' "$id" "$desc"
    printf '               | %s is already RED (or absent) without the mutation, so this\n' "$cell"
    printf '               | control cannot discriminate yet. Re-run --controls after Dev implements.\n'
    rm -rf "$c"; return
  fi
  "$planter" "$c" > "$TMPROOT/plant.txt" 2>&1
  if [ $? -ne 0 ]; then
    printf 'CONTROL-BROKEN %-22s %s\n' "$id" "$desc"
    printf '               | the mutation did not land: %s\n' "$(head -1 "$TMPROOT/plant.txt")"
    rm -rf "$c"; return
  fi
  printf '               | planted: %s\n' "$(head -1 "$TMPROOT/plant.txt")"
  bash "$SELF" --src "$c" --only "$cell" > "$TMPROOT/c1.txt" 2>&1
  if grep -qE '^FAIL' "$TMPROOT/c1.txt"; then
    printf 'CONTROL-OK     %-22s %s\n' "$id" "$desc"
    printf '               | %s: GREEN unmutated -> RED mutated. The cell bites.\n' "$cell"
  else
    printf 'CONTROL-BROKEN %-22s %s\n' "$id" "$desc"
    printf '               | %s stayed GREEN under the planted defect. THE CELL IS NOT LOAD-BEARING.\n' "$cell"
  fi
  rm -rf "$c"
}

# The inverse harness: a mutation the cell is EXPECTED to survive. Green after
# the plant is the PASS here, and red is the finding.
control_survivor() { # id cell desc planter why
  local id="$1" cell="$2" desc="$3" planter="$4" why="$5"
  local c="$TMPROOT/ctl-$id"
  rm -rf "$c"; mkdir -p "$c/plugins"
  cp -R "$REPO/plugins/pipeline" "$c/plugins/pipeline"
  bash "$SELF" --src "$c" --only "$cell" > "$TMPROOT/c0.txt" 2>&1
  if ! grep -qE '^PASS' "$TMPROOT/c0.txt"; then
    printf 'CONTROL-N/A    %-22s %s\n' "$id" "$desc"
    printf '               | %s is not GREEN unmutated, so a survivor proves nothing.\n' "$cell"
    rm -rf "$c"; return
  fi
  "$planter" "$c" > "$TMPROOT/plant.txt" 2>&1 || { printf 'CONTROL-BROKEN %-22s %s\n' "$id" "$desc"; printf '               | the mutation did not land: %s\n' "$(head -1 "$TMPROOT/plant.txt")"; rm -rf "$c"; return; }
  printf '               | planted: %s\n' "$(head -1 "$TMPROOT/plant.txt")"
  bash "$SELF" --src "$c" --only "$cell" > "$TMPROOT/c1.txt" 2>&1
  if grep -qE '^PASS' "$TMPROOT/c1.txt"; then
    printf 'SURVIVOR-OK    %-22s %s\n' "$id" "$desc"
    printf '               | %s: GREEN mutated, AS EXPECTED. %s\n' "$cell" "$why"
  else
    printf 'SURVIVOR-RED   %-22s %s\n' "$id" "$desc"
    printf '               | %s went RED on a mutation that preserves meaning. %s\n' "$cell" "$why"
  fi
  rm -rf "$c"
}

if [ "$MODE" = controls ]; then
  printf '=== verify-40.sh --controls :: the non-zero control battery for #40\n'
  printf '    Nothing in %s is mutated; every plant lands in a throwaway copy.\n\n' "$REPO"
  control addprops    'AC10.addprops'     'planting additionalProperties:false on agentBlock concerns.items' plant_addprops
  control peerreq     'AC6.notrequired'   'planting a required list on panelVerdict concerns.items'          plant_peerreq
  control brace       'AC14.identical'    'de-syncing the second probe definition from the first'            plant_brace
  control probe20     'AC12.nomatch'      'making the probe return 1 (INDETERMINATE) on a real no-match'      plant_probe20
  control qanarrow    'AC11.qa'           "deleting qa.md's mechanism-licence line"                          plant_qanarrow
  control stdtier     'AC11.stdtier'      'deleting a line from the injected standard-tier block'            plant_stdtier
  control inspection  'AC9.editscope'     'deleting one of the six protected inspection prompts'             plant_inspection
  control middleware  'AC9.middleware'    'restoring the :169 mechanism string'                              plant_middleware
  control censusword  'AC1.census'        'changing ONE word in ONE of the ten copies'                       plant_census_word
  control censusanchor 'AC1.nonempty'     'truncating ONE anchor heading (the empty-extraction case)'        plant_census_anchor
  control censusanchor2 'AC1.census'      'truncating ONE anchor heading, watched by the census itself'      plant_census_anchor
  control reposcope   'AC7.noRepoScope'   'planting a repository-identity enforcement warranty'              plant_reposcope
  control matrixlie   'AC4.matrix'        "claiming, in design.md's own copy, a refusal design does not get"  plant_matrix_lie
  control newrole     'AC4.matrix.roles'  'adding a tenth agent file that carries the block and is unlisted'  plant_newrole
  control digeststale 'AC1.digest'        'editing the published span digest by one character'                plant_digest
  control digestbody  'AC1.digest'        'moving the BLOCK BODY in all ten copies and leaving the digest'     plant_digest_body
  control msreviewdrop 'R3.a'             'DELETING must_satisfy from review agentBlock concerns.items'        plant_ms_review_drop
  control msreviewtype 'R3.a'             'RETYPING must_satisfy to number (key present, no <error> path)'     plant_ms_review_type
  control mspeerdrop  'AC6.typed'         'DELETING must_satisfy from peer-review panelVerdict concerns.items' plant_ms_peer_drop
  control rncdrop     'R3.rnc'            'DELETING rationale_not_checked from 1 of its 3 subschemas'          plant_rnc_drop
  control creddrop    'AC15.52.replaced'  'removing the archived-verbatim exposure sentence'                   plant_credential_drop
  control credover    'AC15.52.replaced'  'appending an OVERCLAIM that the exposure is handled'                plant_credential_overclaim
  control credrem     'AC15.52.replaced'  'removing the WHOLE exposure note from review/remediation (QA MQ1)'  plant_credential_drop_rem
  control credpeer    'AC15.52.replaced'  'removing the exposure note from peer-review/must_satisfy (QA MQ2)'  plant_credential_drop_peer
  control credsplit   'AC15.52.replaced'  'SPLITTING the note so no one sentence carries it whole'             plant_credential_split
  control credinvert  'AC15.52.replaced'  'INVERTING the note into a false assurance (QA CM7)'                  plant_credential_invert
  control credsafe    'AC15.52.replaced'  'planting the assurance wording "safe to paste" (QA CM8)'             plant_credential_safe
  control pairflip    'AC3.pairsort'      'flipping the card-data case OUT -> IN in the ELEVENTH copy'          plant_pairflip
  control pairlit     'AC3.pairsort'      'drifting the IN case CITED LITERAL in the ELEVENTH copy (QA QM4)'     plant_pairlit
  control loci        'AC3.loci'          'stating the citation rule in a TWELFTH file the sentence does not name' plant_loci
  control locidrop    'AC3.loci'          'DELETING a locus the sentence names (secops.md Style bullet)'          plant_loci_drop
  control_survivor credreword 'AC15.52.replaced' 'REWORDING the note, meaning kept (QA MQ5)' plant_credential_reword \
    'the legs test the note SUBSTANCE, not a frozen sentence; a reworded note must not be reported as a missing warning.'
  control_survivor pairreword 'AC3.pairsort' 'REWORDING prose beside the sorted cases in the ELEVENTH copy (QA QM5)' plant_pairsort_reword \
    'the cell asserts the three sorting statements and the derived literal, not the paragraph around them; a reworded neighbour must not read as a sorting defect.'

  # The dangling-SHA cell reads GIT, not a file, so --src cannot reach it. Its
  # control drives the named test seam instead, with a REAL non-ancestor commit
  # (b279ffa, the SHA the retired AC15.59 would have had Dev ship).
  printf '               | planted: VERIFY40_EXTRA_SHA=b279ffa (a real commit object, NOT an ancestor of origin/main)\n'
  if bash "$SELF" --only 'AC15.59.replaced' > "$TMPROOT/c0.txt" 2>&1 && \
     ! VERIFY40_EXTRA_SHA=b279ffa bash "$SELF" --only 'AC15.59.replaced' > "$TMPROOT/c1.txt" 2>&1; then
    printf 'CONTROL-OK     %-22s %s\n' 'danglingsha' 'feeding a real non-ancestor commit to the resolver'
    printf '               | AC15.59.replaced: GREEN clean -> RED with a dangling SHA. The cell bites.\n'
    grep -E '^ +\| DANGLING' "$TMPROOT/c1.txt" | head -1
  else
    printf 'CONTROL-BROKEN %-22s %s\n' 'danglingsha' 'feeding a real non-ancestor commit to the resolver'
    printf '               | the cell did not discriminate; see %s\n' "$TMPROOT/c1.txt"
  fi
  printf '\nNOT PLANTABLE HERE, and why:\n'
  printf '  AC4.* blocking cells   their control is the PRE-CHANGE plugin root (AC4.*.ctl), built from\n'
  printf '                         git at the merge base, and it runs on every normal invocation.\n'
  printf '  AC10.down.*            validated against schemas read from git at the merge base, so a\n'
  printf '                         worktree mutation cannot reach them by construction.\n'
  printf '  AC3.manual, AC13       no mechanical control exists; see the MANUAL block.\n'
  exit 0
fi

# =============================================================================
banner() { printf '\n--- %s\n' "$1"; }
printf '=== verify-40.sh :: QA behavioural verification battery for #40\n'
printf '    repo : %s\n' "$REPO"
printf '    src  : %s\n' "$SRC"
printf '    head : %s\n' "$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null)"
printf '    base : %s (merge-base with origin/main)\n' "$(git -C "$REPO" merge-base origin/main HEAD 2>/dev/null | cut -c1-12)"
printf '    NOTE : this is a command, not a gate. Nothing runs it for you.\n'

MB="$(git -C "$REPO" merge-base origin/main HEAD 2>/dev/null)"
# Merge-base copies of the two files whose UNTOUCHED regions are asserted. Taken
# once, at the top, so no cell depends on another cell having run first (an
# earlier draft made AC11.stdtier SKIP under `--only AC11.*` for exactly that).
git -C "$REPO" show "$MB:plugins/pipeline/agents/secops.md" > "$TMPROOT/secops.base" 2>/dev/null
git -C "$REPO" show "$MB:plugins/pipeline/agents/qa.md"     > "$TMPROOT/qa.base"     2>/dev/null

# =============================================================================
banner 'H.jnode -- the harness asserts its own output convention'
# =============================================================================
if want 'H.jnode'; then B=GREEN
  # A probe that only ever PRINTS is a zero result about the harness, so this
  # one asserts. Against a synthetic fixture, not against the schema under test:
  # the convention must hold whatever Dev wrote. Three legs, because the three
  # repaired cells depend on three different behaviours of this helper -- the
  # bare-string leg (what they compare), the <error> leg (how they go red when
  # the field is absent) and the JSON leg (how they go red when the type is
  # changed rather than removed).
  printf '{"a":{"t":"string","n":7,"arr":["x","y"],"nul":null}}' > "$TMPROOT/j.json"
  jbad=0
  chk() { # label got want
    if [ "$2" = "$3" ]; then detail "OK   $1 -> [$2]"; else jbad=$((jbad+1)); detail "BAD  $1 -> [$2] want [$3]"; fi
  }
  chk 'a JSON string prints BARE (never quoted)' "$(jnode "$TMPROOT/j.json" 'd.a.t')" 'string'
  chk 'a number prints JSON'                     "$(jnode "$TMPROOT/j.json" 'd.a.n')" '7'
  chk 'an array prints JSON'                     "$(jnode "$TMPROOT/j.json" 'd.a.arr')" '["x","y"]'
  chk 'an absent key prints <undefined>'         "$(jnode "$TMPROOT/j.json" 'd.a.missing')" '<undefined>'
  chk 'an absent PARENT prints <error>'          "$(jnode "$TMPROOT/j.json" 'd.a.missing.deeper')" '<error>'
  assert_eq 'H.jnode' 'jnode prints strings bare; <undefined> and <error> are distinct sentinels' "$jbad" "0"
fi

# =============================================================================
banner 'AC1 / AC8 -- the ten-copy census and the replicated passage'
# =============================================================================

if want 'AC1.count'; then B=GREEN
  n="$(ls "$PP"/agents/*.md 2>/dev/null | wc -l | tr -d ' ')"
  assert_eq 'AC1.count' 'agents/ holds exactly nine agent files (the census denominator)' "$n" "9"
fi

CENSUS="$TMPROOT/census.txt"
: > "$CENSUS"
while IFS= read -r f; do extract_block "$f" | shasum | awk '{print $1}'; done < <(ten_files) > "$CENSUS"

# `printf '' | shasum`. Verified independently, not copied from a design note.
EMPTY_DIGEST='da39a3ee5e6b4b0d3255bfef95601890afd80709'

if want 'AC1.census'; then B=RED
  # THE ASSERTION IS "exactly one distinct hash, with count 10", NOT "is there
  # one group". A copy whose ANCHOR or TERMINATOR is broken extracts as EMPTY
  # and hashes to the empty-input digest, so TWO broken anchors would group
  # together and a "one group?" check would pass on a file that ships nothing.
  #
  # AND THE SAME TRAP CAUGHT THIS CELL. At the merge base all ten extractions
  # are empty, so the census reads `10 da39a3ee...`: one group, count 10, and an
  # earlier draft of this cell PASSED on a tree containing none of the change.
  # The empty-digest guard below is therefore part of the ASSERTION, not a
  # separate nicety, and AC1.nonempty is kept as its own cell so a partial
  # breakage (one file of ten) still has a dedicated name.
  groups="$(sort "$CENSUS" | uniq -c | sed 's/^ *//' | wc -l | tr -d ' ')"
  count1="$(sort "$CENSUS" | uniq -c | sed 's/^ *//' | awk '{print $1}' | head -1)"
  digest1="$(sort "$CENSUS" | uniq -c | sed 's/^ *//' | awk '{print $2}' | head -1)"
  printf '                     | census (count hash):\n'
  sort "$CENSUS" | uniq -c | sed 's/^ *//' | while IFS= read -r l; do detail "$l"; done
  if [ "$digest1" = "$EMPTY_DIGEST" ]; then
    no 'AC1.census' 'exactly one distinct block hash, with count 10, and it is not the empty digest'
    detail "the single group IS the empty-extraction digest: nothing was extracted from any file"
  else
    assert_eq 'AC1.census' 'exactly one distinct block hash, with count 10' "$groups/$count1" "1/10"
  fi
fi

if want 'AC1.nonempty'; then B=RED
  hits="$(grep -c "$EMPTY_DIGEST" "$CENSUS" | tr -d ' ')"
  assert_eq 'AC1.nonempty' 'no file extracts EMPTY (broken anchor / broken terminator)' "$hits" "0"
fi

if want 'AC1.digest'; then B=RED
  # THE SHIPPED CENSUS INSTRUCTION IS NOW SELF-CHECKING, and this cell checks the
  # self-check. The block names its own span digest on the line immediately after
  # the span, OUTSIDE it, because a digest cannot cover itself. Two legs:
  #   1. all ten files carry the SAME digest line (that line is outside the
  #      hashed span, so AC1.census cannot see it drift);
  #   2. the digest they carry EQUALS the hash the census just computed, so a
  #      block edited without updating the line fails loudly instead of shipping
  #      a stale number a reader would trust over their own run.
  d="$(sort -u "$CENSUS" | head -1)"
  bad=0; shipped=""
  while IFS= read -r f; do
    s="$(grep -oE "The span's sha1 on an undrifted tree is \`[0-9a-f]{40}\`" "$f" | grep -oE '[0-9a-f]{40}' | head -1)"
    if [ -z "$s" ]; then bad=$((bad+1)); detail "${f#$SRC/} ships no span digest line"; continue; fi
    if [ -z "$shipped" ]; then shipped="$s"
    elif [ "$s" != "$shipped" ]; then bad=$((bad+1)); detail "${f#$SRC/} ships a DIFFERENT digest: $s"; fi
  done < <(ten_files)
  if [ "$bad" -eq 0 ] && [ "$shipped" != "$d" ]; then
    bad=$((bad+1)); detail "the shipped digest is STALE: files say $shipped, the census computes $d"
  fi
  detail "computed $d / shipped ${shipped:-<none>}"
  assert_eq 'AC1.digest' 'the shipped span digest is identical in ten files AND matches the census' "$bad" "0"
fi

# ---------------------------------------------------------------------------
# AC1.verbatim IS RETIRED. Dev's ruling, 2026-08-22, on QA's round-3 finding,
# recorded here so the next reader sees the reasoning and not a missing cell.
#
# IT WAS NOT A PIN. It compared the ten shipped copies against
# design.json's canonical_block_text, and design.json is UNTRACKED and
# gitignored. The block changed in each of rounds 1, 2 and 3, and on each
# occasion the reference was rewritten to match the artifact in the same pass.
# The cell therefore passed at three different block texts (29b8188e, 3f92ab1a,
# 784ebcb6) and would have passed at a fourth. A reference that moves with its
# subject constrains nothing about its subject; it is a same-session
# consistency check wearing a pin's name, which is worse than no cell because a
# reader counts it as coverage.
#
# WHY RETIRE RATHER THAN RE-ANCHOR. Its whole subject -- the ten copies agree
# with EACH OTHER and with the digest they publish -- is carried by AC1.census
# and AC1.digest, which read only TRACKED files and which QA mutated in both
# legs and found load-bearing (censusword, censusanchor, digeststale,
# digestbody). Re-anchoring on a tracked reference would mean pinning the ten
# copies to an ELEVENTH tracked copy, which moves the same question one file
# over and adds a copy to keep in sync. The one genuinely uncensused copy of
# this rule, review.schema.json, is now covered by AC3.pairsort with its own
# control (pairflip), which is the coverage that was actually missing.
#
# design.json's canonical_block_text is now HISTORICAL: it holds the round-3
# text, nothing reads it, and it is not the source of truth for the block. The
# ten shipped files are.
# ---------------------------------------------------------------------------

if want 'AC1.placement'; then B=RED
  # The design's placement rule, checked as a rule and not as a line number:
  # in every agent file the FIRST `## ` heading after `## Identity` is the anchor.
  bad=0
  for f in "$PP"/agents/*.md; do
    h="$(awk '/^## Identity$/{f=1;next} f&&/^## /{print;exit}' "$f")"
    if [ "$h" != '## The property, not the fix (identical for every pipeline agent)' ]; then
      bad=$((bad+1)); detail "$(basename "$f"): next heading after Identity is: ${h:-<none>}"
    fi
  done
  assert_eq 'AC1.placement' 'the block follows ## Identity in all nine agent files' "$bad" "0"
fi

if want 'AC1.tenth'; then B=RED
  # AC1's tenth copy must be in the SHARED PHASE 4 PREAMBLE, beside the rule it
  # reconciles with -- not merely somewhere in commands/pipeline.md.
  g="$(grep -n 'Before you demand a guardrail, name the CORRECT work it refuses' "$CMD" | head -1 | cut -d: -f1)"
  a="$(grep -n '^## The property, not the fix (identical for every pipeline agent)$' "$CMD" | head -1 | cut -d: -f1)"
  if [ -z "$a" ]; then no 'AC1.tenth' 'the tenth copy sits in the Phase 4 preamble'; detail "anchor heading absent from commands/pipeline.md"
  elif [ -z "$g" ]; then no 'AC1.tenth' 'the tenth copy sits in the Phase 4 preamble'; detail "the guardrail-refuses line is gone; the preamble anchor moved"
  else
    d=$((a-g))
    if [ "$d" -gt 0 ] && [ "$d" -le 5 ]; then ok 'AC1.tenth' "the tenth copy sits in the Phase 4 preamble (${d} line(s) after the guardrail rule)"
    else no 'AC1.tenth' 'the tenth copy sits in the Phase 4 preamble'; detail "guardrail line $g, block anchor $a (want 1..5 lines after)"; fi
  fi
fi

if want 'AC8.colocation'; then B=RED
  # AC8: rule and FORCE in the SAME passage, checked per file over the EXTRACTED
  # passage, so a file whose enforcement note lives in another section fails.
  # Independent of the census on purpose: if one copy drifts, a reader can still
  # see which of AC8's parts survived, per file.
  bad=0
  while IFS= read -r f; do
    t="$(extract_block "$f")"
    miss=""
    case "$t" in *'concerns[]'*) ;; *) miss="$miss concerns[]";; esac
    case "$t" in *'vulnerabilities[]'*) ;; *) miss="$miss vulnerabilities[]";; esac
    case "$t" in *'compliance_flags[]'*) ;; *) miss="$miss compliance_flags[]";; esac
    case "$t" in *'peer-review'*) ;; *) miss="$miss peer-review";; esac
    case "$t" in *'#66'*) ;; *) miss="$miss '#66'";; esac
    case "$t" in *'2026-08-21'*) ;; *) miss="$miss the-date";; esac
    if [ -n "$miss" ]; then bad=$((bad+1)); detail "${f#$SRC/} lacks:$miss"; fi
  done < <(ten_files)
  assert_eq 'AC8.colocation' 'every copy carries the force clause in the same passage' "$bad" "0"
fi

# =============================================================================
banner 'AC2 -- the reconciliation of the two colliding rules, WITH its why'
# =============================================================================
if want 'AC2.reconcile'; then B=RED
  bad=0
  while IFS= read -r f; do
    t="$(extract_block "$f")"
    miss=""
    case "$t" in *'name the CORRECT work it refuses'*) ;; *) miss="$miss guardrail-rule";; esac
    case "$t" in *'evidence.md'*) ;; *) miss="$miss evidence.md";; esac
    case "$t" in *[Cc][Oo][Ss][Tt]*) ;; *) miss="$miss cost(why-1)";; esac
    case "$t" in *[Rr][Ee][Aa][Cc][Hh][Aa][Bb]*) ;; *) miss="$miss reachability(why-2)";; esac
    if [ -n "$miss" ]; then bad=$((bad+1)); detail "${f#$SRC/} lacks:$miss"; fi
  done < <(ten_files)
  assert_eq 'AC2.reconcile' 'both rules named, each with WHY it stays allowed' "$bad" "0"
fi

# =============================================================================
banner 'AC3 -- the discriminator, its exemptions, and its two named failure modes'
# =============================================================================
if want 'AC3.exemptions'; then B=RED
  bad=0
  while IFS= read -r f; do
    t="$(extract_block "$f")"
    miss=""
    case "$t" in *'rationale_not_checked'*) ;; *) miss="$miss non-binding-field";; esac
    case "$t" in *'measured by'*) ;; *) miss="$miss measured-by-example";; esac
    if [ -n "$miss" ]; then bad=$((bad+1)); detail "${f#$SRC/} lacks:$miss"; fi
  done < <(ten_files)
  assert_eq 'AC3.exemptions' 'both exemptions stated; the non-binding field is named' "$bad" "0"
fi

if want 'AC3.identifier'; then B=RED
  # R2(c): at least one shipped example is an externally-fixed IDENTIFIER, which
  # is the class round 1's three-numeric illustration set did not exhibit at all.
  bad=0
  while IFS= read -r f; do
    t="$(extract_block "$f")"
    case "$t" in
      *HMAC-SHA256*|*X-Frame-Options*|*'PKCE `S256`'*) ;;
      *) bad=$((bad+1)); detail "${f#$SRC/} carries no externally-fixed IDENTIFIER example";;
    esac
  done < <(ten_files)
  assert_eq 'AC3.identifier' 'every copy exhibits an externally-fixed IDENTIFIER example' "$bad" "0"
fi

if want 'AC3.pairsort'; then B=RED
  # THE COVERAGE GAP QA NAMED IN ROUND 3: nothing mechanical checked how the
  # worked cases are SORTED. AC3.identifier greps for the presence of an
  # identifier example; presence is not correctness, and for three rounds the
  # passage carried an IN-bounds exemplar ("per the applicable card-data
  # standard's authentication requirements") that names no openable document and
  # so fails the umbrella it exemplifies.
  #
  # THE ELEVENTH LOCATION IS THE POINT. The ten block copies are already pinned
  # byte-for-byte by AC1.census, so drift there is caught. review.schema.json
  # carries the SAME rule in its own words and NO census covers it, which is
  # exactly where round 3 promoted the defective pair to the rule's oracle.
  # This cell reads both, so a flip in the uncensused copy alone reddens it
  # (control: pairflip).
  #
  # THE IN CASE'S LITERAL IS DERIVED, NOT HARD-CODED TWICE (QA-N2, round 4).
  # The legs below used to match on "RFC 6238 section 5.2 fixes as its default",
  # which sits AFTER the number, so QA's QM4 changed the eleventh copy's `30
  # seconds` to `60 seconds` and this cell passed: the uncensused copy could
  # ship, in the rule's own oracle, an exemplar that IS the defect the rule
  # forbids - a citation whose named place does not fix the stated literal.
  # IN_EX is now read out of a block copy (the double-quoted span carrying the
  # citation) and required verbatim in all eleven locations, so the two
  # statements of one rule cannot disagree about the value. Deriving it also
  # means a legitimate future change of the exemplar needs no edit here, while
  # a change to ONE side reddens. Control: pairlit. Expected survivor: pairreword.
  bad=0
  CARD="per the applicable card-data standard's authentication requirements"
  IN_EX="$(extract_block "$(ten_files | head -1)" | grep -o '"[^"]*RFC 6238[^"]*"' | head -1 | tr -d '"')"
  if [ -z "$IN_EX" ]; then
    bad=$((bad+1)); detail "could not DERIVE the IN exemplar from the block (a quoted span citing RFC 6238); the derivation anchor moved, and every leg below that uses it is vacuous"
  else
    detail "IN exemplar derived from the block: \"$IN_EX\""
    # A derivation that came back without a literal in it would compare two
    # strings and prove nothing about the value, which is the whole subject.
    case "$IN_EX" in
      *[0-9]*) ;;
      *) bad=$((bad+1)); detail "the derived IN exemplar carries NO literal; a citation rule's IN case must bind on one";;
    esac
  fi
  while IFS= read -r f; do
    t="$(extract_block "$f")"
    case "$t" in
      *"$CARD\" leaves a reader nothing to open"*) ;;
      *) bad=$((bad+1)); detail "${f#$SRC/}: the card-data case is not sorted OUT in the block";;
    esac
    case "$t" in
      *'A citation meets it only when it names the DOCUMENT and the PLACE INSIDE IT'*) ;;
      *) bad=$((bad+1)); detail "${f#$SRC/}: no document-AND-place citation test";;
    esac
    case "$t" in
      *"$IN_EX"*) ;;
      *) bad=$((bad+1)); detail "${f#$SRC/}: the IN case is absent or does not carry the derived exemplar verbatim (literal included)";;
    esac
  done < <(ten_files)
  rs="$(jnode "$RS" 'd.properties.secops.allOf[1].properties.vulnerabilities.items.properties.remediation.description')"
  case "$rs" in
    *"$CARD' is OUT"*) ;;
    *) bad=$((bad+1)); detail "review.schema.json/remediation: the card-data case is not sorted OUT";;
  esac
  case "$rs" in
    *"$CARD' is IN"*) bad=$((bad+1)); detail "review.schema.json/remediation: the card-data case is sorted IN -- it names no openable document";;
  esac
  case "$rs" in
    *"'$IN_EX' is IN"*) ;;
    *) bad=$((bad+1)); detail "review.schema.json/remediation: the IN case is absent, or its cited literal DISAGREES with the block's (block says: \"$IN_EX\")";;
  esac
  assert_eq 'AC3.pairsort' 'the worked cases are sorted the same way in all eleven locations, and every IN case names an openable source carrying the same literal' "$bad" "0"
fi

if want 'AC3.loci'; then B=RED
  # THIS CELL EXISTS BECAUSE OF WHAT THE ROUND-4 NIT PASS ITSELF SHIPPED.
  # SecOps N1 said the schema's propagation instruction named TWO loci where
  # FOUR exist, and the fix names the four. That fix ships an ENUMERATION in
  # prose - the same shape as the defect QA-N1 was about one level down - and
  # nothing checked it: add a fifth statement of the citation rule anywhere in
  # the plugin, or delete secops.md's Style bullet, and the shipped sentence
  # becomes false with every other check green. So the sentence gets a census.
  #
  # STATED AS A RULE, NOT AS A FILE LIST, so it re-derives instead of freezing:
  # the umbrella phrase may appear ONCE in each of the ten block copies (that
  # occurrence is the block's own), ONCE in review.schema.json, and TWICE MORE
  # in secops.md and nowhere else - those two extra being the Style bullet and
  # the VETO template the sentence names. Thirteen occurrences over eleven
  # files, which is the count SecOps measured by hand on 2026-08-22.
  # Controls: plant_loci (a twelfth file acquires the phrase) and plant_loci_drop
  # (a named locus disappears), one in each direction.
  #
  # WHAT THIS CELL DOES NOT DO, stated so nobody reads it as more than it is: it
  # counts STATEMENTS, it does not compare their CONTENT. SecOps's M6 and M7 -
  # the Style bullet made to contradict the block, the VETO template's source
  # requirement gutted - change the wording and not the count, and they survive
  # this cell exactly as they survive the digest. The digest still covers 10 of
  # the 13. All this closes is the silence around a FIFTH locus appearing, or a
  # named one vanishing, which is what the propagation sentence newly asserts.
  bad=0
  UMB='open and find that literal in'
  tenlist="$(ten_files)"
  total=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    c="${line%% *}"; f="${line#* }"
    total=$((total+c))
    exp=0
    case "$tenlist" in *"$f"*) exp=1;; esac
    case "$(basename "$f")" in secops.md) exp=3;; review.schema.json) exp=1;; esac
    if [ "$exp" = 0 ]; then
      bad=$((bad+1)); detail "${f#$SRC/}: an UNLISTED statement of the citation rule ($c occurrence(s)); the schema sentence names four loci and this is not one of them"
    elif [ "$c" != "$exp" ]; then
      bad=$((bad+1)); detail "${f#$SRC/}: $c occurrence(s) of the umbrella phrase, expected $exp"
    fi
  done <<LOCI_EOF
$(find "$SRC/plugins/pipeline" -type f \( -name '*.md' -o -name '*.json' \) -print0 2>/dev/null \
  | xargs -0 grep -c -i -F "$UMB" 2>/dev/null | awk -F: '$2>0 {print $2" "$1}' | sort -k2)
LOCI_EOF
  [ "$total" = 13 ] || { bad=$((bad+1)); detail "the citation rule is stated $total time(s) across the plugin; the shipped sentence is written for 13 (ten block copies + this description + secops.md's two)"; }
  rs2="$(jnode "$RS" 'd.properties.secops.allOf[1].properties.vulnerabilities.items.properties.remediation.description')"
  miss=""
  case "$rs2" in *'ten files'*) ;; *) miss="$miss the-ten-block-copies";; esac
  case "$rs2" in *'this description'*) ;; *) miss="$miss this-description";; esac
  case "$rs2" in *'Style bullet'*) ;; *) miss="$miss secops-Style-bullet";; esac
  case "$rs2" in *'VETO template'*) ;; *) miss="$miss secops-VETO-template";; esac
  [ -z "$miss" ] || { bad=$((bad+1)); detail "the propagation sentence does not name every locus it must; lacks:$miss"; }
  assert_eq 'AC3.loci' 'every statement of the citation rule is one the propagation sentence names, and it names all four' "$bad" "0"
fi

if want 'AC3.form'; then B=RED
  # The OVER-REFUSING failure mode AC3 names by hand: attaching "however
  # abstractly it is phrased" to the bound's ORIGIN refuses the canonical
  # property form. Absence alone would be vacuous while the block is missing, so
  # the cell requires the positive form-test clause to be PRESENT first.
  bad=0
  while IFS= read -r f; do
    t="$(extract_block "$f")"
    case "$t" in
      *'however abstractly it is phrased'*) bad=$((bad+1)); detail "${f#$SRC/} ships the over-refusing wording";;
      *) ;;
    esac
    case "$t" in
      *"THE TEST IS THE ASK'S FORM"*|*"the ask's FORM"*|*"ASK'S FORM"*) ;;
      *) bad=$((bad+1)); detail "${f#$SRC/} states no ask's-FORM discriminator (absence check would be vacuous)";;
    esac
  done < <(ten_files)
  assert_eq 'AC3.form' "discriminator is the ask's FORM, not the bound's origin" "$bad" "0"
fi

# =============================================================================
banner 'R3 -- the typed home (the precondition AC4 exercises)'
# =============================================================================
if want 'R3.a'; then B=RED
  assert_eq 'R3.a' 'review agentBlock concerns.items.must_satisfy is a string' \
    "$(jnode "$RS" 'd.definitions.agentBlock.properties.concerns.items.properties.must_satisfy.type')" 'string'
  assert_eq 'R3.a.req' 'must_satisfy IS in that subschema required list' \
    "$(jnode "$RS" 'd.definitions.agentBlock.properties.concerns.items.required.slice().sort().join(",")')" \
    'description,must_satisfy,severity'
fi

if want 'R3.b'; then B=RED
  assert_eq 'R3.b' 'secops vulnerabilities.items required is exactly severity+description+remediation' \
    "$(jnode "$RS" 'd.properties.secops.allOf[1].properties.vulnerabilities.items.required.slice().sort().join(",")')" \
    'description,remediation,severity'
  rd="$(jnode "$RS" 'd.properties.secops.allOf[1].properties.vulnerabilities.items.properties.remediation.description||""')"
  if [ ${#rd} -ge 40 ]; then ok 'R3.b.desc' 'remediation gains a description (it had NONE at the base)'
  else no 'R3.b.desc' 'remediation gains a description (it had NONE at the base)'; detail "description is ${#rd} chars: ${rd:-<absent>}"; fi
fi

if want 'R3.rnc'; then B=RED
  bad=0
  for spec in \
    "$RS|d.definitions.agentBlock.properties.concerns.items" \
    "$RS|d.properties.secops.allOf[1].properties.vulnerabilities.items" \
    "$PS|d.definitions.panelVerdict.properties.concerns.items"; do
    f="${spec%%|*}"; p="${spec#*|}"
    t="$(jnode "$f" "$p.properties.rationale_not_checked.type")"
    [ "$t" = 'string' ] || { bad=$((bad+1)); detail "$(basename "$f") $p: rationale_not_checked type is [$t]"; }
    r="$(jnode "$f" "($p.required||[]).join(',')")"
    case ",$r," in *,rationale_not_checked,*) bad=$((bad+1)); detail "$(basename "$f") $p: rationale_not_checked is REQUIRED and must never be";; esac
  done
  assert_eq 'R3.rnc' 'rationale_not_checked typed in all three subschemas, required in none' "$bad" "0"
fi

# =============================================================================
banner 'AC4 -- the location matrix, driven through the SHIPPED hook'
# =============================================================================
# ENVIRONMENT, LOAD-BEARING (#66): every cell below uses a BARE agent_type.
# hooks/subagent-stop.sh -> validate-pipeline-artifact.mjs looks AGENT_RULES up
# by bare role name and returns zero failures for a NAMESPACED type before any
# root, mtime or active-issue resolution. A matrix run under `pipeline:dba` is
# silent in every cell and is a zero result about the harness, not about the
# schema. #66 owns that defect and it is OUT OF SCOPE here. The inertness is
# ASSERTED below (H.namespaced), not merely announced.
printf '                     | agent_type used in every AC4 cell: BARE (dba / secops). See #66.\n'

mk_plugin now ""      >/dev/null 2>&1; PLUGIN_NOW="$RET"
mk_plugin base "$MB"  >/dev/null 2>&1; PLUGIN_BASE="$RET"

if [ -z "${PLUGIN_NOW:-}" ] || [ -z "${PLUGIN_BASE:-}" ]; then
  B=GREEN; skip 'AC4.*' 'could not build isolated plugin roots (git show failed?)'
else

if want 'H.harness'; then B=GREEN
  # THE HARNESS'S OWN NON-ZERO CONTROL. A shard the CURRENT schema already
  # refuses (verdict not in the enum). If this is silent, every "SILENT" result
  # below is about a broken sandbox, not about a schema.
  mk_sandbox h review.dba.json "$(dba_bad_verdict)"; s="$RET"
  hook_blocks 'H.harness' 'CONTROL: the hook fires at all (invalid verdict blocks)' "$PLUGIN_NOW" dba "$s" 'verdict'
fi

if want 'H.namespaced'; then B=GREEN
  # The inertness that makes the BARE choice load-bearing, asserted with the one
  # fixture that is known to block under a bare name. Expected SILENT. This is a
  # known, tracked, out-of-scope defect (#66), NOT a hole this change opened.
  mk_sandbox h review.dba.json "$(dba_bad_verdict)"; s="$RET"
  hook_silent 'H.namespaced' 'KNOWN #66: the same fixture is INERT under pipeline:dba' "$PLUGIN_NOW" 'pipeline:dba' "$s"
fi

if want 'AC4.dba.absent'; then B=RED
  mk_sandbox a review.dba.json "$(dba_shard '')"; s="$RET"
  hook_blocks 'AC4.dba.absent' 'concerns[] row without the property -> block naming it' "$PLUGIN_NOW" dba "$s" 'must_satisfy'
fi
if want 'AC4.dba.absent.ctl'; then B=GREEN
  mk_sandbox a review.dba.json "$(dba_shard '')"; s="$RET"
  hook_silent 'AC4.dba.absent.ctl' 'NON-ZERO CONTROL: same shard is SILENT on the pre-change schemas' "$PLUGIN_BASE" dba "$s"
fi
if want 'AC4.dba.present'; then B=GREEN
  mk_sandbox b review.dba.json "$(dba_shard ',"must_satisfy":"The deploy path must not execute any statement from the down region, checked by running the file through the deploy path and asserting the down statements produce no effect."')"; s="$RET"
  hook_silent 'AC4.dba.present' 'concerns[] row WITH a non-empty property -> silent' "$PLUGIN_NOW" dba "$s"
fi
if want 'AC4.dba.empty'; then B=GREEN
  # THE EMPTY STRING SATISFIES. Demonstrated, not assumed: the walker has no
  # minLength, so "" is the cheapest value that satisfies the new required field.
  # This cell passing is the DISCLOSED RESIDUAL, not a defect in the battery.
  mk_sandbox c review.dba.json "$(dba_shard ',"must_satisfy":""')"; s="$RET"
  hook_silent 'AC4.dba.empty' 'DISCLOSED RESIDUAL: the empty string satisfies the field' "$PLUGIN_NOW" dba "$s"
fi

if want 'AC4.secops.concerns'; then B=RED
  mk_sandbox d review.secops.json "$(secops_concern_shard '')"; s="$RET"
  hook_blocks 'AC4.secops.concerns' 'SecOps concerns[] row without the property -> block' "$PLUGIN_NOW" secops "$s" 'must_satisfy'
fi
if want 'AC4.secops.vuln'; then B=RED
  # THE CELL THAT PLACES THE FINDING OUTSIDE concerns[]: a critical auth bypass
  # filed with `concerns: []`, which is the shape secops.md's own artifact
  # contract tells SecOps to write. A change that binds only on concerns[] binds
  # everywhere except the role holding the veto.
  mk_sandbox e review.secops.json "$(secops_shard '')"; s="$RET"
  hook_blocks 'AC4.secops.vuln' 'critical vuln with concerns:[] and no remediation -> block' "$PLUGIN_NOW" secops "$s" 'remediation'
fi
if want 'AC4.secops.vuln.ctl'; then B=GREEN
  mk_sandbox e review.secops.json "$(secops_shard '')"; s="$RET"
  hook_silent 'AC4.secops.vuln.ctl' 'NON-ZERO CONTROL: same shard is SILENT on the pre-change schemas' "$PLUGIN_BASE" secops "$s"
fi
if want 'AC4.secops.present'; then B=GREEN
  mk_sandbox f review.secops.json "$(secops_shard ',"remediation":"The endpoint must reject any session cookie whose signature does not verify, measured by replaying a forged cookie and asserting a 401 before the handler runs."')"; s="$RET"
  hook_silent 'AC4.secops.present' 'vulnerabilities[] row WITH a non-empty property -> silent' "$PLUGIN_NOW" secops "$s"
fi
if want 'AC4.secops.empty'; then B=GREEN
  mk_sandbox g review.secops.json "$(secops_shard ',"remediation":""')"; s="$RET"
  hook_silent 'AC4.secops.empty' 'DISCLOSED RESIDUAL: empty remediation satisfies' "$PLUGIN_NOW" secops "$s"
fi

if want 'AC4.compliance'; then B=GREEN
  # THE UNGUARDED THIRD CHANNEL. A VETO with no statute, no concern and no
  # action validates SILENT, before AND after. The criterion is the agreement
  # between the SHIPPED STATEMENT's prediction (AC8.colocation asserts the
  # statement NAMES this channel) and this observation.
  mk_sandbox i review.secops.json "$(secops_veto_empty_flag)"; s="$RET"
  hook_silent 'AC4.compliance' 'VETO via compliance_flags:[{}] is SILENT after the change' "$PLUGIN_NOW" secops "$s"
fi
if want 'AC4.compliance.base'; then B=GREEN
  mk_sandbox i review.secops.json "$(secops_veto_empty_flag)"; s="$RET"
  hook_silent 'AC4.compliance.base' 'and SILENT before it too (unchanged, not newly opened)' "$PLUGIN_BASE" secops "$s"
fi

# ---- AC4.matrix: the CROSS PRODUCT of (role receiving a copy) x (location) ---
# Added in the panel fix round, at QA's instruction, by Dev. QA owns this file
# and was not available to write the cell; the reason it exists is recorded in
# impl-report.json. Its two predecessors (AC4.dba.*, AC4.secops.*) stay: they
# are the deep single-role cells, this is the wide one.
if want 'AC4.matrix'; then B=RED
  bad=0; blocked=""; silent=""; vulnblock=""; rows=0
  while IFS="$(printf '\t')" read -r role f; do
    [ -n "$role" ] || continue
    if [ "$role" = "ORCHESTRATOR" ]; then
      # The main thread has no SubagentStop, so there is nothing to observe. The
      # claim its copy makes about that is checked as TEXT, below.
      case "$(extract_block "$f")" in
        *'no SubagentStop at all'*) ;;
        *) bad=$((bad+1)); detail "${f#$SRC/}: the orchestrator's own copy does not say its thread has no SubagentStop";;
      esac
      continue
    fi
    art="$(role_artifact "$role" "$f")"
    ref="$(block_list "$f" 'REFUSED AT (')"
    non="$(block_list "$f" 'NOT REFUSED AT (')"
    if [ -z "$ref" ] || [ -z "$non" ]; then
      bad=$((bad+1)); detail "${f#$SRC/}: the block states no REFUSED AT / NOT REFUSED AT role list"; continue
    fi
    c="$(mx_probe "$PLUGIN_NOW" "$role" "$art" "$(mx_concerns)" 'must_satisfy')"
    v="$(mx_probe "$PLUGIN_NOW" "$role" "$art" "$(mx_vuln)"     'remediation')"
    g="$(mx_probe "$PLUGIN_NOW" "$role" "$art" "$(mx_flags)"    'compliance')"
    rows=$((rows+1))
    detail "$(printf '%-13s %-26s concerns=%-11s vulnerabilities=%-11s compliance_flags=%s' "$role" "$art" "$c" "$v" "$g")"
    [ "$c" = 'BLOCK' ] && blocked="$blocked $role" || silent="$silent $role"
    [ "$v" = 'BLOCK' ] && vulnblock="$vulnblock $role"
    # (i) the copy delivered to this role must be TRUE for this role.
    case " $ref " in
      *" $role "*) [ "$c" = 'BLOCK' ] || { bad=$((bad+1)); detail "  ^ CLAIMS MORE THAN IT KNOWS: this copy lists $role as REFUSED and the hook is $c"; };;
      *) case " $non " in
           *" $role "*) [ "$c" = 'SILENT' ] || { bad=$((bad+1)); detail "  ^ this copy lists $role as NOT REFUSED and the hook is $c"; };;
           *) bad=$((bad+1)); detail "  ^ $role appears in NEITHER list in its own copy of the block";;
         esac;;
    esac
    # (ii) compliance_flags is unguarded for every role, as the block says.
    [ "$g" = 'SILENT' ] || { bad=$((bad+1)); detail "  ^ compliance_flags blocked for $role; the block says that channel is unguarded"; }
    # (iii) no role outside the REFUSED list may block on vulnerabilities either.
    if [ "$v" = 'BLOCK' ]; then
      case " $ref " in *" $role "*) ;; *) bad=$((bad+1)); detail "  ^ $role refuses on vulnerabilities[] but its copy does not list it as REFUSED";; esac
    fi
  done < <(block_roles)
  # NON-VACUITY, three ways: the matrix ran, it separates the two outcomes, and
  # the vulnerabilities axis fired somewhere. An all-SILENT matrix is a broken
  # sandbox reported as agreement.
  [ "$rows" -ge 9 ] && [ -n "$blocked" ] && [ -n "$silent" ] && [ -n "$vulnblock" ] || {
    bad=$((bad+1)); detail "VACUOUS: rows=$rows blocked=[${blocked:-none} ] silent=[${silent:-none} ] vuln=[${vulnblock:-none} ]"; }
  detail "observed BLOCK on concerns[]:${blocked:- none}"
  detail "observed SILENT on concerns[]:${silent:- none}"
  assert_eq 'AC4.matrix' 'every copy of the block is TRUE for the role it is delivered to, across all three locations' "$bad" "0"
fi

if want 'AC4.matrix.roles'; then B=RED
  # THE ROLE SET IS CLOSED AND DERIVED. Two directions, because a hand-written
  # row would satisfy either one alone:
  #   1. every role that RECEIVES a copy is accounted for in that copy's own two
  #      lists (nobody is silently absent);
  #   2. every Phase 2 review shard the ORCHESTRATOR names belongs to a role that
  #      receives a copy (nobody writes a Phase 2 concerns[] without the rule).
  bad=0; derived=""
  while IFS="$(printf '\t')" read -r role f; do
    [ "$role" = "ORCHESTRATOR" ] && continue
    derived="$derived $role"
  done < <(block_roles)
  first="$(block_roles | head -1 | cut -f2)"
  listed="$(printf '%s %s' "$(block_list "$first" 'REFUSED AT (')" "$(block_list "$first" 'NOT REFUSED AT (')" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ')"
  want_set="$(printf '%s' "$derived" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ')"
  if [ "$listed" != "$want_set" ]; then
    bad=$((bad+1)); detail "roles carrying the block: [$want_set]"; detail "roles named in the block : [$listed]"
  fi
  # Direction 2: the orchestrator's own Phase 2 shard names, mapped back to the
  # role whose contract claims each one.
  orch="$(grep -oE 'review\.[a-z_]+\.json' "$CMD" | grep -v '^review\.schema\.json$' | sort -u)"
  owned=""
  while IFS="$(printf '\t')" read -r role f; do
    [ "$role" = "ORCHESTRATOR" ] && continue
    owned="$owned $(role_artifact "$role" "$f")"
  done < <(block_roles)
  n=0
  for a in $orch; do
    n=$((n+1))
    case " $owned " in *" $a "*) ;; *) bad=$((bad+1)); detail "the orchestrator names $a and no block-carrying contract claims it";; esac
  done
  [ "$n" -ge 1 ] || { bad=$((bad+1)); detail "VACUOUS: the orchestrator names no review.<role>.json shard at all"; }
  detail "derived roles: [$want_set]"; detail "orchestrator-named shards ($n): $(printf '%s' "$orch" | tr '\n' ' ')"
  assert_eq 'AC4.matrix.roles' 'the role set is DERIVED and closed in both directions' "$bad" "0"
fi

# ---- AC4.live: the only control in this battery that nobody planted ---------
# QA named this cell in its Phase 4 delta shard, wearing the test-author hat, and
# named the mechanism: run checkArtifacts over THIS RUN'S OWN merged review.json
# for all nine roles and require the set of roles it refuses to equal the block's
# REFUSED AT list. Every other cell in the AC4 family drives fixtures this
# battery wrote. This one reads eleven real concerns rows, written by this run's
# Phase 2 before the required field existed, and watches the gate fire on exactly
# three roles and stay silent for the other six -- including `design`, which IS a
# Phase 2 reviewer and whose shard is unvalidated.
#
# `now` is pinned to the file's own mtime so the 30-minute recency filter cannot
# make this cell's answer depend on how long the battery has been running. That
# is the same window a real stop uses; pinning it removes the clock, not the rule.
#
# EXPIRY, AND IT IS IN THE ASSERTION AND NOT ONLY IN THIS COMMENT: this control's
# subject is the ABSENCE of must_satisfy on those rows. If review.json is ever
# rewritten with the field on every concern, the cell has no subject left and
# reports VACUOUS rather than passing -- at which point re-anchor it on another
# pre-contract merged review.json, or retire it and say why.
if want 'AC4.live'; then B=RED
  if [ "$SRC" != "$REPO" ]; then skip 'AC4.live' 'needs the real worktree and its live .pipeline (--src override in effect)'
  elif [ ! -f "$SELF_DIR/review.json" ]; then skip 'AC4.live' 'this run has no merged review.json to read'
  else
    live="$(node --input-type=module -e '
      import { checkArtifacts } from "'"$PP"'/scripts/validate-pipeline-artifact.mjs";
      import { statSync, readFileSync } from "node:fs";
      const rv = "'"$SELF_DIR"'/review.json";
      const now = statSync(rv).mtimeMs;
      const roles = ["art-director","ba","dba","design","dev","devops","librarian","qa","secops"];
      const hit = [];
      for (const r of roles) {
        const { failures } = checkArtifacts(r, { cwd: "'"$REPO"'", active_issue: "40" }, now);
        if (failures.some(x => x.startsWith("review.json/") && x.includes("must_satisfy"))) hit.push(r);
      }
      const doc = JSON.parse(readFileSync(rv, "utf8"));
      let rows = 0, bare = 0;
      for (const r of roles) for (const c of (doc[r]?.concerns ?? [])) { rows++; if (!("must_satisfy" in c)) bare++; }
      console.log(hit.join(" ") + "|" + rows + "|" + bare);
    ' 2>&1)"
    hit="${live%%|*}"; rest="${live#*|}"; rows="${rest%%|*}"; bare="${rest##*|}"
    refused="$(block_list "$(block_roles | head -1 | cut -f2)" 'REFUSED AT (')"
    got="$(printf '%s' "$hit" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ')"
    detail "live review.json: $rows concerns rows across the nine roles, $bare of them carrying no must_satisfy"
    detail "refused on review.json: [${got:-none}]   block's REFUSED AT list: [$refused]"
    if [ "$bare" = "0" ]; then
      no 'AC4.live' 'the live merged review.json refuses exactly the roles the block lists as REFUSED'
      detail "VACUOUS: every concern in review.json now carries must_satisfy. If this is false the"
      detail "precedent was fixed and this control needs a new subject: re-anchor it on another"
      detail "pre-contract merged review.json, or retire it and record why."
    else
      assert_eq 'AC4.live' 'the live merged review.json refuses exactly the roles the block lists as REFUSED' "$got" "$refused"
    fi
  fi
fi

# ---- AC10 down direction, through the same shipped hook ----------------------
if want 'AC10.down.review'; then B=GREEN
  mk_sandbox j review.dba.json "$(down_review_shard)"; s="$RET"
  hook_silent 'AC10.down.review' 'DOWN: new-contract concerns[] + undeclared keys pass the OLD agentBlock' "$PLUGIN_BASE" dba "$s"
fi
if want 'AC10.down.secops'; then B=GREEN
  mk_sandbox k review.secops.json "$(down_secops_shard)"; s="$RET"
  hook_silent 'AC10.down.secops' 'DOWN: vulnerabilities[] row with resolved/resolution passes the OLD secops block' "$PLUGIN_BASE" secops "$s"
fi
if want 'AC10.down.peer'; then B=GREEN
  mk_sandbox l peer-review.dba.json "$(down_peer_shard)"; s="$RET"
  hook_silent 'AC10.down.peer' 'DOWN: new-contract panelVerdict passes the OLD peer-review schema' "$PLUGIN_BASE" dba "$s"
fi

# ---- the documented EXPECTED SURVIVOR ---------------------------------------
if want 'SURVIVOR.selftest'; then B=GREEN
  # A battery in which every mutation reddens cannot tell real coverage from a
  # harness that reddens indiscriminately. THIS MUTATION IS EXPECTED TO SURVIVE:
  # dropping must_satisfy from agentBlock's required list leaves the shipped
  # validator self-test at 68 passed / 0 failed, because the self-test builds
  # every review agentBlock with `concerns: []` and never reaches the concern
  # item subschema. Reason it is not a hole: the self-test is a NON-REGRESSION
  # signal and AC5 says so; the cell that dies under this mutation is
  # AC4.dba.absent, asserted immediately below. Issue: #40 / AC5.
  mk_plugin mut "" >/dev/null 2>&1; mp="$RET"
  node -e 'const f=process.argv[1];const fs=require("fs");const d=JSON.parse(fs.readFileSync(f,"utf8"));
           const it=d.definitions.agentBlock.properties.concerns.items;
           it.required=(it.required||[]).filter(x=>x!=="must_satisfy");
           fs.writeFileSync(f,JSON.stringify(d,null,2));
           process.stdout.write("mutated required -> "+JSON.stringify(it.required));' \
    "$mp/schemas/review.schema.json" > "$TMPROOT/mut.txt" 2>/dev/null
  detail "$(cat "$TMPROOT/mut.txt" 2>/dev/null)"   # prove the edit landed
  st="$(node "$mp/scripts/validate-pipeline-artifact.mjs" --self-test 2>&1 | tail -1)"
  case "$st" in
    *'0 failed'*) ok 'SURVIVOR.selftest' "EXPECTED SURVIVOR: self-test blind to it ($st)";;
    *) no 'SURVIVOR.selftest' 'EXPECTED SURVIVOR: self-test blind to it'; detail "got: $st";;
  esac
  # The survivor is only meaningful beside a mutation that DIES. Asserted as a
  # DISCRIMINATION, not as a single silence: at the merge base both halves are
  # silent, so a bare "the mutant is silent" cell would pass on a tree with none
  # of the change in it -- the same vacuity that caught AC1.census.
  B=RED
  mk_sandbox a review.dba.json "$(dba_shard '')"; s="$RET"
  run_hook "$PLUGIN_NOW" dba "$s"; unmut="$HOOK_OUT"
  run_hook "$mp" dba "$s";         mut="$HOOK_OUT"
  if [ -n "$unmut" ] && [ -z "$mut" ]; then
    ok 'SURVIVOR.discriminates' 'the mutation KILLS AC4.dba.absent while the self-test survives it'
  else
    no 'SURVIVOR.discriminates' 'the mutation KILLS AC4.dba.absent while the self-test survives it'
    detail "unmutated plugin: $([ -n "$unmut" ] && echo BLOCK || echo SILENT) (want BLOCK)"
    detail "mutated   plugin: $([ -n "$mut" ] && echo BLOCK || echo SILENT) (want SILENT)"
  fi
fi

fi  # plugin roots built

# =============================================================================
banner 'AC5 -- non-regression, the rebase precondition, and the path assertion'
# =============================================================================
if want 'AC5.selftest'; then B=GREEN
  # NON-REGRESSION, NOT COVERAGE. The self-test builds every review agentBlock
  # with `concerns: []`, so it never reaches the concern item subschema and its
  # result is IDENTICAL before and after this change. Citing 68/0 as evidence
  # that the new field works is a misreading of AC5. See SURVIVOR.selftest.
  out="$(node "$PP/scripts/validate-pipeline-artifact.mjs" --self-test 2>&1 | tail -1)"
  p="$(printf '%s' "$out" | sed -n 's/.*self-test: \([0-9]*\) passed.*/\1/p')"
  f="$(printf '%s' "$out" | sed -n 's/.*, \([0-9]*\) failed.*/\1/p')"
  if [ "${f:-x}" = "0" ] && [ "${p:-0}" -ge 68 ]; then ok 'AC5.selftest' "NON-REGRESSION (not coverage): $out"
  else no 'AC5.selftest' 'NON-REGRESSION (not coverage): >=68 passed / 0 failed'; detail "got: $out"; fi
fi

if want 'AC5.rebased'; then B=RED
  n="$(git -C "$REPO" rev-list --count HEAD..origin/main 2>/dev/null)"
  assert_eq 'AC5.rebased' 'HEAD carries origin/main (R11: line/suite claims are owed a re-measure otherwise)' "${n:-?}" "0"
fi

if want 'AC5.paths'; then B=GREEN
  # The cheapest way to make a suite green is to edit the suite. AC16's half is
  # here too: config-doctor.mjs must be absent from the diff.
  bad="$(git -C "$REPO" diff --name-only origin/main...HEAD 2>/dev/null | grep -E '^(plugins/pipeline/(tests|hooks|scripts)/|\.github/workflows/|plugins/pipeline/schemas/status\.schema\.json$)' || true)"
  if [ -z "$bad" ]; then ok 'AC5.paths' 'no forbidden path in the diff (tests/ hooks/ scripts/ workflows status.schema.json)'
  else no 'AC5.paths' 'no forbidden path in the diff'; printf '%s\n' "$bad" | while IFS= read -r l; do detail "FORBIDDEN: $l"; done; fi
fi

# =============================================================================
banner 'AC6 / AC7 / AC10 -- the schema-side contract and the honesty record'
# =============================================================================
if want 'AC6.typed'; then B=RED
  assert_eq 'AC6.typed' 'peer-review panelVerdict concerns.items.must_satisfy is typed' \
    "$(jnode "$PS" 'd.definitions.panelVerdict.properties.concerns.items.properties.must_satisfy.type')" 'string'
fi
if want 'AC6.notrequired'; then B=GREEN
  # It has NO required list today, so AC6 is satisfied by adding none. Dev must
  # not create one: doing so turns the shipped self-test to 65/3 and the fix
  # lives in a file this change may not edit (#38).
  assert_eq 'AC6.notrequired' 'panelVerdict concerns.items gains NO required list' \
    "$(jnode "$PS" 'd.definitions.panelVerdict.properties.concerns.items.required===undefined?"none":JSON.stringify(d.definitions.panelVerdict.properties.concerns.items.required)')" 'none'
fi
if want 'AC6.description'; then B=RED
  t="$(jnode "$PS" 'd.definitions.panelVerdict.properties.concerns.items.properties.must_satisfy.description||""')"
  miss=""
  case "$t" in *'#38'*) ;; *) miss="$miss '#38'";; esac
  case "$t" in *self-test*|*'self test'*) ;; *) miss="$miss names-the-self-test";; esac
  case "$t" in *'68'*) ;; *) miss="$miss the-68/65-count";; esac
  case "$t" in *validate-pipeline-artifact*) ;; *) miss="$miss names-the-file";; esac
  if [ -z "$miss" ]; then ok 'AC6.description' 'the unenforced-here reason is written where it is read'
  else no 'AC6.description' 'the unenforced-here reason is written where it is read'; detail "lacks:$miss"; fi
fi

if want 'AC10.addprops'; then B=GREEN
  # One such edit turns a reversible field addition into a one-way migration.
  bad=0
  for spec in \
    "$RS|d.definitions.agentBlock.properties.concerns.items" \
    "$RS|d.properties.secops.allOf[1].properties.vulnerabilities.items" \
    "$PS|d.definitions.panelVerdict.properties.concerns.items"; do
    f="${spec%%|*}"; p="${spec#*|}"
    v="$(jnode "$f" "$p.additionalProperties")"
    [ "$v" = '<undefined>' ] || { bad=$((bad+1)); detail "$(basename "$f") $p: additionalProperties = $v"; }
  done
  assert_eq 'AC10.addprops' 'no additionalProperties on ANY of the three edited item subschemas' "$bad" "0"
fi

# ---- AC7's six parts, per schema FILE and per must_satisfy description -------
ac7_part() { # id file expr label pattern...
  local id="$1" file="$2" expr="$3" label="$4"; shift 4
  local t; t="$(jnode "$file" "$expr")"
  local miss=""
  for pat in "$@"; do
    case "$t" in *"$pat"*) ;; *) miss="$miss $pat";; esac
  done
  if [ -n "$t" ] && [ "$t" != '<undefined>' ] && [ -z "$miss" ]; then ok "$id" "$label"
  else no "$id" "$label"; detail "missing marker(s):${miss:- <the description itself>}"; fi
}

if want 'AC7.review.*'; then B=RED
  E='d.definitions.agentBlock.properties.concerns.items.properties.must_satisfy.description||""'
  ac7_part 'AC7.review.a' "$RS" "$E" '(a) three locations, compliance_flags named unreached' 'compliance_flags' 'vulnerabilities' 'peer-review'
  ac7_part 'AC7.review.b' "$RS" "$E" '(b) deployment-mode record: window, population, re-derivation, #66' '2026-08-21' '1638' 'subagent_type' '#66'
  ac7_part 'AC7.review.c' "$RS" "$E" '(c) fail-open degradations, naming the AGENT_RULES lookup miss' 'AGENT_RULES'
  ac7_part 'AC7.review.d' "$RS" "$E" '(d) empty-string residual with 17 of 229 and its split' '17' '229'
  ac7_part 'AC7.review.e' "$RS" "$E" '(e) archive residual as the both-versions invariant + the check' 'ABSOLUTE_VALUE' 'LEADING_SPAN' 'knowledge-store.mjs'
  ac7_part 'AC7.review.f' "$RS" "$E" '(f) the neighbour limit' 'warrant'
fi
if want 'AC7.peer.*'; then B=RED
  E='d.definitions.panelVerdict.properties.concerns.items.properties.must_satisfy.description||""'
  ac7_part 'AC7.peer.a' "$PS" "$E" '(a) three locations, compliance_flags named unreached' 'compliance_flags' 'vulnerabilities' 'peer-review'
  ac7_part 'AC7.peer.b' "$PS" "$E" '(b) deployment-mode record: window, population, re-derivation, #66' '2026-08-21' '1638' 'subagent_type' '#66'
  ac7_part 'AC7.peer.c' "$PS" "$E" '(c) fail-open degradations, naming the AGENT_RULES lookup miss' 'AGENT_RULES'
  ac7_part 'AC7.peer.d' "$PS" "$E" '(d) empty-string residual with 17 of 229 and its split' '17' '229'
  ac7_part 'AC7.peer.e' "$PS" "$E" '(e) archive residual as the both-versions invariant + the check' 'ABSOLUTE_VALUE' 'LEADING_SPAN' 'knowledge-store.mjs'
  ac7_part 'AC7.peer.f' "$PS" "$E" '(f) neighbour limit names the severity enum AND final_verdict' 'final_verdict' 'severity'
fi
if want 'AC7.secops.desc'; then B=RED
  t="$(jnode "$RS" 'd.properties.secops.description||""')"
  if [ ${#t} -ge 80 ] && case "$t" in *compliance_flags*) true;; *) false;; esac; then
    ok 'AC7.secops.desc' 'the secops-level description carries the three-location enumeration'
  else no 'AC7.secops.desc' 'the secops-level description carries the three-location enumeration'; detail "len ${#t}: ${t:-<absent>}"; fi
fi

# ---- AC7's mechanical prohibition -------------------------------------------
# The single sentence this criterion exists to stop: a false enforcement
# warranty scoped by REPOSITORY IDENTITY. Patterns are CLASSES, not the two
# examples: an enumeration proves nothing about a class it does not contain.
PROHIB='proven in adopting|never (been )?observed in this repos|besidecare|(refus|block|enforc|observ|prov)[a-z]*[^.]{0,80}in this repositor'
if want 'AC7.noRepoScope'; then B=RED
  bad=0; empties=0
  while IFS= read -r f; do
    t="$(extract_block "$f")"
    if [ -z "$t" ]; then empties=$((empties+1)); continue; fi
    h="$(printf '%s' "$t" | grep -inE "$PROHIB")"
    if [ -n "$h" ]; then bad=$((bad+1)); detail "${f#$SRC/}: $h"; fi
  done < <(ten_files)
  for f in "$RS" "$PS"; do
    h="$(grep -inE "$PROHIB" "$f")"
    if [ -n "$h" ]; then bad=$((bad+1)); detail "$(basename "$f"): $(printf '%s' "$h" | head -c 200)"; fi
  done
  # AN ABSENCE ASSERTED OVER AN EMPTY TEXT IS VACUOUS. The cell refuses to pass
  # while any of the ten extractions is empty.
  if [ "$empties" -gt 0 ]; then no 'AC7.noRepoScope' 'no repository-identity scoping in the shipped text'
    detail "$empties of 10 blocks are EMPTY: the absence check would be vacuous"
  else assert_eq 'AC7.noRepoScope' 'no repository-identity scoping in the shipped text' "$bad" "0"; fi
fi
if want 'AC7.deployScope'; then B=RED
  # The positive twin, so AC7.noRepoScope is not a pure absence: the text must
  # actually scope by DEPLOYMENT MODE, which is what a reader needs to decide
  # whether the gate protects them.
  bad=0
  while IFS= read -r f; do
    t="$(extract_block "$f")"
    miss=""
    case "$t" in *[Bb][Aa][Rr][Ee]*) ;; *) miss="$miss bare-names";; esac
    case "$t" in *namespaced*|*NAMESPACED*) ;; *) miss="$miss namespaced";; esac
    case "$t" in *'INSTALLED PLUGIN'*|*'installed plugin'*) ;; *) miss="$miss installed-plugin";; esac
    if [ -n "$miss" ]; then bad=$((bad+1)); detail "${f#$SRC/} lacks:$miss"; fi
  done < <(ten_files)
  assert_eq 'AC7.deployScope' 'the refusal is scoped by DEPLOYMENT MODE in all ten copies' "$bad" "0"
fi
if want 'AC7.diffLines'; then B=RED
  # The same prohibition over the diff's ADDED lines, which cannot false-red on
  # prose that was already in the tree (commands/pipeline.md carries two
  # pre-existing, unrelated "in this repository" sentences at the merge base).
  if [ "$SRC" != "$REPO" ]; then skip 'AC7.diffLines' 'needs the real worktree (--src override in effect)'
  else
    add="$(git -C "$REPO" diff origin/main...HEAD -- plugins/pipeline 2>/dev/null | grep '^+' | grep -v '^+++')"
    n="$(printf '%s' "$add" | grep -c . | tr -d ' ')"
    h="$(printf '%s' "$add" | grep -inE 'proven in adopting|never (been )?observed in this repos|besidecare' || true)"
    if [ "${n:-0}" -eq 0 ]; then
      no 'AC7.diffLines' 'no added line scopes the refusal by repository identity'
      detail "the diff adds 0 lines under plugins/pipeline: an absence check over an empty diff is vacuous"
    elif [ -z "$h" ]; then ok 'AC7.diffLines' "no repository-identity scoping in the ${n} added lines"
    else no 'AC7.diffLines' 'no added line scopes the refusal by repository identity'; printf '%s\n' "$h" | while IFS= read -r l; do detail "$l"; done; fi
  fi
fi

# =============================================================================
banner 'AC9 / AC11 -- the SecOps contract, at edit scope, and the untouched licences'
# =============================================================================
SEC="$PP/agents/secops.md"
if want 'AC9.middleware'; then B=RED
  assert_hasnt 'AC9.middleware' 'the :169 mechanism string is gone' "$SEC" 'Wrap with the global rate-limit middleware (10 req/min).'
fi
if want 'AC9.line29'; then B=RED
  assert_hasnt 'AC9.line29' 'the :29 "be specific about the remediation" line is gone' "$SEC" 'be specific about the remediation'
fi
if want 'AC9.veto'; then B=RED
  assert_hasnt 'AC9.veto' 'the VETO template no longer asks for "Remediation: <specific action>"' "$SEC" 'Remediation: <specific action>.'
  if grep -qiE 'must satisfy' "$SEC"; then ok 'AC9.veto.property' 'the VETO template asks what a correct fix must SATISFY'
  else no 'AC9.veto.property' 'the VETO template asks what a correct fix must SATISFY'; fi
fi
if want 'AC9.identifier'; then B=RED
  # R2(c) inside the SecOps contract specifically: at least one shipped example
  # exhibits an externally-fixed IDENTIFIER, not only an externally-fixed number.
  # The pre-existing PKCE/X-Frame-Options INSPECTION PROMPTS are not examples of
  # an ask, so the marker is the webhook-scheme example the design places at :29.
  if grep -qF 'HMAC-SHA256' "$SEC"; then ok 'AC9.identifier' 'an externally-fixed IDENTIFIER example ships in the SecOps contract'
  else no 'AC9.identifier' 'an externally-fixed IDENTIFIER example ships in the SecOps contract'; detail "no HMAC-SHA256 example in secops.md"; fi
fi
if want 'AC9.editscope'; then B=GREEN
  # ASSERTION SCOPE EQUALS EDIT SCOPE. The inspection prompts are checked by
  # TEXT, re-pinned from the merge base, because every line number in secops.md
  # shifts once the block is inserted.
  bad=0
  for ln in 52 55 65 73 84 85; do
    t="$(sed -n "${ln}p" "$TMPROOT/secops.base")"
    if [ -z "$t" ]; then bad=$((bad+1)); detail "base :$ln unreadable"; continue; fi
    grep -qF -- "$t" "$SEC" || { bad=$((bad+1)); detail "inspection prompt from base :$ln is GONE: $(printf '%s' "$t" | head -c 90)"; }
  done
  assert_eq 'AC9.editscope' 'the six inspection prompts survive verbatim (not bound by R1)' "$bad" "0"
fi
if want 'AC11.stdtier'; then B=GREEN
  # R8(b)/AC11: the standard-tier constraints block is the ONLY security review a
  # standard-tier change gets. Expected hunk count there is ZERO -- demonstrated
  # by diffing the injected block, not asserted.
  awk '/^## Standard-tier constraints/{f=1;next} f&&/^## /{exit} f{print}' "$TMPROOT/secops.base" > "$TMPROOT/std.base" 2>/dev/null
  awk '/^## Standard-tier constraints/{f=1;next} f&&/^## /{exit} f{print}' "$SEC" > "$TMPROOT/std.now" 2>/dev/null
  if [ ! -s "$TMPROOT/std.base" ]; then skip 'AC11.stdtier' 'could not extract the standard-tier block at the merge base'
  elif diff -q "$TMPROOT/std.base" "$TMPROOT/std.now" >/dev/null 2>&1; then
    ok 'AC11.stdtier' "the injected standard-tier block is byte-unchanged ($(wc -l < "$TMPROOT/std.base" | tr -d ' ') lines)"
  else no 'AC11.stdtier' 'the injected standard-tier block is byte-unchanged'
    diff "$TMPROOT/std.base" "$TMPROOT/std.now" | head -20 | while IFS= read -r l; do detail "$l"; done; fi
fi
if want 'AC11.additive'; then B=RED
  # R8(a) covers Dev's mechanism-choosing licence as well as QA's, and Dev's has
  # no quotable line the way qa.md:181/:184 do. Asserted structurally instead:
  # the five agent files this change only ADDS to must show ZERO deleted lines.
  # A narrowing edit anywhere in them is a deletion, wherever it sits, so this
  # is stronger than any line-quoting cell and it cannot go stale on a rebase.
  # It is guarded against vacuity: a file with no additions has not been touched
  # and its zero deletions prove nothing.
  if [ "$SRC" != "$REPO" ]; then skip 'AC11.additive' 'needs the real worktree (--src override in effect)'
  else
    bad=0
    for f in ba dev qa librarian art-director; do
      ns="$(git -C "$REPO" diff --numstat origin/main...HEAD -- "plugins/pipeline/agents/$f.md" 2>/dev/null)"
      add="$(printf '%s' "$ns" | awk '{print $1}')"; del="$(printf '%s' "$ns" | awk '{print $2}')"
      if [ -z "$ns" ]; then bad=$((bad+1)); detail "$f.md is untouched: 0 deletions is vacuous here"
      elif [ "$del" != "0" ]; then bad=$((bad+1)); detail "$f.md deletes $del line(s); this change may only ADD to it"
      fi
    done
    assert_eq 'AC11.additive' 'ba/dev/qa/librarian/art-director gain lines and delete none' "$bad" "0"
  fi
fi
if want 'AC11.qa'; then B=GREEN
  bad=0
  for ln in 181 184; do
    t="$(sed -n "${ln}p" "$TMPROOT/qa.base")"
    if [ -z "$t" ]; then bad=$((bad+1)); detail "base qa.md:$ln unreadable"; continue; fi
    grep -qF -- "$t" "$PP/agents/qa.md" || { bad=$((bad+1)); detail "qa.md base :$ln narrowed or gone: $(printf '%s' "$t" | head -c 90)"; }
  done
  assert_eq 'AC11.qa' "QA's and Dev's mechanism licence (qa.md :181/:184) is not narrowed" "$bad" "0"
fi

# =============================================================================
banner 'AC12 / AC14 -- the surface_probe, raw reading and byte-identity'
# =============================================================================
probe_def() { # file n
  awk -v want="$2" '/^surface_probe\(\) \{/{n++; if(n==want) f=1}
                    f{print}
                    f&&/^\}$/{exit}' "$1"
}
if want 'AC14.count'; then B=GREEN
  n="$(grep -c '^surface_probe() {' "$CMD" | tr -d ' ')"
  assert_eq 'AC14.count' 'commands/pipeline.md carries exactly two probe definitions' "$n" "2"
fi
if want 'AC14.identical'; then B=GREEN
  probe_def "$CMD" 1 > "$TMPROOT/p1"; probe_def "$CMD" 2 > "$TMPROOT/p2"
  if [ ! -s "$TMPROOT/p1" ]; then no 'AC14.identical' 'the two definitions are byte-identical'; detail "definition 1 extracted EMPTY"
  elif diff -q "$TMPROOT/p1" "$TMPROOT/p2" >/dev/null 2>&1; then ok 'AC14.identical' 'the two definitions are byte-identical'
  else no 'AC14.identical' 'the two definitions are byte-identical'
    diff "$TMPROOT/p1" "$TMPROOT/p2" | head -8 | while IFS= read -r l; do detail "$l"; done; fi
fi
if want 'AC9.brace'; then B=RED
  # The design's settled form. The four-cell probe matrix is NOT re-derived here:
  # it is first-hand from the orchestrator (shipped 20, $1-substituted 1, naive
  # backslash escape 1, brace form 20). What this cell asserts is that the SHIPPED
  # bytes are the brace form, in BOTH definitions.
  bad=0
  for n in 1 2; do
    probe_def "$CMD" "$n" > "$TMPROOT/pn"
    grep -qF -- '"${1}" "${2}"' "$TMPROOT/pn" || { bad=$((bad+1)); detail "definition $n does not end in the brace form"; }
  done
  assert_eq 'AC9.brace' 'both definitions pass the two arguments in brace form' "$bad" "0"
fi
if want 'AC12.nomatch'; then B=GREEN
  # RAW-FILE READING, extracted exactly as test-panel-composition-fail-direction.sh
  # does it, sourced, and CALLED. A no-match must exit 20, never 1: 1 is the
  # reserved INDETERMINATE code and reading it as "clean" is the fail direction.
  bad=0
  for n in 1 2; do
    probe_def "$CMD" "$n" > "$TMPROOT/pn.sh"
    rc=$( . "$TMPROOT/pn.sh"; printf 'plugins/pipeline/agents/qa.md\0plugins/pipeline/commands/pipeline.md\0' \
            | CLAUDE_PLUGIN_ROOT="$PP" surface_probe data-layer-surface.mjs diffTouchesDataLayer >/dev/null 2>&1; echo $? )
    [ "$rc" = "20" ] || { bad=$((bad+1)); detail "definition $n exited $rc on a real no-match (want 20)"; }
  done
  assert_eq 'AC12.nomatch' 'a genuine no-match exits 20 (not 1) from the raw reading' "$bad" "0"
fi
if want 'AC12.control'; then B=GREEN
  # NON-ZERO CONTROL for the cell above: the same call over a path list that DOES
  # touch the data layer must exit 0, so the 20 is a no-match and not a silent
  # failure of the probe itself.
  probe_def "$CMD" 1 > "$TMPROOT/pn.sh"
  rc=$( . "$TMPROOT/pn.sh"; printf 'db/migrations/003_add_index.sql\0' \
          | CLAUDE_PLUGIN_ROOT="$PP" surface_probe data-layer-surface.mjs diffTouchesDataLayer >/dev/null 2>&1; echo $? )
  assert_eq 'AC12.control' 'CONTROL: a data-layer path exits 0, so 20 above is a real no-match' "$rc" "0"
fi
if want 'AC14.suite'; then B=GREEN
  if [ "$SRC" != "$REPO" ]; then skip 'AC14.suite' 'needs the real worktree (--src override in effect)'
  else
    ( cd "$REPO" && bash plugins/pipeline/tests/test-panel-composition-fail-direction.sh ) > "$TMPROOT/pcfd.txt" 2>&1
    rc=$?
    m="$(git -C "$REPO" diff --name-only origin/main...HEAD -- plugins/pipeline/tests/test-panel-composition-fail-direction.sh 2>/dev/null)"
    if [ $rc -eq 0 ] && [ -z "$m" ]; then ok 'AC14.suite' 'test-panel-composition-fail-direction.sh passes UNMODIFIED'
    else no 'AC14.suite' 'test-panel-composition-fail-direction.sh passes UNMODIFIED'
      detail "exit $rc; modified-in-diff: ${m:-no}"; tail -8 "$TMPROOT/pcfd.txt" | while IFS= read -r l; do detail "  $l"; done; fi
  fi
fi

# =============================================================================
banner 'AC15 / AC16 -- the deferrals and the no-new-issue set comparison'
# =============================================================================
# BASELINE, recorded so the comparison is written rather than remembered. The
# first SIXTEEN numbers are spec.json's measured_state at ba_approved_at
# (3 19 21 25 38 40 44 52 53 54 56 58 59 61 63 66); the two after them were
# opened later by other hands and are annotated one by one below. Count them
# before trusting the sentence: the list is EIGHTEEN long, and a comment that
# says sixteen while the list says otherwise is the first thing to go stale.
BASELINE='3 19 21 25 38 40 44 52 53 54 56 58 59 61 63 66 71 74'
# #71 IS IN THE BASELINE AND WAS NOT OPEN AT ba_approved_at. Recorded, not
# silently added: the ORCHESTRATOR opened it at 2026-08-21T23:57:13Z, between
# the Phase 4 panel returning and the fix round starting, as the panel's
# disposition of GAP.52 and the empty-string residual (SecOps asked for exactly
# that, "FILE IT", and the fix round was told not to re-file). AC16's binding
# half is that the IMPLEMENTATION opens no issue, and it still binds: any
# further number appearing here is Dev's and fails the cell.
#
# #74 IS IN THE BASELINE ON THE SAME TERMS, added in the round-4 nit pass and
# recorded rather than absorbed. THE OWNER opened it at 2026-08-22T05:31:34Z
# (`gh issue view 74 --json author,createdAt`: nsmedia-io), 22 minutes before
# this pass ran the battery, and its body opens "Deferred out of #63 (Phase 2
# review: DBA, SecOps, DevOps)" - it is #63's lane disposing of its own
# deferral, cites #63 and not #40, and was filed BEFORE this pass started.
# THE EVIDENCE THAT IT IS NOT THIS IMPLEMENTATION'S, run rather than asserted:
# `git diff origin/main...HEAD | grep 'gh issue create'` returns nothing on this
# branch, and this change is docs-only with no executable surface at all.
# READ THE PATTERN, NOT JUST THE ENTRY: this is the second number added to a
# baseline frozen at ba_approved_at, so the frozen set has now been wrong twice
# in one issue's lifetime, both times because a CONCURRENT lane moved the
# tracker. The set comparison still binds - a number this implementation opened
# would not be in this list, and each entry above carries the evidence for its
# own presence - but a third addition should be read as the cell asking to be
# re-keyed on attribution (author and creation time) rather than on a frozen set.

# GROUP GUARD, and it is a guard on the GROUP, not a cell. It exists only to
# avoid shelling out to `gh` when no tracker cell was selected. It must not be
# written as `want 'AC15.*'`: that glob-matches the LITERAL string "AC15.*"
# against $ONLY, so `--only AC15.59.replaced` silently skipped the whole group
# and the cell never ran -- which made its own control report CONTROL-BROKEN
# for a reason that had nothing to do with the cell. Test the SELECTOR instead.
GHGROUP=0
case "$ONLY" in AC15*|AC16*|'*') GHGROUP=1;; esac
if [ "$GHGROUP" = 1 ]; then
  if ! command -v gh >/dev/null 2>&1; then
    B=GREEN; skip 'AC15/AC16' 'gh is not on PATH: the tracker cells cannot run (a skip is not a pass)'
  else
    # COMMENTS ONLY, and rc-aware. `gh issue view N --comments` prints the BODY
    # too, so a marker already in the issue body would pass a cell that is
    # supposed to observe a COMMENT posted before merge; and it prints NOTHING
    # for an issue with zero comments, which an emptiness test misreads as "gh
    # could not read it" -- i.e. a real FAIL reported as a SKIP. #52 is exactly
    # that case at the merge base: zero comments, and CLOSED.
    gh_comments() { gh issue view "$1" --json comments -q '.comments[].body' 2>/dev/null; }
    gh_state()    { gh issue view "$1" --json state    -q '.state'            2>/dev/null; }

    if want 'AC15.38'; then B=RED
      st="$(gh_state 38)"
      c="$(gh_comments 38)"
      if [ -z "$st" ]; then skip 'AC15.38' 'gh could not reach issue 38 (auth? network?)'
      else
        detail "issue 38 is $st with $(printf '%s' "$c" | grep -c . ) comment line(s)"
        miss=""
        case "$c" in *'#66'*) ;; *) miss="$miss cross-ref-#66";; esac
        case "$c" in *'panel major severity accepted'*) ;; *) miss="$miss the-three-case-names";; esac
        case "$c" in *validate-pipeline-artifact*) ;; *) miss="$miss the-file-they-live-in";; esac
        if [ -z "$miss" ]; then ok 'AC15.38' '#38 carries the three case names, their file, and the #66 cross-ref'
        else no 'AC15.38' '#38 carries the three case names, their file, and the #66 cross-ref'; detail "lacks:$miss"; fi
      fi
    fi
    # ---------------------------------------------------------------------
    # AC15.52 IS RETIRED. QA ruling, 2026-08-21, recorded here so the next
    # reader sees the reasoning and not just a missing cell.
    #
    # R10(c) wanted #52 to carry the enumeration of every free-text field this
    # change adds to the committed-and-archived-verbatim surface, "so its
    # eventual fix is built against the current field set rather than a stale
    # enumeration". #52 has since CLOSED and its own subject is discharged.
    # There is no eventual fix for the enumeration to inform, and a comment on
    # a closed issue is not the durable record the criterion was buying. The
    # criterion's PURPOSE, not its letter, is what survives: the exposure must
    # be written where the person exposed to it will read it. That is the
    # field's own description, which every reviewer opens and nobody has to
    # remember to check -- so the assertion MOVES there (AC15.52.replaced).
    #
    # WHAT THE RULING DOES NOT DO is claim the class is closed. See the GAP
    # note in the MANUAL block: `description`, `notes` and `location` cross the
    # same boundary with no mitigation at all, and with #52 closed that class
    # now has NO tracker home. That is the orchestrator's to re-file; AC16
    # forbids this implementation opening one.
    if want 'AC15.52.replaced'; then B=RED
      # REWRITTEN 2026-08-22 after QA measured this cell BLIND on one of the
      # three fields it claims to cover (round 3, Q1). The old legs grepped the
      # WHOLE description for `verbatim` and for a credential word. In
      # review/remediation both needles occur OUTSIDE the exposure note -
      # `verbatim` inside the redactor caveat that says the opposite of what the
      # leg tests, `credential` inside the rate-limit EXAMPLE - so the entire
      # warning could be deleted from SecOps's own field and this cell stayed
      # GREEN. Both legs were carried by text that is not an exposure note.
      #
      # The fix is to stop grepping the field and extract the NOTE: the note is
      # the sentence that speaks about PASTING, and nothing else in any of the
      # three descriptions does (verified per field at HEAD: exactly one
      # sentence each). Every substantive leg then runs against that region, so
      # a needle satisfied by neighbouring prose cannot carry it. The legs are
      # about the note's SUBSTANCE and not its wording, so a reworded note
      # still passes - that survivor is planted as a control (credreword) and
      # is EXPECTED to survive.
      #
      # REWRITTEN AGAIN 2026-08-22 (QA-N1, round 4). The version above could be
      # INVERTED into a false assurance while staying GREEN: QA's CM7 kept leg
      # 3's framing phrase ("a rule you honor", "not a control") and reversed
      # what followed it, and the cell passed while printing a detail line
      # asserting the opposite of the text it had just approved. Leg 3 now
      # demands the negated-protection clause itself (negated_protection), and
      # the overclaim check is a CLASS scan for an affirmative protection claim
      # over credential material (overclaim_hits) rather than a four-phrase
      # blocklist. CM7 is planted as a permanent control beside CM8; both must
      # redden this cell.
      bad=0
      for spec in \
        "$RS|d.definitions.agentBlock.properties.concerns.items.properties.must_satisfy.description||\"\"" \
        "$PS|d.definitions.panelVerdict.properties.concerns.items.properties.must_satisfy.description||\"\"" \
        "$RS|d.properties.secops.allOf[1].properties.vulnerabilities.items.properties.remediation.description||\"\""; do
        f="${spec%%|*}"; p="${spec#*|}"
        t="$(jnode "$f" "$p")"
        note="$(exposure_note "$f" "$p")"
        n="$(basename "$f")/$(printf '%s' "$p" | sed 's/.*properties\.\([a-z_]*\)\.description.*/\1/')"
        if [ -z "$note" ]; then
          # QA-N3: say what was MEASURED, which is that the locator found no
          # candidate - not that the note is absent. QA's CM6b removed both
          # paste-words while keeping the warning whole, and the old message
          # would have sent the next editor to rewrite a note that was there.
          bad=$((bad+1))
          detail "$n: the exposure-note LOCATOR found no candidate sentence (exposure_note() selects sentences containing \"paste\")"
          detail "$n: a note may still be present and reworded around that word -- read the field before rewriting it"
        else
          # ONE SENTENCE must carry all three legs. Satisfying them across
          # different sentences is the very hole being closed here.
          whole=0
          while IFS= read -r sent; do
            [ -n "$sent" ] || continue
            legs=0
            case "$sent" in *"credential"*|*"secret"*|*"token"*) legs=$((legs+1));; esac
            case "$sent" in *"verbatim"*|*"public"*|*"archiv"*|*"committed"*) legs=$((legs+1));; esac
            negated_protection "$sent" && legs=$((legs+1))
            [ "$legs" = 3 ] && whole=1
          done <<NOTE_EOF
$note
NOTE_EOF
          if [ "$whole" = 0 ]; then
            bad=$((bad+1))
            detail "$n: no SINGLE sentence carries the whole note (credential class + durable copy + a NAMED protection this path does not perform)"
          fi
        fi
        # NON-OVERCLAIM, asserted over the WHOLE field: an overclaim anywhere in
        # the description misleads, whether or not it lands inside the note.
        # TWO READINGS, and they answer different mutations. The class scan
        # catches a claim that something here removes/strips/redacts/filters
        # credential material, in any spelling (CM7). The phrase list catches
        # assurance wording that names no verb at all (CM8's "safe to paste").
        while IFS= read -r hit; do
          [ -n "$hit" ] || continue
          bad=$((bad+1)); detail "$n: OVERCLAIM -- this field asserts a protection over credential material that no code on this path performs [$hit]"
          # THE EXPIRY, WRITTEN INTO THE FAILURE. This leg is anchored to a live
          # absence: knowledge-store.mjs redacts by path shape and nothing else.
          # The correct outcome for that absence is that somebody closes it, and
          # on that day a TRUE sentence reddens here. If that is why you are
          # reading this, the cell is what is stale - re-anchor it on what the
          # new redactor actually does, and do not delete the note to pass.
          detail "$n:   if a credential redactor HAS since shipped on this path, this leg is the stale party -- re-anchor it, do not delete the note"
        done <<HIT_EOF
$(overclaim_hits "$f" "$p")
HIT_EOF
        case "$t" in
          *"redacted for you"*|*"safe to paste"*|*"is redacted before"*|*"automatically redacted"*)
            bad=$((bad+1)); detail "$n: OVERCLAIM -- the note implies the exposure is handled; no such control exists";;
        esac
      done
      if [ "$bad" = 0 ]; then
        ok 'AC15.52.replaced' 'the archived-verbatim exposure is written on all three new/changed fields, and does not overclaim'
        detail 'WHAT THIS CELL MEASURED: each note names a protection this path does not perform, and no field'
        detail 'asserts one it does. The absence itself (no minLength, no pattern, no credential redaction on the'
        detail 'archive path) is a fact about knowledge-store.mjs, read there and not inferred from this text.'
      else
        no 'AC15.52.replaced' 'the archived-verbatim exposure is written on all three new/changed fields, and does not overclaim'
      fi
    fi
    # ---------------------------------------------------------------------
    # AC15.59 IS RETIRED. QA ruling, 2026-08-21.
    #
    # The criterion required a comment on #59 "naming commit b279ffa", so that
    # whichever redactor version merged second, the comment stayed true. The
    # world resolved the condition instead: #59 CLOSED, LEADING_SPAN is live at
    # knowledge-store.mjs:147, ABSOLUTE_VALUE is gone, and the merged commit is
    # e7c1bd2. VERIFIED BY QA FIRST-HAND, through the real consumer path
    # (archiveIssue, not a restatement of the regex), with a non-zero control:
    #   A "/v1/public-feed must be unreachable without a server-validated
    #     bearer token, measured by ..."
    #     -> "<redacted-absolute-path> must be unreachable without a
    #         server-validated bearer token, measured by ..."   claim SURVIVES
    #   B "/v1/public-feed"  (CONTROL: the value IS a bare path)
    #     -> "<redacted-absolute-path>"                          fully replaced
    #   module-counted redactions: 2, so the redactor demonstrably ran on both.
    # Without B, A's survival would be indistinguishable from a redactor that
    # never fired.
    #
    # AND THE CRITERION'S LETTER IS NOW HARMFUL: `git merge-base --is-ancestor
    # b279ffa origin/main` exits 1. b279ffa is NOT an ancestor of origin/main,
    # so a comment naming it would ship an unresolvable reference -- the very
    # staleness the criterion existed to prevent, caused by obeying it.
    #
    # WHAT REPLACES IT is the generalised form of the harm: no shipped text may
    # name a commit that a reader cannot resolve. That covers b279ffa and every
    # future dangling SHA, and unlike the comment assertion it cannot expire.
    if want 'AC15.59.replaced'; then B=GREEN
      if [ "$SRC" != "$REPO" ]; then skip 'AC15.59.replaced' 'needs the real worktree (--src override in effect)'
      else
        add="$(git -C "$REPO" diff origin/main...HEAD -- plugins/pipeline 2>/dev/null | grep '^+' | grep -v '^+++')"
        # TEST SEAM, used only by --controls: a check that has only ever seen a
        # clean input is a zero result about itself. VERIFY40_EXTRA_SHA appends
        # one candidate so the ancestor logic can be watched firing on a real
        # non-ancestor commit. It is named, it is empty in every normal run, and
        # it can only ADD a candidate -- it can never suppress a real finding.
        shas="$(printf '%s\n%s' "$add" "${VERIFY40_EXTRA_SHA:-}" | grep -oE '\b[0-9a-f]{7,40}\b' | sort -u)"
        bad=0; checked=0
        for h in $shas; do
          # A hex run of 7+ chars is a SHA candidate, not a SHA. Only the ones
          # git actually knows as commits are claims a reader can be misled by;
          # the rest are hashes, ids and coincidences (da39a3ee..., 353,907).
          if git -C "$REPO" cat-file -e "${h}^{commit}" 2>/dev/null; then
            checked=$((checked+1))
            if git -C "$REPO" merge-base --is-ancestor "$h" origin/main 2>/dev/null; then
              detail "resolvable: $h is an ancestor of origin/main"
            else
              bad=$((bad+1)); detail "DANGLING: $h is a commit but NOT an ancestor of origin/main"
            fi
          fi
        done
        detail "$checked commit-shaped token(s) in the added lines were resolved against origin/main"
        assert_eq 'AC15.59.replaced' 'no added line names a commit a reader cannot resolve on origin/main' "$bad" "0"
      fi
    fi
    if want 'AC16.nonew'; then B=GREEN
      open="$(gh issue list --state open --limit 200 --json number -q '.[].number' 2>/dev/null | sort -n)"
      if [ -z "$open" ]; then skip 'AC16.nonew' 'gh could not list open issues'
      else
        newones=""
        for n in $open; do
          case " $BASELINE " in *" $n "*) ;; *) newones="$newones $n";; esac
        done
        closed=""
        for n in $BASELINE; do
          case " $(echo $open) " in *" $n "*) ;; *) closed="$closed $n";; esac
        done
        # The BINDING half is "opens no new issue". A baseline issue closing is a
        # different event (another lane merging) and is reported, not failed.
        detail "closed since the baseline (NOT a violation, reported for the set comparison):${closed:- none}"
        if [ -z "$newones" ]; then ok 'AC16.nonew' 'the implementation opened NO new tracker issue'
        else
          no 'AC16.nonew' 'the implementation opened NO new tracker issue'
          detail "open but not in the baseline:$newones"
          # ATTRIBUTION, so the red is actionable rather than merely red: an
          # issue opened by a CONCURRENT LANE before Phase 3a even started is
          # not this implementation opening an issue. AC16 compares against a
          # baseline frozen at ba_approved_at, which a multi-lane tree falsifies
          # on its own. Print the evidence; do not soften the assertion.
          for n in $newones; do
            detail "  #$n $(gh issue view "$n" --json createdAt,author,title -q '.createdAt+"  "+.author.login+"  "+.title' 2>/dev/null | cut -c1-110)"
          done
          detail "  If every row above predates this Phase 3, AC16's baseline is stale, not violated."
        fi
      fi
    fi
  fi
fi

# =============================================================================
banner 'AC5.suite -- the whole shipped suite (SLOW: several minutes, run last)'
# =============================================================================
if want 'AC5.suite'; then B=GREEN
  if [ "$SRC" != "$REPO" ]; then skip 'AC5.suite' 'suite cell needs the real worktree (--src override in effect)'
  else
    printf '                     | running plugins/pipeline/tests/run.sh ...\n'
    ( cd "$REPO" && bash plugins/pipeline/tests/run.sh ) > "$TMPROOT/suite.txt" 2>&1
    rc=$?
    if [ $rc -eq 0 ]; then ok 'AC5.suite' 'NON-REGRESSION (not coverage): tests/run.sh exits 0'
    else no 'AC5.suite' 'NON-REGRESSION: tests/run.sh exits 0'; detail "exit $rc; tail:"; tail -12 "$TMPROOT/suite.txt" | while IFS= read -r l; do detail "  $l"; done; fi
  fi
fi

# =============================================================================
banner 'SUMMARY'
# =============================================================================
printf 'cells: %d passed, %d failed, %d skipped\n' "$PASS_N" "$FAIL_N" "$SKIP_N"
if [ -n "$FAILED" ]; then printf 'failing:%s\n' "$FAILED"; fi
if [ "$SURPRISE_N" -gt 0 ]; then
  printf '\n!! %d cell(s) declared [base:GREEN] and FAILED. Those are NOT explained by\n' "$SURPRISE_N"
  printf '!! a missing implementation. Read them first: broken harness, stale rebase,\n'
  printf '!! rotted fixture, or a real regression.\n'
fi
cat <<'MANUAL_BLOCK'

MANUAL -- NOT DISCHARGED BY THIS BATTERY, AT ANY EXIT CODE:
  AC3.manual  Two readers, handed the shipped passage and these six asks, must
              classify all six identically. No script can run this cell.
              CASE 3 MOVED, 2026-08-22: it read `-> IN` for three rounds and QA,
              the second reader, classified it OUT. QA is right and the text was
              wrong -- "the applicable card-data standard" NAMES no document, so
              there is nothing to open, and that is decidable from the ask's form
              with no standard in hand. The shipped passage now sorts it OUT and
              case 6 is the IN case that replaces it. AC3.pairsort pins that
              sorting mechanically in all eleven locations.
                1 "the rate limit must be low enough that credential stuffing is
                   not economical, measured by <observation>"          -> IN
                2 "the token lifetime must be short enough that a leaked token
                   expires before a human can act on it, measured by ..." -> IN
                3 "the failed-login lockout threshold must be at most 6 attempts,
                   per the applicable card-data standard"              -> OUT
                4 "the webhook signature must be verified with the provider's
                   HMAC-SHA256 scheme"                                 -> IN
                5 "the retry budget must be at most 3", no source named -> OUT
                6 "the TOTP time step must be the 30 seconds RFC 6238
                   section 5.2 fixes as its default"                   -> IN
  GAP.52      A CLASS WITH NO TRACKER HOME, recorded here because retiring
              AC15.52 must not retire the thing it was protecting. #52 named a
              class -- free-text reviewer fields committed and archived
              VERBATIM -- and has CLOSED with only its own subject discharged.
              This change mitigates its OWN new fields with a sentence
              (AC15.52.replaced pins it). The PRE-EXISTING `description`,
              `notes` and `location` fields on review and peer-review shards
              cross the identical boundary with no mitigation at all, and with
              #52 closed that class is now tracked NOWHERE. Orchestrator's call
              to re-file: AC16 forbids this implementation opening an issue, so
              Dev cannot fix this and must not be asked to.
              AND THE MITIGATION IS A NORM, NOT A CONTROL: no minLength, no
              pattern, no redaction of credential material. A reviewer who
              pastes a token still validates clean and is still archived
              verbatim. Read the sentence as advice, never as a guard.
  AC13.manual The LOADED-TEXT reading of surface_probe. The substitution happens
              in the slash-command loader, not in a shell, so no repo-resident
              check can witness it. The orchestrator must re-load
              `/pipeline --issue 40` after the change and report the rendered
              definition line VERBATIM. Reporting that it was not observed is the
              correct outcome; claiming a pass without the rendering is not.
MANUAL_BLOCK

if [ "$FAIL_N" -eq 0 ] && [ "$SKIP_N" -eq 0 ]; then exit 0; fi
exit 1
