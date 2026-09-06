#!/usr/bin/env bash
# config-doctor's SURFACE half: the zero-match report, the unsupported-glob warnings, the new
# config keys, and the contract that none of it can ever block a session. Issue #17.
#
# Kept separate from test-config-doctor.sh on purpose: that file pins the shipped diagnosis
# and must keep passing unmodified, so a regression here names this change rather than
# surfacing as an edit to a suite that was already green.
#
# The class this exists to catch is a report that CANNOT FIRE. Every surface key's effective
# set is a union containing the built-in defaults, so a key-granularity zero-match check would
# be green in every repo where the defaults match anything -- reporting confidently about a
# configured pattern it never looked at. The report is therefore per PATTERN per CONSUMER, and
# every assertion below has a control in the other direction.
#
# Fixtures are built in `mktemp` scratch repos. Nothing is committed to THIS repo under a path
# the narrow set matches: `tests/fixtures/migrations/0001.sql` TRIPS the preset union, so the
# obvious fixture layout would make this repository halt on its own test data forever.

. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
require_node

make_temp_project || exit 90

DOCTOR="$SCRIPTS_DIR/config-doctor.mjs"
SURFACE="$SCRIPTS_DIR/data-layer-surface.mjs"
PLUGIN_DIR="$PLUGIN_ROOT"
REPO_ROOT="$(cd "$PLUGIN_DIR/../.." && pwd)"

# make_repo_with <name> <config-json|-> <path>... -> echoes the repo dir
make_repo_with() {
  local name="$1" cfg="$2"; shift 2
  local dir="$TEMP_PROJECT/$name" p
  mkdir -p "$dir"
  git -C "$dir" init -q 2>/dev/null
  for p in "$@"; do
    mkdir -p "$dir/$(dirname "$p")"
    printf 'fixture\n' > "$dir/$p"
  done
  [[ "$cfg" == "-" ]] || printf '%s' "$cfg" > "$dir/pipeline.config.json"
  git -C "$dir" add -A >/dev/null 2>&1
  git -C "$dir" -c user.email=t@t -c user.name=t commit -q -m fixture >/dev/null 2>&1
  printf '%s' "$dir"
}

doctor_out() { ( cd "$1" && CLAUDE_PROJECT_DIR="$1" node "$DOCTOR" 2>/dev/null ); }
doctor_rc() { ( cd "$1" && CLAUDE_PROJECT_DIR="$1" node "$DOCTOR" >/dev/null 2>&1 ); printf '%s' "$?"; }

# =============================================================================
# AC39 -- THE SHIPPED EXAMPLE CONFIG DOES NOT NARROW GATE DISCOVERY.
# =============================================================================
suite "AC39: a project configured verbatim from the shipped example still discovers every layout"

EXAMPLE="$PLUGIN_DIR/pipeline.config.example.json"

assert_eq "the shipped example declares no migrationGlobs key at all" \
  "$(node -e 'import("node:fs").then(fs=>{const c=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));console.log(Object.prototype.hasOwnProperty.call(c,"migrationGlobs")?"present":"absent")})' "$EXAMPLE")" \
  "absent"

# discovered <config-json> -> the count of the six preset paths migrationGlobsForGate matches.
# The gate's resolver is asked directly: this criterion is about DISCOVERY, and routing it
# through the whole gate would make a zero unreadable (a gate exits 0 both when it discovered
# nothing and when everything it discovered was fine).
SIX='["db/migrate/x.rb","alembic/versions/a.py","Data/Migrations/20240101_Init.cs","drizzle/0000_snapshot.sql","supabase/schemas/u.sql","src/main/resources/db/migration/V1__init.sql"]'
discovered() {
  node -e '
    import(process.argv[1]).then(m=>{
      const cfg = JSON.parse(process.argv[2]);
      const globs = m.migrationGlobsForGate(cfg);
      const paths = JSON.parse(process.argv[3]);
      console.log(paths.filter(p=>m.isMigrationPath(p, globs)).length);
    })' "$SURFACE" "$1" "$SIX"
}

EXAMPLE_CFG="$(node -e 'import("node:fs").then(fs=>console.log(JSON.stringify(JSON.parse(fs.readFileSync(process.argv[1],"utf8")))))' "$EXAMPLE")"
assert_eq "the example's own config discovers all six framework layouts" "$(discovered "$EXAMPLE_CFG")" "6"

# NON-ZERO CONTROL, and it is the defect being removed, observed rather than described: the
# value the example USED to ship pins gate discovery to one pattern while the preset union
# grew to fifteen rows. If this ever returns 6, replace semantics have been quietly dropped
# and the gate can no longer be narrowed at all -- which is a different bug, not a fix.
assert_eq "CONTROL: the value the example used to ship discovers NONE of the six" \
  "$(discovered '{"migrationGlobs":["**/migrations/**"]}')" "0"
assert_eq "CONTROL: and that same config still discovers what it does name" \
  "$(node -e 'import(process.argv[1]).then(m=>console.log(m.isMigrationPath("db/migrations/1.sql", m.migrationGlobsForGate({migrationGlobs:["**/migrations/**"]}))))' "$SURFACE")" \
  "true"

# =============================================================================
# AC10 / AC12 -- every new key is REGISTERED, and every DOCUMENTED key resolves.
# =============================================================================
suite "AC10: the new keys are read by something, with a reader, a fallback and a consequence"

R_ALLKEYS=$(make_repo_with allkeys '{"checkCommand":"npm test","migrationGlobs":["**/migrations/**"],"extraMigrationGlobs":["sql/tables.sql"],"dataLayerGlobs":["**/db/**"],"infraGlobs":["**/infra/**"],"dispatchModels":{"ba":"sonnet"}}' 'migrations/0001.sql' 'sql/tables.sql' 'db/x.sql' 'infra/main.tf')
OUT_ALLKEYS="$(doctor_out "$R_ALLKEYS")"
assert_not_contains "a config using every new key produces no 'read by nothing' line" "$OUT_ALLKEYS" "read by nothing"
assert_contains "and the config still reports healthy" "$OUT_ALLKEYS" "all keys recognized"

# The module path travels in the ENVIRONMENT, never as argv[1]: config-doctor.mjs decides
# whether it is the entrypoint by inspecting process.argv[1], so passing its own path there
# makes a `node -e` probe run the whole CLI and print the session banner instead of the field.
key_field() { # <key> <field>
  DOC="$DOCTOR" KEY="$1" FIELD="$2" node -e '
    import(process.env.DOC).then(m=>{
      const k = m.ALL_KEYS[process.env.KEY];
      if (!k) { console.log("ERR:unregistered"); return; }
      console.log(k[process.env.FIELD] ? "present" : "MISSING");
    })'
}
for k in extraMigrationGlobs dataLayerGlobs infraGlobs dispatchModels deferralTracker deferralDir; do
  assert_eq "$k has a reader"   "$(key_field "$k" reader)"   "present"
  assert_eq "$k has a fallback" "$(key_field "$k" fallback)" "present"
  assert_eq "$k has a degrades consequence" "$(key_field "$k" degrades)" "present"
done
assert_eq "CONTROL: an unregistered key is reported as such, so 'present' means something" \
  "$(key_field notAKey reader)" "ERR:unregistered"

DEGRADES="$(DOC="$DOCTOR" node -e 'import(process.env.DOC).then(m=>console.log(m.ALL_KEYS.migrationGlobs.degrades))')"
assert_contains "migrationGlobs' consequence names the GATE consumer" "$DEGRADES" "gate"
assert_contains "and the TRIPWIRE consumer" "$DEGRADES" "tripwire"
assert_contains "and says the tripwire UNIONS rather than narrows" "$DEGRADES" "UNIONS"
assert_contains "and names extraMigrationGlobs as the additive alternative" "$DEGRADES" "extraMigrationGlobs"

# The two deferral keys (0.41.0). `deferralTracker` decides where a deferred item is WRITTEN, and
# the pre-Phase-4 gate refuses a tracker_ref that does not resolve in the mode it names, so a
# project that never sets it records deferrals into a `gh` it may not have. Its `degrades` has to
# say that, and has to name the escape hatch, or an adopting project reads the key as cosmetic.
TRACKER_DEGRADES="$(DOC="$DOCTOR" node -e 'import(process.env.DOC).then(m=>console.log(m.ALL_KEYS.deferralTracker.degrades))')"
assert_contains "deferralTracker's consequence names the default it silently takes" "$TRACKER_DEGRADES" "gh issue create"
assert_contains "and names every legal value, so a typo is diagnosable from this line alone" \
  "$TRACKER_DEGRADES" '"directory"'
assert_contains "and names the gate that refuses a ref written the wrong way" "$TRACKER_DEGRADES" "gate"
DIR_DEGRADES="$(DOC="$DOCTOR" node -e 'import(process.env.DOC).then(m=>console.log(m.ALL_KEYS.deferralDir.degrades))')"
assert_contains "deferralDir's consequence says it is read in ONE mode only" "$DIR_DEGRADES" "directory"
assert_contains "and that an escaping value is refused rather than honoured" "$DIR_DEGRADES" "refused"

# The example must SET both, not merely mention them: an adopting project copies that file, and a
# key it does not carry is a key nobody discovers.
assert_eq "the shipped example sets deferralTracker" \
  "$(grep -c '"deferralTracker":' "$EXAMPLE" | tr -d ' ')" "1"
assert_eq "and deferralDir" "$(grep -c '"deferralDir":' "$EXAMPLE" | tr -d ' ')" "1"

suite "AC12: every config key the docs name in backticks resolves to a registered key"

# Mechanical, not by reading: the README table and commands/pipeline.md are parsed, and every
# backticked token that is a config key must exist in ALL_KEYS. The semantic half (whether the
# prose describes the key's PURPOSE accurately) is not mechanically checkable and is recorded
# as such in the spec rather than given a check that implies coverage it does not have.
DOC_KEYS=$(grep -oE '`[a-z][a-zA-Z]+`' "$PLUGIN_DIR/README.md" "$PLUGIN_DIR/commands/pipeline.md" 2>/dev/null | sed 's/.*`\(.*\)`/\1/' | sort -u)
REGISTERED=$(DOC="$DOCTOR" node -e 'import(process.env.DOC).then(m=>console.log(Object.keys(m.ALL_KEYS).join(" ")))')
UNRESOLVED=""
for k in $DOC_KEYS; do
  case " $REGISTERED " in *" $k "*) continue ;; esac
  # Only tokens that LOOK like config keys are in scope; the docs backtick plenty of other
  # things (function names, phases, verdicts). A key is in scope when the example config or
  # the README config table names it.
  grep -q "\"$k\":" "$EXAMPLE" 2>/dev/null || continue
  UNRESOLVED="$UNRESOLVED $k"
done
assert_eq "no documented config key is missing from the registry" "$UNRESOLVED" ""
assert_eq "CONTROL: the registry sweep is non-empty (it found real keys to check)" \
  "$([[ -n "$REGISTERED" ]] && echo yes || echo no)" "yes"

# The README states a COUNT for the preset union. A stated number is exactly the kind of
# hand-copied fact this whole issue is about, so it is derived from the code, not trusted.
assert_eq "the README's 'fifteen-row' claim equals the code's row count" \
  "$(node -e 'import(process.argv[1]).then(m=>console.log(m.DEFAULT_MIGRATION_GLOBS.length))' "$SURFACE")" "15"
# Presence, not an exact count: the phrase legitimately appears in both the config table and
# the Upgrading section, and pinning the count would redden on a documentation addition that
# says the same true thing twice.
assert_eq "and the README states that number in words" \
  "$([[ "$(grep -c 'fifteen-row framework-preset union' "$PLUGIN_DIR/README.md" | tr -d ' ')" -ge 1 ]] && echo stated || echo absent)" "stated"
assert_eq "CONTROL: the same grep reports absent for a number the README does not claim" \
  "$([[ "$(grep -c 'twenty-row framework-preset union' "$PLUGIN_DIR/README.md" | tr -d ' ')" -ge 1 ]] && echo stated || echo absent)" "absent"

suite "AC12(b): every VALUE the README's Default column states is a value the code produces"

# The second clause of AC12, which shipped as prose and never as a check. It found live drift
# the moment it was written: the README promised `checkCommand` defaults to
# "npm run typecheck && npm test && npm run lint", while the Stop hook falls back to
# `npm run typecheck` ONLY when package.json declares it and is otherwise a no-op. An owner
# reading that table believed their tests and lint ran on every turn end. Nothing did.
#
# The rule is exact and needs no exception list: every BACKTICKED LITERAL in a Default cell is
# a value claim, and it must appear verbatim in that key's registered `fallback` or `reader`.
# Unbackticked prose in the same cell ("a generic component/style set") is a description, not a
# claim about a value, and is not compared -- which is why the literal COUNT is asserted too:
# rewriting a claim into prose to dodge the check reddens the floor.
key_value() { # <key> <field> -> the registered string, or "" when absent
  DOC="$DOCTOR" KEY="$1" FIELD="$2" node -e '
    import(process.env.DOC).then(m=>{
      const k = m.ALL_KEYS[process.env.KEY];
      console.log(k && k[process.env.FIELD] ? String(k[process.env.FIELD]) : "");
    })'
}
cell_literals() { printf '%s' "$1" | grep -oE '`[^`]+`' | sed 's/^`//;s/`$//'; }

# CONTAINMENT ANYWHERE IN `reader|fallback` was the first spelling of this comparison, and it
# could not refuse two whole classes of false claim. SecOps rewrote the README's
# `migrationDownMarker` default from `-- DOWN` to `-- D` and the suite stayed 75/0, because a
# truncation is a substring of the thing it truncates. QA separately measured that four of the
# nine literals -- migrationGlobs, dataLayerGlobs, infraGlobs and dispatchModels -- matched only
# through `reader`, which HOLDS A FILE PATH, so any path-shaped claim satisfied them: setting the
# checkCommand cell to `hooks/stop.sh` passed at 75/0 too.
#
# Both holes are the same mistake, which is comparing a value claim against a field that is not a
# value. The comparison is now DELIMITED and the two kinds of literal are told apart.
delimited_in() {  # <haystack> <needle> -> 0 when the needle occurs on non-alphanumeric boundaries
  local hay="$1"
  local needle="$2"
  local rest="$hay"
  local pre
  local post
  local before
  local after
  [[ -n "$needle" ]] || return 1
  while [[ "$rest" == *"$needle"* ]]; do
    pre="${rest%%"$needle"*}"
    post="${rest#*"$needle"}"
    before="${pre: -1}"
    after="${post:0:1}"
    if [[ ! "$before" =~ [A-Za-z0-9] ]] && [[ ! "$after" =~ [A-Za-z0-9] ]]; then return 0; fi
    rest="$post"
  done
  return 1
}
is_module_path() {  # <literal> -> 0 when it is a path into the plugin rather than a value
  case "$1" in */*.mjs|*/*.sh|*/*.json) return 0 ;; *) return 1 ;; esac
}
cell_drift() { # <key> <default-cell> -> "" when every literal in the cell is a claim the code supports
  local key="$1"
  local cell="$2"
  local fallback
  local reader
  local lit
  local out=""
  fallback="$(key_value "$key" fallback)"
  reader="$(key_value "$key" reader)"
  if [[ -z "$fallback" && -z "$reader" ]]; then printf '%s' "$key(unregistered)"; return 0; fi
  while IFS= read -r lit; do
    [[ -n "$lit" ]] || continue
    if is_module_path "$lit"; then
      # A POINTER ("the default is defined over there"), never a value, and never matched against
      # `reader` as a substring. A pointer earns its place only when the cell SAYS it is one, the
      # code really calls that key's default a built-in, the file is really there, and the key is
      # really read from it. `hooks/stop.sh` in the checkCommand cell fails the second of those,
      # in both the bare and the "the default in ..." spelling.
      if ! delimited_in "$cell" "in \`$lit\`"; then
        out="$out|$key: README states [$lit] as its default value, but that is a module path"
      elif ! delimited_in "$fallback" "built-in"; then
        out="$out|$key: README points at [$lit] for its default, but the code says [$fallback], which is not a built-in"
      elif [[ ! -f "$PLUGIN_DIR/$lit" ]]; then
        out="$out|$key: README points at [$lit], which is not a file in the plugin"
      elif ! delimited_in "$reader" "$lit"; then
        out="$out|$key: README points at [$lit], but the key is read by [$reader]"
      fi
    elif ! delimited_in "$fallback" "$lit"; then
      # A VALUE claim, compared against `fallback` ALONE. `reader` is prose naming files and
      # consumers; comparing a value against it is what let a path stand in for a command.
      out="$out|$key: README states [$lit], code says [$fallback]"
    fi
  done < <(cell_literals "$cell")
  printf '%s' "$out"
}

README_ROWS=0
README_LITERALS=0
DOC_DRIFT=""
while IFS= read -r row; do
  README_ROWS=$((README_ROWS + 1))
  ROW_KEY="$(printf '%s' "$row" | awk -F'|' '{print $2}' | tr -d ' `')"
  ROW_CELL="$(printf '%s' "$row" | awk -F'|' '{print $4}')"
  README_LITERALS=$((README_LITERALS + $(cell_literals "$ROW_CELL" | grep -c . | tr -d ' ')))
  DOC_DRIFT="$DOC_DRIFT$(cell_drift "$ROW_KEY" "$ROW_CELL")"
done < <(grep '^| `[a-z]' "$PLUGIN_DIR/README.md")

# The population is asserted BEFORE the verdict. A parse that matched nothing reports no drift,
# which is the shape where "checked and fine" and "never looked" print the same thing.
assert_eq "the README config table parsed into rows (a zero-row parse reports no drift forever)" \
  "$([[ "$README_ROWS" -ge 10 ]] && echo ">=10" || echo "PARSED $README_ROWS ROWS")" ">=10"
assert_eq "and those rows carry value claims to compare (prose-only cells compare nothing)" \
  "$([[ "$README_LITERALS" -ge 9 ]] && echo ">=9" || echo "ONLY $README_LITERALS LITERALS")" ">=9"
assert_eq "the checkCommand row in particular states a value, so it is inside the population" \
  "$([[ -n "$(cell_literals "$(grep '^| `checkCommand`' "$PLUGIN_DIR/README.md" | awk -F'|' '{print $4}')")" ]] && echo stated || echo prose)" \
  "stated"
assert_eq "no README default contradicts the code" "$DOC_DRIFT" ""

# NON-ZERO CONTROL, run through the SAME comparison against the SAME live registry: a cell
# claiming a default the code does not produce is reported, and names both sides.
FAKE_CELL='`npm run typecheck && npm test && npm run lint`'
assert_contains "CONTROL: the comparison reports a README default the code does not produce" \
  "$(cell_drift checkCommand "$FAKE_CELL")" "README states [npm run typecheck && npm test && npm run lint]"
assert_contains "and it names what the code actually falls back to, not just that they differ" \
  "$(cell_drift checkCommand "$FAKE_CELL")" "npm run typecheck if package.json declares it"
assert_eq "CONTROL: and it reports nothing for a cell that matches the registry" \
  "$(cell_drift knowledgeDir '`knowledge`')" ""
assert_contains "CONTROL: an unregistered key is named rather than silently skipped" \
  "$(cell_drift notARealKey '`whatever`')" "notARealKey(unregistered)"

# THE TWO MUTATIONS THAT WALKED PAST THE CONTAINMENT VERSION, run through the live registry.
# Both were measured green at 75/0 before this change; both are named failures now.
assert_eq "the real migrationDownMarker cell still passes, so the tightening did not just refuse everything" \
  "$(cell_drift migrationDownMarker '`-- DOWN`')" ""
assert_contains "CONTROL: a TRUNCATED default (\`-- D\` for \`-- DOWN\`) is refused" \
  "$(cell_drift migrationDownMarker '`-- D`')" "README states [-- D]"
assert_contains "CONTROL: and a truncation of a one-word default is refused too" \
  "$(cell_drift integrationBranch '`mai`')" "README states [mai]"
assert_contains "CONTROL: a FILE PATH standing in for a command default is refused" \
  "$(cell_drift checkCommand '`hooks/stop.sh`')" "that is a module path"
# The same claim in the spelling a pointer cell legitimately uses. Without this case the fix is
# one rewording away from being defeated: `reader` for checkCommand really is hooks/stop.sh, so
# only the "is this key's default actually a built-in" question can refuse it.
assert_contains "CONTROL: dressed as a pointer, it is still refused, because that default is no built-in" \
  "$(cell_drift checkCommand 'the default in `hooks/stop.sh`')" "which is not a built-in"

# The four cells QA measured as UNFALSIFIABLE, each now put through a check that can refuse. A
# pointer that names no real file, and a pointer to a module that does not read the key, are the
# two ways a path-shaped claim goes wrong; both were invisible while `reader` was searched as a
# substring for the value.
POINTER_MISS=""
POINTER_WRONG=""
for k in migrationGlobs dataLayerGlobs infraGlobs dispatchModels; do
  [[ -n "$(cell_drift "$k" "the default in \`scripts/no-such-module.mjs\`")" ]] \
    || POINTER_MISS="$POINTER_MISS $k"
  [[ -n "$(cell_drift "$k" "the default in \`hooks/stop.sh\`")" ]] \
    || POINTER_WRONG="$POINTER_WRONG $k"
done
assert_eq "CONTROL: every pointer cell refuses a module path that does not exist" "$POINTER_MISS" ""
assert_eq "CONTROL: and refuses a real file that does not read that key" "$POINTER_WRONG" ""

# The boundary rule itself, since four assertions above depend on it discriminating rather than
# always saying yes or always saying no.
assert_eq "delimited_in finds a needle bounded by quotes" \
  "$(delimited_in 'the built-in "-- DOWN" line-comment marker' '-- DOWN' && echo found || echo no)" "found"
assert_eq "and refuses the same needle truncated mid-word" \
  "$(delimited_in 'the built-in "-- DOWN" line-comment marker' '-- D' && echo found || echo no)" "no"
assert_eq "and finds one that runs to the end of the string" \
  "$(delimited_in 'otherwise NOTHING' 'NOTHING' && echo found || echo no)" "found"

# The same false claim also lived OUTSIDE the table, in agents/dev.md, where the row parser
# cannot reach it. A check that only covers the shape the drift was found in leaves its twin
# in place: the claim is refused wherever a doc calls that command the DEFAULT.
FALSE_DEFAULT_FILES="$( { grep -rl 'default `npm run typecheck && npm test && npm run lint`' \
  "$PLUGIN_DIR/README.md" "$PLUGIN_DIR/agents" "$PLUGIN_DIR/commands" 2>/dev/null || true; } | wc -l | tr -d ' ')"
assert_eq "no doc calls the full three-part command the checkCommand DEFAULT" "$FALSE_DEFAULT_FILES" "0"
FALSE_DEFAULT_PROBE="$TEMP_PROJECT/false-default-probe.md"
printf '%s\n' 'run your check command (default `npm run typecheck && npm test && npm run lint`).' \
  > "$FALSE_DEFAULT_PROBE"
assert_eq "CONTROL: the same grep DOES find the claim when it is present" \
  "$(grep -c 'default `npm run typecheck && npm test && npm run lint`' "$FALSE_DEFAULT_PROBE" | tr -d ' ')" "1"
# ...and the example config may still USE that command, which is a suggestion and not a claim
# about what happens when the key is absent. Asserted so a later cleanup does not delete it as
# though it were the same defect.
assert_eq "the example config still SETS it, which is the right place for that command" \
  "$(grep -c '"checkCommand": "npm run typecheck && npm test && npm run lint"' "$EXAMPLE" | tr -d ' ')" "1"

# =============================================================================
# AC28 -- LOUD MATCH-NOTHING, at PATTERN granularity, per CONSUMER.
# =============================================================================
suite "AC28(a): a CONFIGURED pattern that owns nothing is named by its literal text"

R_DEAD=$(make_repo_with dead-pattern '{"checkCommand":"npm test","migrationGlobs":["db/changes/**"]}' 'db/migrations/0001.sql' 'src/x.ts')
OUT_DEAD="$(doctor_out "$R_DEAD")"
assert_contains "the dead pattern is named by its literal text" "$OUT_DEAD" 'migrationGlobs pattern "db/changes/**" matches NONE'
assert_contains "and it is a WARNING" "$OUT_DEAD" "WARNING"

# The rev-2 shape reported at KEY granularity and could not fire here at all: the key's
# effective set contains the built-in presets, which DO match db/migrations/0001.sql.
assert_not_contains "the KEY as a whole is not reported (its effective set matches plenty)" \
  "$OUT_DEAD" 'migrationGlobs matches NONE'

suite "AC28(b): the GATE's dead set is reported separately, in the gate's own consequence terms"

assert_contains "the gate's discovery is reported as dead" "$OUT_DEAD" "down-section gate discovers NOTHING"
assert_contains "and it names the consequence in the gate's terms" "$OUT_DEAD" "checking zero files"
assert_contains "and says the TRIPWIRE is unaffected, since only the gate's set can go dead" \
  "$OUT_DEAD" "mis-tier tripwire is unaffected"

suite "AC28 NON-ZERO CONTROLS, in both directions"

# Direction 1: a configured pattern that DOES match produces no warning for that pattern. The
# warning above was OBSERVED firing first, so this absence is a measurement and not a silence.
R_LIVE=$(make_repo_with live-pattern '{"checkCommand":"npm test","migrationGlobs":["db/changes/**"]}' 'db/changes/0001.sql' 'src/x.ts')
OUT_LIVE="$(doctor_out "$R_LIVE")"
assert_not_contains "a pattern that matches a tracked file raises no warning" "$OUT_LIVE" 'matches NONE'
assert_not_contains "and the gate is not reported dead" "$OUT_LIVE" "discovers NOTHING"
assert_contains "CONTROL: the same doctor DID warn about the same pattern one repo earlier" \
  "$OUT_DEAD" 'db/changes/**'

# Direction 2: no repository, no population, no zero. A "zero matches" over a corpus that does
# not exist is the vacuous green this whole suite is built to refuse.
NOGIT="$TEMP_PROJECT/not-a-repo"
mkdir -p "$NOGIT"
printf '%s' '{"checkCommand":"npm test","migrationGlobs":["db/changes/**"]}' > "$NOGIT/pipeline.config.json"
OUT_NOGIT="$(doctor_out "$NOGIT")"
assert_not_contains "a non-git directory produces no zero-match output at all" "$OUT_NOGIT" "matches NONE"
assert_contains "but the ordinary diagnosis still runs there" "$OUT_NOGIT" "all keys recognized"

suite "AC28(c): a project with no data layer and no surface config gets an INFO, not a WARNING"

# Asserted against THIS repository, which is the case the demotion exists for: its tracked
# files match zero narrow-set and zero broad-set globs, so the key-granularity shape would
# have emitted a permanent every-session warning here from day one.
OUT_SELF="$(doctor_out "$REPO_ROOT")"
assert_contains "this repo is told it has no data layer the pipeline can see" "$OUT_SELF" "no data layer the pipeline can see"
assert_contains "as an INFO line" "$OUT_SELF" "INFO: no tracked file matches the built-in data-layer globs"
assert_not_contains "never as a WARNING" "$OUT_SELF" "WARNING"
assert_eq "and the exit code is still 0" "$(doctor_rc "$REPO_ROOT")" "0"

# =============================================================================
# AC29 -- UNSUPPORTED GLOB SYNTAX WARNS (warning only; the exit code never moves).
# =============================================================================
suite "AC29: a glob shape that compiles to something matching nothing is called out"

# The case NAME is passed explicitly rather than derived from the glob text. Deriving it
# collapsed four different globs onto two directories (every non-alphanumeric character is
# stripped, so '!db/...', '/db/...' and '../db/...' all named the same fixture), and each
# case then read the config the previous one had written -- a fixture that never constructs
# the case it claims to test.
syntax_out() { # <case-name> <glob-json>
  local dir="$TEMP_PROJECT/syn-$1"
  mkdir -p "$dir/db/migrations"
  git -C "$dir" init -q 2>/dev/null
  printf 'x\n' > "$dir/db/migrations/0001.sql"
  git -C "$dir" add -A >/dev/null 2>&1
  git -C "$dir" -c user.email=t@t -c user.name=t commit -q -m f >/dev/null 2>&1
  printf '{"checkCommand":"npm test","migrationGlobs":[%s]}' "$2" > "$dir/pipeline.config.json"
  doctor_out "$dir"
}

# The glob travels through a VARIABLE, and that is load-bearing rather than tidy: bash 3.2
# (the system bash on macOS, and what run.sh executes) performs BRACE EXPANSION on a word
# containing `{a,b}` even when the braces sit inside a double-quoted command substitution.
# Written inline, `"$(syntax_out braces '"{db,supabase}/..."')"` split into TWO arguments, the
# assertion's arguments shifted by one, and the case silently compared two unrelated doctor
# outputs. An assignment word is not brace-expanded, so this is the fixture actually carrying
# the pattern it names.
G_BRACES='"{db,supabase}/migrations/**"'
G_CLASS='"db/[0-9]*/migrations/**"'
G_BANG='"!db/migrations/**"'
G_SLASH='"/db/migrations/**"'
G_DOTDOT='"../db/migrations/**"'
G_PLAIN='"**/migrations/**"'

OUT_BRACES="$(syntax_out braces "$G_BRACES")"
assert_contains "brace expansion warns"  "$OUT_BRACES" "brace/bracket expansion is NOT supported"
assert_contains "and it names the offending pattern by its literal text" "$OUT_BRACES" "{db,supabase}/migrations/**"
assert_contains "a character class warns" "$(syntax_out charclass "$G_CLASS")" "brace/bracket expansion is NOT supported"
assert_contains "a leading ! warns"       "$(syntax_out bang "$G_BANG")" "leading '!'"
assert_contains "a leading / warns"       "$(syntax_out leadslash "$G_SLASH")" "cannot match a repo-relative diff path"
assert_contains "a leading ../ warns"     "$(syntax_out dotdot "$G_DOTDOT")" "cannot match a repo-relative diff path"
assert_contains "and each names the consequence for that key" "$OUT_BRACES" "the pre-Phase-4 gate discovers no migration"

# NON-ZERO CONTROL: a plain, supported glob raises nothing, and it is the same fixture shape,
# so the difference is the pattern and not the repository.
assert_not_contains "CONTROL: a plain **/migrations/** raises no syntax warning" \
  "$(syntax_out plain "$G_PLAIN")" "NOT supported"

# The leading-slash case is not a style opinion; it genuinely matches nothing.
assert_eq "CONTROL: '/db/migrations/**' really does NOT match 'db/migrations/0001.sql'" \
  "$(node -e 'import(process.argv[1]).then(m=>console.log(m.isMigrationPath("db/migrations/0001.sql",["/db/migrations/**"])))' "$SURFACE")" \
  "false"

suite "AC29: a poisoned array element is named with its index, never silently dropped"

R_POISON=$(make_repo_with poison '{"checkCommand":"npm test","migrationGlobs":["db/migrations/**",42]}' 'db/migrations/0001.sql')
OUT_POISON="$(doctor_out "$R_POISON")"
assert_contains "the non-string element is named with its index" "$OUT_POISON" "migrationGlobs[1] is 42"
assert_contains "and says it is dropped before compilation" "$OUT_POISON" "DROPPED before compilation"

# =============================================================================
# AC45 -- THE CONTRACT IS PRESERVED: exit 0 always, never writes, never crashes.
# =============================================================================
suite "AC45: config-doctor never blocks, never writes, and never crashes"

R_UNPARSEABLE=$(make_repo_with unparseable '{"migrationGlobs": [ this is not json' 'src/x.ts')
R_POISONED=$(make_repo_with poisoned-arr '{"checkCommand":"npm test","migrationGlobs":[null,123,{}]}' 'db/migrations/0001.sql')

assert_eq "exit 0 on an unparseable config"    "$(doctor_rc "$R_UNPARSEABLE")" "0"
assert_eq "exit 0 on a poisoned glob array"    "$(doctor_rc "$R_POISONED")" "0"
assert_eq "exit 0 in a non-git directory"      "$(doctor_rc "$NOGIT")" "0"
assert_eq "exit 0 against this repo itself"    "$(doctor_rc "$REPO_ROOT")" "0"
assert_eq "exit 0 with every new key set"      "$(doctor_rc "$R_ALLKEYS")" "0"
assert_contains "a poisoned array does not throw: the diagnosis still prints" "$(doctor_out "$R_POISONED")" "DROPPED before compilation"

BEFORE=$(cd "$R_DEAD" && find . -type f | sort)
doctor_out "$R_DEAD" >/dev/null
AFTER=$(cd "$R_DEAD" && find . -type f | sort)
assert_eq "it writes nothing: the fixture tree is byte-identical afterwards" "$BEFORE" "$AFTER"

suite "AC45 NON-ZERO CONTROL: the exit-0 assertion is watched going RED against a planted exit(1)"

# The whole scripts/ directory is copied so the planted mutation runs with its real imports.
# It is never applied to the checkout: an interrupted battery that left a planted defect in a
# tracked file is a documented way to ship one.
MUT="$TEMP_PROJECT/mutant"
mkdir -p "$MUT"
cp "$SCRIPTS_DIR"/*.mjs "$MUT/"
node -e '
  const fs = require("node:fs");
  const f = process.argv[1];
  const s = fs.readFileSync(f, "utf8");
  const needle = "function main() {";
  if (!s.includes(needle)) { console.error("MUTATION DID NOT APPLY"); process.exit(3); }
  fs.writeFileSync(f, s.replace(needle, needle + "\n  process.exit(1); // planted"));
' "$MUT/config-doctor.mjs"
assert_eq "the mutation really landed (the planted line is in the copy)" \
  "$(grep -c 'planted' "$MUT/config-doctor.mjs" | tr -d ' ')" "1"
MUT_RC=$( ( cd "$R_DEAD" && CLAUDE_PROJECT_DIR="$R_DEAD" node "$MUT/config-doctor.mjs" >/dev/null 2>&1 ); printf '%s' "$?" )
assert_eq "and the exit-code assertion DOES go red against it" "$MUT_RC" "1"
assert_eq "while the real script, run the same way, stays 0" "$(doctor_rc "$R_DEAD")" "0"

finish
