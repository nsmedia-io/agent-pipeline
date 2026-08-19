#!/usr/bin/env bash
# gate-pre-phase4.mjs — the down-region CLASSIFIER (issue #30, commit A).
#
# BEHAVIOURAL CONTRACT, authored at Phase 3a BEFORE the implementation exists. Every case
# here is written against an OBSERVABLE outcome of the gate binary: its exit code and its
# stderr. Nothing in this file imports a private helper or asserts a call sequence, so the
# implementation is free to be shaped however Dev likes as long as it classifies correctly.
#
# WHAT IS BEING CLASSIFIED. The down REGION is the text of a migration beginning at the FIRST
# NEWLINE AT OR AFTER the down marker's line (spec A1) -- i.e. the marker's own line is NOT
# part of the region. The region is classified as exactly one of:
#
#     clean          -- nothing but comments every target dialect agrees are comments
#     executable     -- residue remains after the strip, i.e. a database would RUN something
#     indeterminate  -- the region cannot be classified (an unterminated `/*`)
#
# Both non-clean values exit RC=1, and their MESSAGES DIFFER. Pinning RC alone leaves the
# fail-closed direction holding by coincidence (spec A4), so the messages are asserted.
#
# THE SCAN (spec A2/A3), stated because three plausible implementations each pass a live
# DROP on a DIFFERENT cell and no single mutation reaches all three:
#   * ONE left-to-right scan, FIRST-ENCOUNTERED token wins. Inside a `--` line comment a
#     `/*` is inert; inside a block comment a `--` is inert. Two-pass regex stripping is
#     forbidden in EITHER order -- block-comments-first calls cell (g) clean and a database
#     executes that DROP.
#   * Block comments DO NOT NEST. The first `*/` closes, whatever the depth. PostgreSQL and
#     SQL Server nest; MySQL/MariaDB, SQLite and Oracle do not. Strip only what EVERY target
#     dialect agrees is a comment and classify executable on divergence -- cell (h).
#   * A block opener IMMEDIATELY followed by `!` or `M!` is NOT stripped: MySQL/MariaDB
#     EXECUTE the contents of `/*! ... */`, `/*!NNNNN ... */` and `/*M! ... */` -- cell (k).
#     This does NOT extend to `/*+ hint */`; cells (k-ctl-1) and (k-ctl-2) are the non-zero
#     controls proving the clause targets the `!`/`M!` opener and not block comments at large.
#
# MESSAGE CONTRACT (spec A5, promoted from Q-DEV-5). The literal substrings asserted below
# ARE the contract; a bare "executable SQL found at line N" satisfies the RC pin while being
# unactionable, and an unactionable halt is how an adopting project deletes the gate.
#   executable   : the migration path; the first offending line NUMBER and ITS TEXT; when the
#                  residue followed a CLOSED block, the LINE AND COLUMN of the `*/` that
#                  closed it; the sentence that block comments do not nest so the first `*/`
#                  closes; the remedy ("remove the inner" delimiters, or "reflow" to `--`).
#   indeterminate: the word `indeterminate`, the phrase `unterminated block comment`, the line
#                  carrying the `/*`, and its remedy. It must NOT read as `executable SQL`.
#   `/*!` family : additionally names the construct a MySQL/MariaDB `conditional-execution`
#                  comment whose body the server RUNS.
#
# FIXTURE DISCIPLINE, inherited from test-gate-pre-phase4.sh and load-bearing here: every
# impl-report fixture is schema-VALID, so an exit 1 is attributable to the migration rule and
# nothing else. Each migration case asserts stderr carries no "impl-report schema:" line.
# Every fixture lives under one registered mktemp root; nothing is written into the checkout.
#
# EVERY DOWN REGION BELOW STARTS ON LINE 3 of its file, so a `line 3` assertion is stable.

. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
require_node

GATE="$SCRIPTS_DIR/gate-pre-phase4.mjs"
GATE_SRC="$SCRIPTS_DIR/gate-pre-phase4.mjs"
ISSUE=4243

make_temp_project "$ISSUE" || exit 90

new_project() {
  PROJ="$TEMP_PROJECT/$1"
  PROJ_ISSUE_DIR="$PROJ/.pipeline/$ISSUE"
  mkdir -p "$PROJ_ISSUE_DIR"
}

write_report() {
  local rel="$1"
  cat > "$PROJ_ISSUE_DIR/impl-report.json" <<EOF
{
  "issue_number": $ISSUE,
  "branch": "fix/enforce-what-we-claim",
  "commits": [{"sha":"a1","message":"m","files_changed":["$rel"]}],
  "files_removed": [],
  "checks_passed": {"typecheck": true, "test": true, "lint": true},
  "completed_at": "2026-01-01T00:00:00Z",
  "requirement_checks": [
    {"requirement_index": 0, "requirement_text": "AC1 handled", "status": "PASS", "notes": "recorded by the fixture"}
  ]
}
EOF
}

write_spec() {
  cat > "$PROJ_ISSUE_DIR/spec.json" <<EOF
{"issue_number": $ISSUE, "acceptance_criteria": ["AC1: migrations are reversible"]}
EOF
}

write_config() { printf '%s' "$1" > "$PROJ/pipeline.config.json"; }

write_migration() {
  mkdir -p "$PROJ/$(dirname "$1")"
  printf '%s' "$2" > "$PROJ/$1"
}

gate() {
  local outf="$TEMP_PROJECT/out.txt" errf="$TEMP_PROJECT/err.txt"
  ( cd "$PROJ" && CLAUDE_PROJECT_DIR="$PROJ" node "$GATE" "$@" ) >"$outf" 2>"$errf"
  RC=$?
  OUT=$(cat "$outf")
  ERR=$(cat "$errf")
}

# run_cell <case-name> <rel-path> <down-region-body> [config-json]
# Builds a migration whose up section is line 1, whose marker is line 2, and whose down
# region therefore begins on LINE 3.
run_cell() {
  local name="$1" rel="$2" body="$3" cfg="${4:-}" marker="${5:--- DOWN}"
  new_project "$name"
  write_spec
  write_report "$rel"
  [[ -n "$cfg" ]] && write_config "$cfg"
  write_migration "$rel" "create table foo (id int);
$marker
$body"
  gate --issue "$ISSUE"
}

# Every migration case asserts this, so an exit 1 can never be credited to a schema rejection.
assert_not_schema() {
  assert_not_contains "$1 (attributable: not a schema rejection)" "$ERR" "impl-report schema:"
}

suite "gate down-region classifier: AC1/AC2 -- the refusal and its non-zero control"

# AC1. Executable SQL after the marker LINE halts, is classified `executable`, and names the
# migration and the first offending line.
run_cell ac1-executable "migrations/030_exec.sql" "drop table foo;
"
assert_eq "AC1: an executable down region halts the panel" "$RC" "1"
assert_not_schema "AC1"
assert_contains "AC1: the halt names the classification" "$ERR" "executable"
assert_contains "AC1: the halt names the migration" "$ERR" "migrations/030_exec.sql"
assert_contains "AC1: the halt names the first offending line number" "$ERR" "line 3"
assert_contains "AC1: the halt quotes the offending line's text" "$ERR" "drop table foo;"

# AC2. THE NON-ZERO CONTROL ON AC1, in the opposite direction: the new refusal must reject
# the executable region and ONLY the executable region. Without this cell, "fail every
# migration" would satisfy AC1.
run_cell ac2-commented "migrations/031_ok.sql" "-- drop table foo;
"
assert_eq "AC2 CONTROL: a fully \`--\` commented down region still passes" "$RC" "0"
assert_contains "AC2 CONTROL: and the gate says so" "$OUT" "OK: pre-Phase-4 gate passed."

suite "gate down-region classifier: AC3 -- the eleven-cell fixture matrix"

# The matrix is the CROSS PRODUCT, not a representative fixture. Cells (g), (h) and (i) are
# each the ONLY cell a specific plausible implementation gets wrong; cell (k) is the only cell
# BOTH candidate scans get wrong. No cell is represented by another.

# (a) line comments only => clean / RC=0
run_cell ac3-a "migrations/03a.sql" "-- rollback: drop table foo;
-- restore from PITR if this ran in prod
"
assert_eq "AC3(a): line comments only => clean, RC=0" "$RC" "0"

# (b) a block comment only => clean / RC=0
run_cell ac3-b "migrations/03b.sql" "/* rollback: drop table foo; */
"
assert_eq "AC3(b): a block comment only => clean, RC=0" "$RC" "0"

# (c) a block comment CLOSED then executable SQL on the SAME line => executable / RC=1
run_cell ac3-c "migrations/03c.sql" "/* note */ drop table foo;
"
assert_eq "AC3(c): block closed then SQL on the same line => executable, RC=1" "$RC" "1"
assert_not_schema "AC3(c)"
assert_contains "AC3(c): and the residue's line is quoted" "$ERR" "drop table foo;"

# (d) executable SQL with no comment at all => executable / RC=1
run_cell ac3-d "migrations/03d.sql" "delete from users where 1=1;
"
assert_eq "AC3(d): uncommented SQL => executable, RC=1" "$RC" "1"
assert_not_schema "AC3(d)"

# (e) line and block comments mixed => clean / RC=0
run_cell ac3-e "migrations/03e.sql" "-- rollback notes follow
/* drop table foo; */
-- end
"
assert_eq "AC3(e): line and block comments mixed => clean, RC=0" "$RC" "0"

# (f) a block comment spanning multiple lines => clean / RC=0
run_cell ac3-f "migrations/03f.sql" "/* rollback:
     drop table foo;
   restore via PITR
*/
"
assert_eq "AC3(f): a multi-line block comment => clean, RC=0" "$RC" "0"

# (g) THE COMMENT TOGGLE. A `--` runs to end of line, so the `/*` on line 3 never opens a
# block and the DROP on line 4 is live SQL. A block-comments-FIRST two-pass strip calls this
# CLEAN and hands a database a live DROP. This cell is the ONLY one that mutation reaches.
run_cell ac3-g "migrations/03g.sql" "-- /*
drop table foo;
-- */
"
assert_eq "AC3(g): the comment toggle => executable, RC=1" "$RC" "1"
assert_not_schema "AC3(g)"
assert_contains "AC3(g): the live DROP is named as the offending line" "$ERR" "drop table foo;"
assert_contains "AC3(g): and its line number is line 4" "$ERR" "line 4"

# (h) THE NESTED BLOCK. A nest-aware scan calls this CLEAN and MySQL/MariaDB, SQLite and
# Oracle then execute the DROP. Non-nesting: the first `*/` (line 3, column 19) closes, so
# ` drop table users; */` is residue.
#
# MESSAGE AXIS. This is the cell where "the first offending line" is PROSE THE AUTHOR
# BELIEVES IS INSIDE A COMMENT, so naming the line explains nothing on its own. The message
# assertions below are what mutation (v) -- emit a bare "executable SQL found at line N" --
# must redden WHILE THE RC ASSERTION ABOVE STAYS GREEN. If they stay green under that
# mutation, the message was never asserted and the Q-DEV-5 promotion did not land.
run_cell ac3-h "migrations/03h.sql" "/* outer /* inner */ drop table users; */
"
assert_eq "AC3(h): the nested block => executable, RC=1" "$RC" "1"
assert_not_schema "AC3(h)"
assert_contains "AC3(h) MESSAGE: names the migration file" "$ERR" "migrations/03h.sql"
assert_contains "AC3(h) MESSAGE: names the offending line number" "$ERR" "line 3"
assert_contains "AC3(h) MESSAGE: quotes the offending line's TEXT" "$ERR" "drop table users;"
assert_contains "AC3(h) MESSAGE: gives the column of the \`*/\` that closed the block" "$ERR" "column 19"
assert_contains "AC3(h) MESSAGE: says block comments do not nest" "$ERR" "not nest"
assert_contains "AC3(h) MESSAGE: says the first \`*/\` closes" "$ERR" "first */"
assert_contains "AC3(h) MESSAGE: remedy -- remove the inner delimiters" "$ERR" "remove the inner"
assert_contains "AC3(h) MESSAGE: remedy -- or reflow to \`--\` lines" "$ERR" "reflow"

# (i) UNTERMINATED `/*`. See the AC4 suite below for the classification and message axes;
# the cell itself is asserted here so the matrix is complete in one place.
run_cell ac3-i "migrations/03i.sql" "/* drop table users;
"
assert_eq "AC3(i): an unterminated block comment => RC=1" "$RC" "1"
assert_not_schema "AC3(i)"

# (j) A CONFIGURED NON-COMMENT MARKER over a down region of pure `--` comments => clean.
# The marker is `# DOWN`, which is NOT a comment in any target dialect, so a region classified
# from downMarkerIndex itself leaves `# DOWN` as residue and EVERY migration in such a project
# fails forever from its first upgrade. Classifying from the END OF THE MARKER LINE closes it.
# The default `-- DOWN` marker IS a comment and strips away, so every other cell in this
# matrix is structurally blind to this defect -- which is why (j) needs its own cell.
run_cell ac3-j "migrations/03j.sql" "-- drop table foo;
" '{"migrationDownMarker": "# DOWN"}' "# DOWN"
assert_eq "AC3(j): a configured \`# DOWN\` marker over a \`--\` region => clean, RC=0" "$RC" "0"

# (j-ctl) THE WITNESSED NON-ZERO CONTROL ON (j). Without it, an implementation that simply
# stopped finding the configured marker would pass (j) vacuously -- RC=0 because no migration
# was ever classified. Same project shape, executable body: it MUST halt.
run_cell ac3-j-ctl "migrations/03j2.sql" "drop table foo;
" '{"migrationDownMarker": "# DOWN"}' "# DOWN"
assert_eq "AC3(j) CONTROL: the same \`# DOWN\` project still halts on an executable region" "$RC" "1"
assert_not_schema "AC3(j) CONTROL"
assert_contains "AC3(j) CONTROL: and the region really was classified" "$ERR" "executable"

# (k) MySQL/MariaDB CONDITIONAL-EXECUTION comments. The server RUNS the body. All four
# siblings classify CLEAN under BOTH candidate scans (non-nesting and nest-aware), so neither
# reading catches them and this cell could not be reached by mutating between the two. Each
# sibling is asserted SEPARATELY: `/*!` and `/*M!` are different openers and `/*!NNNNN` is a
# different lexical shape from a bare `/*!`.
run_cell ac3-k1 "migrations/03k1.sql" "/*! drop table users; */
"
assert_eq "AC3(k1): \`/*!\` => executable, RC=1" "$RC" "1"
assert_not_schema "AC3(k1)"
assert_contains "AC3(k1) MESSAGE: names the MySQL/MariaDB construct" "$ERR" "conditional-execution"
assert_contains "AC3(k1) MESSAGE: names the dialect" "$ERR" "MySQL"
assert_contains "AC3(k1) MESSAGE: names the migration file" "$ERR" "migrations/03k1.sql"

run_cell ac3-k2 "migrations/03k2.sql" "/*!50000 drop table users; */
"
assert_eq "AC3(k2): \`/*!50000\` => executable, RC=1" "$RC" "1"
assert_not_schema "AC3(k2)"
assert_contains "AC3(k2) MESSAGE: names the MySQL/MariaDB construct" "$ERR" "conditional-execution"

run_cell ac3-k3 "migrations/03k3.sql" "/*M! drop table users; */
"
assert_eq "AC3(k3): MariaDB \`/*M!\` => executable, RC=1" "$RC" "1"
assert_not_schema "AC3(k3)"
assert_contains "AC3(k3) MESSAGE: names the MySQL/MariaDB construct" "$ERR" "conditional-execution"

# The mysqldump-shaped sibling. Not exotic and not adversarial: `/*!40101 SET NAMES utf8 */`
# is ordinary dump output, so an author pasting dump text in as documentation reaches it.
run_cell ac3-k4 "migrations/03k4.sql" "/*!40101 SET NAMES utf8 */
"
assert_eq "AC3(k4): mysqldump's \`/*!40101 ... */\` => executable, RC=1" "$RC" "1"
assert_not_schema "AC3(k4)"
assert_contains "AC3(k4) MESSAGE: names the MySQL/MariaDB construct" "$ERR" "conditional-execution"

# (k-ctl-1) NON-ZERO CONTROL: an optimizer hint is NOT a standalone destructive statement and
# refusing it would false-halt legitimate documentation. The clause targets `!`/`M!` openers.
run_cell ac3-k-ctl1 "migrations/03kc1.sql" "/*+ full(t) */
"
assert_eq "AC3(k) CONTROL: an optimizer hint \`/*+\` still classifies clean, RC=0" "$RC" "0"

# (k-ctl-2) NON-ZERO CONTROL: a plain block comment is still a comment. If this reddens under
# mutation (iv) the implementation over-refuses rather than the mutation having worked.
run_cell ac3-k-ctl2 "migrations/03kc2.sql" "/* plain block comment */
"
assert_eq "AC3(k) CONTROL: a plain block comment still classifies clean, RC=0" "$RC" "0"

# (k-ctl-3) THE CASE AXIS, measured rather than read. `M!` is matched case-SENSITIVELY, and the
# obvious "hardening" is to lowercase both sides. MariaDB 11.8.8, one harness pass, both cells
# against a real server: `/*M! drop table users; */` DROPPED the table and the lowercase
# `/*m! ... */` twin SURVIVED. So lowercase does not open a conditional-execution comment, and
# a case-insensitive compare would refuse ordinary documentation beginning `m!` for nothing.
# Cell (k3) above is the uppercase half of the same pair; the two are only meaningful together.
run_cell ac3-k-ctl3 "migrations/03kc3.sql" "/*m! drop table users; */
"
assert_eq "AC3(k) CONTROL: a lowercase \`/*m!\` opener classifies clean, RC=0 (MariaDB does not run it)" "$RC" "0"
# The measurement is the only thing standing between this cell and a future "obviously it
# should be case-insensitive" edit, so the module must keep carrying it.
assert_contains "AC3(k) CONTROL: and the module records the execution that settled the case axis" \
  "$(cat "$GATE_SRC")" "CASE-SENSITIVE ON PURPOSE"

suite "gate down-region classifier: AC4 -- indeterminate is its own value, not executable"

# The natural lazy-regex strip leaves an unterminated `/*` as residue, yields RC=1, and
# REPORTS it as executable SQL naming the `/*` line. The first author who fixes that
# misleading message by consuming to EOF flips the case to CLEAN and a `/*` followed by a
# DROP sails through on PostgreSQL and MySQL. So the direction is pinned by an ASSERTED
# MESSAGE, not by an accident of remainder length: RC stays 1 under that misclassification
# while the assertions below redden.
run_cell ac4 "migrations/040_unterm.sql" "/* drop table users;
"
assert_eq "AC4: an unterminated \`/*\` halts" "$RC" "1"
assert_not_schema "AC4"
assert_contains "AC4: it is classified indeterminate" "$ERR" "indeterminate"
assert_contains "AC4: with the words 'unterminated block comment'" "$ERR" "unterminated block comment"
assert_contains "AC4: naming the line that carries the \`/*\`" "$ERR" "line 3"
assert_contains "AC4: and the migration file" "$ERR" "migrations/040_unterm.sql"
assert_contains "AC4: and its own remedy (close the block, or reflow to \`--\`)" "$ERR" "reflow"
# The discriminator. AC1's executable halt says "executable SQL"; this one must not, or the
# two classifications are distinguishable only to a reader who already knows the answer.
assert_not_contains "AC4: and is NOT reported as the executable case" "$ERR" "executable SQL"

suite "gate down-region classifier: AC4(b) -- a lone CR ends a \`--\` comment, as PostgreSQL says"

# THE FOURTH FAIL-OPEN OF THIS CLASS, and the same shape as (g), (h) and (k): a token a target
# dialect treats as ENDING a comment that the scan did not. PostgreSQL's lexer defines the body
# of a line comment as `[^\n\r]`, so a lone CR (0x0D) ends it and the server parses what follows
# as SQL. A scan that ran to the next LF strips that SQL as commentary: the cell below
# classified CLEAN and the gate exited 0 on a live DROP, against this project's own dialect.
#
# The pair is ONE BYTE APART, which is the whole finding: the LF twin below was refused all
# along, so nothing about the shape of the text made it safe -- only the byte.
run_cell ac4b-cr "migrations/04l.sql" "-- rollback note"$'\r'"drop table users;
"
assert_eq "AC4(b): a lone CR mid-comment-line => executable, RC=1" "$RC" "1"
assert_not_schema "AC4(b)"
assert_contains "AC4(b): the halt names the classification" "$ERR" "executable"
assert_contains "AC4(b): and the line the CR is on" "$ERR" "line 3"
assert_contains "AC4(b): and quotes the SQL that follows the CR" "$ERR" "drop table users;"
# MESSAGE AXIS. The quoted line is the only place the CR is visible, and a RAW CR returns the
# terminal's cursor to column 1: the halt would render as `drop table users;` alone, hiding the
# `--` the author believed commented it out and making the message argue AGAINST itself.
assert_contains "AC4(b) MESSAGE: the CR is shown escaped in the quoted line" "$ERR" '\r'
assert_not_contains "AC4(b) MESSAGE: and not emitted raw, which would overwrite the quoted line" \
  "$ERR" $'\r'

# CONTROL 1, THE ONE-BYTE TWIN: the identical text with LF instead of CR. It was refused before
# this rule and is refused after it, at line 4 rather than line 3. Without it, the cell above
# could be reddening because the region contains `drop table users;` at all.
run_cell ac4b-lf "migrations/04l2.sql" "-- rollback note
drop table users;
"
assert_eq "AC4(b) CONTROL: the LF twin is refused too (it always was)" "$RC" "1"
assert_contains "AC4(b) CONTROL: but one line LATER, so the two cells are distinguishable" "$ERR" "line 4"

# CONTROL 2, WHAT THE RULE REFUSES AND NOTHING MORE: a CR that ends a comment line with only
# more commentary after it stays CLEAN. The refusal is the RESIDUE after the CR, not the CR.
run_cell ac4b-cr-clean "migrations/04l3.sql" "-- rollback note"$'\r'"-- restore via PITR
"
assert_eq "AC4(b) CONTROL: a CR followed by more commentary still classifies clean, RC=0" "$RC" "0"

# CONTROL 3, THE POPULATION THIS COULD HAVE BROKEN: a wholly CRLF file. Every line ends CR LF,
# so a rule that treated CR as anything but a terminator would false-halt every migration
# written on Windows -- a far larger population than the one the cell above refuses.
run_cell ac4b-crlf "migrations/04l4.sql" $'-- rollback note\r\n-- restore via PITR\r\n'
assert_eq "AC4(b) CONTROL: a CRLF region of pure comments is untouched, RC=0" "$RC" "0"
run_cell ac4b-crlf-exec "migrations/04l5.sql" $'-- rollback note\r\ndrop table users;\r\n'
assert_eq "AC4(b) CONTROL: and a CRLF region with real SQL still halts, RC=1" "$RC" "1"
assert_contains "AC4(b) CONTROL: naming the SQL line, not the comment above it" "$ERR" "line 4"

suite "gate down-region classifier: AC21 -- the region starts at the end of the marker LINE"

# AC21 restates cell (j) as its own criterion because the failure it prevents is total: under
# the naive slice-from-downMarkerIndex reading, EVERY migration in a project configuring a
# non-comment marker fails the gate permanently, from its first upgrade onward.
run_cell ac21 "migrations/050_hashmark.sql" "-- drop table foo;
-- restore via PITR
" '{"migrationDownMarker": "# DOWN"}' "# DOWN"
assert_eq "AC21: \`# DOWN\` + a commented region passes (region excludes the marker line)" "$RC" "0"
assert_contains "AC21: and the gate says so" "$OUT" "OK: pre-Phase-4 gate passed."

# The same shape under the DEFAULT marker, which IS a comment: this cell passes under both
# the correct and the naive reading, and is here to show that it cannot stand in for AC21.
run_cell ac21-default "migrations/051_default.sql" "-- drop table foo;
"
assert_eq "AC21 CONTRAST: the default \`-- DOWN\` marker passes under either reading" "$RC" "0"

suite "gate down-region classifier: AC7(b) -- the \`--\` no-whitespace boundary, fixtured in both directions"

# AN ACCEPTED BOUNDARY, WITH FIXTURES, because "documented as accepted" and "nobody ever
# checked" produce the same green. MySQL and MariaDB require whitespace after `--` before it
# is a comment; PostgreSQL, SQLite, Oracle and T-SQL do not. The scan sides with the majority
# and strips `--x`, so a MySQL-family target sees SQL where the gate saw commentary.
#
# The cells below assert the ACCEPT, which is the uncomfortable direction and exactly why they
# have to exist: the boundary shipped with a docstring sentence promising the cost was "never
# destruction" and with NO fixture using a `--` without following whitespace in EITHER
# direction. The sentence has been narrowed to what these cells actually show; if a later
# change closes the boundary, these cells go red and their comments say what to weigh.
run_cell ac7b-nows "migrations/07b1.sql" "--x; drop table users;
"
assert_eq "AC7(b): \`--x; drop table users;\` is ACCEPTED, RC=0 -- the documented boundary" "$RC" "0"
assert_contains "AC7(b): and the gate says so rather than passing silently" "$OUT" "OK: pre-Phase-4 gate passed."
# THE COST THIS CELL RECORDS, so nobody reads the RC=0 as a safety claim: on MySQL/MariaDB
# `--x` is not a comment, so a `;`-splitting runner sees a failing first statement and then a
# live `drop table users`. It needs a MySQL-family target AND a runner that continues past an
# error. The docstring carries this; the assertion below pins that it keeps carrying it.

# CONTROL 1: the SPACED twin. Without it the cell above could be read as "a semicolon inside a
# comment is fine", which is a different and much broader claim.
run_cell ac7b-ws "migrations/07b2.sql" "-- x; drop table users;
"
assert_eq "AC7(b) CONTROL: the spaced \`-- x; ...\` twin is accepted too, so the axis is the whitespace" "$RC" "0"

# CONTROL 2 and 3: WHAT REQUIRING WHITESPACE WOULD REFUSE. These are the population that makes
# the boundary worth keeping rather than closing, and they are ordinary, not contrived.
run_cell ac7b-divider "migrations/07b3.sql" "-----------------------------
-- rollback: restore via PITR
-----------------------------
"
assert_eq "AC7(b) CONTROL: a \`-----\` section divider stays clean, RC=0" "$RC" "0"
run_cell ac7b-nospace-prose "migrations/07b4.sql" "--drop the index, then restore from the nightly dump
"
assert_eq "AC7(b) CONTROL: and so does \`--drop the index\`, ordinary prose with no space" "$RC" "0"

# CONTROL 4: THE BOUNDARY IS CONFINED TO ONE LINE. The same DROP on the NEXT line is refused,
# which is what makes the accepted cell a narrow shape rather than "`--` disables the gate".
run_cell ac7b-nextline "migrations/07b5.sql" "--x
drop table users;
"
assert_eq "AC7(b) CONTROL: the same DROP on the NEXT line still halts, RC=1" "$RC" "1"
assert_not_schema "AC7(b) CONTROL"
assert_contains "AC7(b) CONTROL: naming it as executable" "$ERR" "executable"

# THE PROSE HALF. Asserted over the WHOLE MODULE, not over the docstring window the AC22 suite
# derives below: this is a banned SENTENCE rather than a required one, and a banned sentence
# must not reappear in any comment in the file -- including the classifier's own docblock,
# which is where a future editor is most likely to restate the rule.
GATE_TEXT="$(cat "$GATE_SRC")"
assert_not_contains "AC7(b): the module no longer promises the boundary is \"never as destruction\"" \
  "$GATE_TEXT" "never as destruction"
assert_contains "AC7(b): it names the second-statement shape that makes the promise false" \
  "$GATE_TEXT" "SECOND STATEMENT"
assert_contains "AC7(b): and names the runner condition the destruction needs" \
  "$GATE_TEXT" "continues past"
# ...and records WHY the obvious fix is not taken, or the next reader closes the boundary and
# false-halts every `-----` divider in the corpus.
assert_contains "AC7(b): and warns against \"fixing\" it by requiring whitespace after \`--\`" \
  "$GATE_TEXT" "DO NOT close this by requiring whitespace"

suite "gate down-region classifier: AC22 -- the docstring states the rule it now enforces"

# A prose reader that sides with the OLD predicate is the sentence that reintroduces the bug
# at the next reading. Each clause is asserted INDEPENDENTLY: a single combined edit must not
# be able to satisfy the whole assertion, and each of the three r3 mutations must redden
# exactly one line below.
#
# THE WINDOW IS DERIVED FROM THE FILE, NOT PINNED TO A LINE COUNT. This read was `sed -n
# '1,60p'` while the docstring ran to 95 lines, so the DIALECT BOUNDARIES list and the
# "Gate-green means" summary -- lines 61-95, the half most likely to acquire a sentence that
# sides with the old predicate -- sat outside every assertion below. Planting the banned
# sentence at line 75 left this suite green; the same sentence at line 43 reddened it. A
# larger literal is the same defect one docstring-growth later, so the window runs from the
# `/**` opener to the `*/` terminator, whatever lies between.
DOCSTRING=$(awk '/^\/\*\*/{f=1} f{print} f&&/^ \*\//{exit}' "$GATE_SRC")

# BOTH ENDS OF THAT WINDOW ARE PINNED, because a window derived wrong is not visibly different
# from one derived right. The far end is asserted against a line read out of the file by an
# independent derivation (grep for the terminator, sed for the line above it): a window that
# stops short -- including a regression to any fixed `1,Np` -- fails here rather than silently
# ceasing to look at the tail of the docstring.
DOC_END_LINE=$(grep -n '^ \*/' "$GATE_SRC" | head -1 | cut -d: -f1)
assert_eq "AC22 CONTROL: the docstring block's terminator was located" \
  "$([[ "${DOC_END_LINE:-0}" -gt 1 ]] && echo ok || echo "line=$DOC_END_LINE")" "ok"
assert_contains "AC22 CONTROL: and the window reaches the LAST line of that block" \
  "$DOCSTRING" "$(sed -n "$((DOC_END_LINE - 1))p" "$GATE_SRC")"
# ...and does not run PAST it, or the assertions below would be reading the module's code and
# would start passing on a `MySQL` that appears in a string literal rather than in the prose.
assert_not_contains "AC22 CONTROL: and stops at the block, not somewhere in the code below" \
  "$DOCSTRING" "import "

assert_not_contains "AC22: the docstring no longer claims a commented-out down region passes" \
  "$DOCSTRING" "entirely commented out passes"

# THE SECOND DOCBLOCK, and the one the criterion's own window missed. `classifyDownRegion`
# carries its own JSDoc, and that docblock is the single most likely place a future editor
# restates the rule -- it is the block that says "See the module docstring for why". The banned
# sentence planted there left this suite at 74/0. Same derivation discipline as the window
# above: read from the file, both ends pinned.
CLASSIFIER_FN_LINE=$(grep -n '^export function classifyDownRegion' "$GATE_SRC" | head -1 | cut -d: -f1)
assert_eq "AC22(b) CONTROL: the classifier's own docblock was located" \
  "$([[ "${CLASSIFIER_FN_LINE:-0}" -gt 1 ]] && echo ok || echo "line=$CLASSIFIER_FN_LINE")" "ok"
CLASSIFIER_DOC=$(awk '
  /^\/\*\*/ { buf = $0 "\n"; inblock = 1; next }
  inblock   { buf = buf $0 "\n"; if ($0 ~ /^ \*\//) { inblock = 0; last = buf } ; next }
  /^export function classifyDownRegion/ { printf "%s", last; exit }
' "$GATE_SRC")
# The far end, by an independent derivation: the line two above the `export` is the docblock's
# last substantive line. Pinned with a LENGTH FLOOR, because the day that line becomes a bare
# ` *` the needle is contained in every non-empty window and this control passes vacuously.
CLASSIFIER_DOC_LAST=$(sed -n "$((CLASSIFIER_FN_LINE - 2))p" "$GATE_SRC")
assert_eq "AC22(b) CONTROL: and its last substantive line is substantive, not a bare \` *\`" \
  "$([[ "${#CLASSIFIER_DOC_LAST}" -ge 20 ]] && echo ok || echo "needle is ${#CLASSIFIER_DOC_LAST} chars: [$CLASSIFIER_DOC_LAST]")" "ok"
assert_contains "AC22(b) CONTROL: the window reaches that last line" \
  "$CLASSIFIER_DOC" "$CLASSIFIER_DOC_LAST"
# BOTH ENDS, and the near end is not the same risk as the far end. The module docstring's
# window was pinned at the tail because its historical defect was a `1,60p` that stopped short.
# A window ANCHORED at the function and read backwards fails the other way -- it starts too
# late -- and a docblock whose first half is missing is not visibly different from one that is
# whole. The opener is located by an independent scan for the last `/**` above the function.
CLASSIFIER_DOC_OPEN=$(awk -v n="$CLASSIFIER_FN_LINE" 'NR < n && /^\/\*\*/ { l = NR } END { print l }' "$GATE_SRC")
CLASSIFIER_DOC_FIRST=$(sed -n "$((CLASSIFIER_DOC_OPEN + 1))p" "$GATE_SRC")
assert_eq "AC22(b) CONTROL: its first substantive line is substantive too" \
  "$([[ "${#CLASSIFIER_DOC_FIRST}" -ge 20 ]] && echo ok || echo "needle is ${#CLASSIFIER_DOC_FIRST} chars: [$CLASSIFIER_DOC_FIRST]")" "ok"
assert_contains "AC22(b) CONTROL: and the window reaches back to it" \
  "$CLASSIFIER_DOC" "$CLASSIFIER_DOC_FIRST"
assert_not_contains "AC22(b) CONTROL: and stops at the block, not in the function body below" \
  "$CLASSIFIER_DOC" "export function"
assert_not_contains "AC22(b): the classifier's own docblock does not restate the old predicate either" \
  "$CLASSIFIER_DOC" "entirely commented out passes"

# DOCUMENTED EXPECTED SURVIVOR, so that a battery reporting "everything reddens" is not the
# only reading available. The same banned sentence written as a `//` comment ANYWHERE ELSE in
# the module -- e.g. immediately below the docstring -- leaves this suite green, and that is
# the intended boundary rather than an unclosed hole: AC22 is about the two blocks that STATE
# the rule (the module docstring and the classifier's docblock). A ban over every comment in
# the file would also forbid a comment EXPLAINING why the old predicate was wrong, which is
# exactly the sentence a future reader most needs to find. If that judgement is ever revised,
# the change is to grep "$GATE_SRC" whole rather than to widen either window -- and the shape
# is already in this file: AC7(b) bans its sentence file-wide, because that one has no
# legitimate restatement.
assert_contains "AC22: it states that block comments do not nest" "$DOCSTRING" "not nest"
assert_contains "AC22: naming MySQL as a reason" "$DOCSTRING" "MySQL"
assert_contains "AC22: naming SQLite as a reason" "$DOCSTRING" "SQLite"
assert_contains "AC22: naming SQL Server (T-SQL) among the NESTING dialects" "$DOCSTRING" "T-SQL"
assert_contains "AC22: and stating that \`/*!\` openers are refused" "$DOCSTRING" "/*!"
assert_contains "AC22: and \`/*M!\` openers too" "$DOCSTRING" "/*M!"
# The CR rule is prose the next reader is most likely to "simplify" back: scanning a line
# comment to the newline is what everybody writes, and the byte that makes it wrong is
# invisible in a diff. So the docstring must keep SAYING which characters end the comment.
assert_contains "AC22: and that a \`--\` comment ends at the first CR **or** LF" \
  "$DOCSTRING" '`[^\n\r]`'

finish
