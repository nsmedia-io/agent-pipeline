#!/usr/bin/env bash
# The data-layer / infra surface module -- the SINGLE source of truth for "does this changed
# path belong to the data layer?" and "...to the infra surface?". Issue #17.
#
# This suite is the QA-authored behavioral contract (Phase 3a). It is written BEFORE the
# implementation exists, so at authoring time every assertion below is RED. Each one fails on
# its own, with a message naming the missing BEHAVIOR, rather than through a shared setup that
# aborts the file: a suite that dies at line 1 reports one failure for forty missing
# properties, and Dev cannot tell which of them it has satisfied.
#
# WHAT DEV MUST PROVIDE FOR THIS SUITE TO GO GREEN
# ------------------------------------------------
# A module under plugins/pipeline/scripts/ exporting, per spec R1:
#   isMigrationPath(p, globs)        pure, normalizing, NARROW predicate (.md/.mdx excluded)
#   migrationGlobsForGate(cfg)       REPLACE semantics on migrationGlobs (+ extra union)
#   migrationGlobsForTripwire(cfg)   UNION of defaults with the guarded config
#   dataLayerGlobs(cfg)              BROAD glob set
#   isDataLayerPath(p) / diffTouchesDataLayer(paths)
#   isInfraPath(p)     / diffTouchesInfra(paths)
#
# The suite DISCOVERS that module by its `migrationGlobsForTripwire` export rather than by a
# filename QA guessed. The export NAMES are contract (R1, at SecOps' request: the names carry
# the union/replace difference that a later refactor would otherwise "simplify" away), the
# filename is Dev's to choose. If Dev has a reason the discovery rule cannot hold, raise it to
# QA -- do not edit the assertion to match the implementation.
#
# THE TWO ASYMMETRIES THIS SUITE EXISTS TO PIN (spec C1/C4). Both are deliberate and an
# implementer "making them consistent" is the likeliest defect in this change:
#   * migrationGlobs has TWO effective values. The TRIPWIRE's is a UNION with the built-in
#     defaults (config may only WIDEN a halting control). The GATE's REPLACES (config may
#     narrow, which is an already-tested shipped contract). Same key, opposite directions.
#   * The NARROW set carries a code-resident .md/.mdx exclusion; the BROAD set does not.
#
# Every fixture here is a path STRING or a file inside a `mktemp` scratch project. NOTHING is
# committed under a path the narrow set matches: verified at spec time that a committed
# `tests/fixtures/migrations/0001.sql` TRIPS the preset union, so the obvious fixture layout
# would make this repository halt on its own test data with no config escape (R5c).

. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
require_node

make_temp_project || exit 90

# ---- module discovery -------------------------------------------------------
# By contracted export, not by filename. Empty when nothing implements it yet, which is the
# state this contract is authored in; every assertion then fails with ERR:no-module.
DL_MODULE=""
for f in "$SCRIPTS_DIR"/*.mjs; do
  [[ -f "$f" ]] || continue
  if grep -q 'migrationGlobsForTripwire' "$f" 2>/dev/null; then DL_MODULE="$f"; break; fi
done

DRIVER="$TEMP_PROJECT/dl-driver.mjs"
cat > "$DRIVER" <<'EOF'
// Thin argv->export bridge, so the bash cases below read as behavior rather than as quoting.
// Every failure path prints an ERR: token on stdout and exits 0, so the bash assertion that
// wanted "true" reports `expected: true / actual: ERR:missing-export:isMigrationPath` -- the
// missing behavior names itself instead of hiding inside a node stack trace.
import { existsSync, readFileSync } from "node:fs";
import path from "node:path";

const out = (v) => console.log(String(v));
const modPath = process.env.DL_MODULE || "";
if (!modPath) { out("ERR:no-module-exports-migrationGlobsForTripwire"); process.exit(0); }

let mod;
try { mod = await import(modPath); }
catch (e) { out("ERR:import-failed:" + (e && e.message)); process.exit(0); }

function need(name) {
  if (typeof mod[name] !== "function") { out("ERR:missing-export:" + name); process.exit(0); }
  return mod[name];
}

// Config is read the way the module's own consumers read it: project root, unparseable or
// absent means {}. Mirrors frontend-surface.mjs's documented fallback, so a poisoned config
// fixture exercises the module's guards rather than crashing the harness.
let cfg = {};
try {
  const f = path.join(process.env.CLAUDE_PROJECT_DIR || process.cwd(), "pipeline.config.json");
  if (existsSync(f)) cfg = JSON.parse(readFileSync(f, "utf8"));
} catch { cfg = {}; }

const [cmd, a] = process.argv.slice(2);

if (cmd === "matrix") {
  // One node spawn per config fixture: prints TSV `path gate tripwire broad infra`.
  const isMig = need("isMigrationPath");
  const forGate = need("migrationGlobsForGate");
  const forTrip = need("migrationGlobsForTripwire");
  const isBroad = need("isDataLayerPath");
  const isInfra = need("isInfraPath");
  let gateGlobs, tripGlobs;
  try { gateGlobs = forGate(cfg); } catch (e) { out("ERR:migrationGlobsForGate-threw:" + e.message); process.exit(0); }
  try { tripGlobs = forTrip(cfg); } catch (e) { out("ERR:migrationGlobsForTripwire-threw:" + e.message); process.exit(0); }
  const paths = readFileSync(process.env.CORPUS_FILE, "utf8").split("\n").filter(Boolean);
  const cell = (fn) => { try { return String(fn()); } catch (e) { return "ERR:threw:" + e.message; } };
  const lines = paths.map((p) => [
    p,
    cell(() => isMig(p, gateGlobs)),
    cell(() => isMig(p, tripGlobs)),
    cell(() => isBroad(p)),
    cell(() => isInfra(p)),
  ].join("\t"));
  process.stdout.write(lines.join("\n") + "\n");
} else if (cmd === "globs") {
  const fn = need(a);
  try { out(JSON.stringify(fn(cfg))); } catch (e) { out("ERR:threw:" + e.message); }
} else if (cmd === "globs-nonstring") {
  // How many elements of the resolved set are NOT strings. Must be 0: globToRegExp(null)
  // THROWS, so one poisoned element left in the list takes the whole halt down with it.
  const fn = need(a);
  try {
    const v = fn(cfg);
    if (!Array.isArray(v)) { out("ERR:not-an-array:" + JSON.stringify(v)); }
    else out(v.filter((g) => typeof g !== "string").length);
  } catch (e) { out("ERR:threw:" + e.message); }
} else if (cmd === "narrow-with") {
  // Pure form: caller supplies the glob list, so a preset row can be deleted in the ARGUMENT
  // and the verdict watched changing -- the leave-one-out battery AC27 requires.
  const isMig = need("isMigrationPath");
  const [, globsJson, p] = process.argv.slice(2);
  try { out(isMig(p, JSON.parse(globsJson))); } catch (e) { out("ERR:threw:" + e.message); }
} else if (cmd === "touches-broad") {
  const fn = need("diffTouchesDataLayer");
  try { out(fn(JSON.parse(a))); } catch (e) { out("ERR:threw:" + e.message); }
} else if (cmd === "touches-infra") {
  const fn = need("diffTouchesInfra");
  try { out(fn(JSON.parse(a))); } catch (e) { out("ERR:threw:" + e.message); }
} else if (cmd === "touches-broad-undefined") {
  const fn = need("diffTouchesDataLayer");
  try { out(fn(undefined)); } catch (e) { out("ERR:threw:" + e.message); }
} else {
  console.error("unknown driver command");
  process.exit(2);
}
EOF

# ---- corpus -----------------------------------------------------------------
# The spec's AC3 corpus, the AC27 preset paths at BOTH the repo root and under an `apps/web/`
# monorepo prefix, the AC8/AC9 class paths, and the negative controls. One list, so every
# config fixture is evaluated over the same population and a path cannot be silently dropped
# from one table while surviving in another.
CORPUS="$TEMP_PROJECT/corpus.txt"
cat > "$CORPUS" <<'EOF'
migrations/0001.sql
db/migrations/0042.sql
supabase/migrations/x.sql
supabase/schemas/users.sql
apps/web/supabase/schemas/users.sql
db/migrate/20240101_add.rb
services/api/db/migrate/20240101_add.rb
alembic/versions/abc.py
prisma/schema.prisma
prisma/schema/user.prisma
apps/api/prisma/schema.prisma
src/generated/prisma/client.ts
src/generated/prisma/runtime/library.js
drizzle/0000_snapshot.sql
drizzle.config.ts
db/schema.ts
src/db/schema/users.ts
src/main/resources/db/migration/V1__init.sql
db/changelog/001-init.xml
Data/Migrations/20240101_Init.cs
supabase/policies/rls.sql
supabase/policies/rls.pgsql
db/policies/rls.sql
app/policies/post_policy.rb
db/queries/a.sql
packages/data/queries/foo.ts
packages/data/database.types.ts
packages/data/user.generated.types.ts
src/graphql/schema.ts
src/models/user.ts
src/entities/order.ts
src/x.ts
docs/readme.md
docs/migrations-guide.md
docs/migrations/guide.md
docs/migrations/upgrade-v2.md
docs/migrations/notes.txt
docs/migrations/diagram.png
website/content/docs/migrations/index.mdx
vendor/acme/migrations/0001.sql
tests/fixtures/migrations/0001.sql
app/migrations/0002_auto.py
database/migrations/2024_create.php
schema.sql
sql/tables.sql
db/changes/015.sql
migrations/016.sql
legacy/changes/015.sql
./db/migrations/0042.sql
services/api/deploy.config
deploy.sh
infra/prod.tf
services/api/infra/db.tf
.github/workflows/manifests.yml
deployment-notes.md
apps/web/db/migrate/20240101_add.rb
apps/web/app/migrations/0002_auto.py
apps/web/alembic/versions/abc.py
apps/web/prisma/schema.prisma
apps/web/prisma/schema/user.prisma
apps/web/drizzle/0000_snapshot.sql
apps/web/db/schema.ts
apps/web/src/db/schema/users.ts
apps/web/supabase/migrations/x.sql
apps/web/src/main/resources/db/migration/V1__init.sql
apps/web/db/changelog/001-init.xml
apps/web/Data/Migrations/20240101_Init.cs
apps/web/database/migrations/2024_create.php
apps/web/supabase/policies/rls.sql
apps/web/db/policies/rls.sql
apps/web/schema.sql
EOF

# new_root <name> [config-json] -> echoes the dir
new_root() {
  local dir="$TEMP_PROJECT/$1"
  mkdir -p "$dir"
  [[ $# -gt 1 ]] && printf '%s' "$2" > "$dir/pipeline.config.json"
  printf '%s' "$dir"
}

dl_run() {
  local pdir="$1"; shift
  ( cd "$pdir" && CLAUDE_PROJECT_DIR="$pdir" DL_MODULE="$DL_MODULE" CORPUS_FILE="$CORPUS" \
      node "$DRIVER" "$@" )
}

# ERR-guarded equality, for the assertions whose EXPECTED side is itself computed from the
# module ("these two resolvers agree", "this mutation changes nothing"). Plain equality passes
# when BOTH sides are the same error, which is a green over a module that does not exist --
# the same vacuity as an "every X is also Y" loop over an empty X.
assert_real_eq() {
  local name="$1" actual="$2" expected="$3"
  if [[ -z "$actual" || "$actual" == ERR:* || "$expected" == ERR:* ]]; then
    assert_eq "$name" "unusable value(s): actual=[$actual] expected=[$expected]" "two real, equal values"
    return
  fi
  assert_eq "$name" "$actual" "$expected"
}

# build_matrix <root-dir> <out-tsv>
build_matrix() { dl_run "$1" matrix > "$2" 2>&1; }

# matrix_error <tsv> -> echoes a reason when the file is not a usable matrix, else nothing.
# Without this, a driver that printed one ERR: line would make every "no violations found"
# loop below pass over an EMPTY population -- a vacuous green, which is the exact shape this
# repo's evidence rules forbid. Every consumer of the matrix routes through it.
matrix_error() {
  local f="$1" first
  [[ -s "$f" ]] || { printf 'matrix is empty'; return 0; }
  IFS= read -r first < "$f"
  case "$first" in
    *$'\t'*) : ;;
    *) printf 'matrix unusable: %s' "$first"; return 0 ;;
  esac
  local want have
  want=$(wc -l < "$CORPUS" | tr -d ' ')
  have=$(wc -l < "$f" | tr -d ' ')
  [[ "$want" == "$have" ]] || printf 'matrix has %s rows, corpus has %s' "$have" "$want"
}

# col <tsv> <path> <colnum: 2=gate 3=tripwire 4=broad 5=infra>
# Pure bash, deliberately not awk: one corpus path contains backslashes and `awk -v` would
# interpret them as escapes, turning a fixture into a different string than the one asserted.
col() {
  local f="$1" p="$2" c="$3" a b d e g err
  err=$(matrix_error "$f")
  [[ -z "$err" ]] || { printf '%s' "$err"; return 0; }
  while IFS=$'\t' read -r a b d e g; do
    [[ "$a" == "$p" ]] || continue
    case "$c" in 2) printf '%s' "$b";; 3) printf '%s' "$d";; 4) printf '%s' "$e";; 5) printf '%s' "$g";; esac
    return 0
  done < "$f"
  printf 'ERR:path-absent-from-matrix'
}

R_NONE=$(new_root cfg-none)
R_EMPTY=$(new_root cfg-empty '{"migrationGlobs":[]}')
R_CUSTOM=$(new_root cfg-custom '{"migrationGlobs":["db/changes/**"]}')
R_CUSTOM2=$(new_root cfg-custom2 '{"migrationGlobs":["legacy/changes/**"]}')
R_WRONG=$(new_root cfg-wrongtype '{"migrationGlobs":"db/**"}')
R_POISON=$(new_root cfg-poisoned '{"migrationGlobs":[null,123,{}]}')
R_EXTRA=$(new_root cfg-extra '{"extraMigrationGlobs":["sql/tables.sql"]}')
R_EXTRA_EMPTY=$(new_root cfg-extra-empty '{"extraMigrationGlobs":[]}')
R_CUSTOM_EXTRA=$(new_root cfg-custom-extra '{"migrationGlobs":["db/changes/**"],"extraMigrationGlobs":["sql/tables.sql"]}')
R_DL_EMPTY=$(new_root cfg-dl-empty '{"dataLayerGlobs":[]}')
R_INFRA_EMPTY=$(new_root cfg-infra-empty '{"infraGlobs":[]}')

M_NONE="$TEMP_PROJECT/m-none.tsv";         build_matrix "$R_NONE" "$M_NONE"
M_EMPTY="$TEMP_PROJECT/m-empty.tsv";       build_matrix "$R_EMPTY" "$M_EMPTY"
M_CUSTOM="$TEMP_PROJECT/m-custom.tsv";     build_matrix "$R_CUSTOM" "$M_CUSTOM"
M_CUSTOM2="$TEMP_PROJECT/m-custom2.tsv";   build_matrix "$R_CUSTOM2" "$M_CUSTOM2"
M_WRONG="$TEMP_PROJECT/m-wrong.tsv";       build_matrix "$R_WRONG" "$M_WRONG"
M_POISON="$TEMP_PROJECT/m-poison.tsv";     build_matrix "$R_POISON" "$M_POISON"
M_EXTRA="$TEMP_PROJECT/m-extra.tsv";       build_matrix "$R_EXTRA" "$M_EXTRA"
M_XEMPTY="$TEMP_PROJECT/m-xempty.tsv";     build_matrix "$R_EXTRA_EMPTY" "$M_XEMPTY"
M_CUSTX="$TEMP_PROJECT/m-custx.tsv";       build_matrix "$R_CUSTOM_EXTRA" "$M_CUSTX"
M_DLEMPTY="$TEMP_PROJECT/m-dlempty.tsv";   build_matrix "$R_DL_EMPTY" "$M_DLEMPTY"
M_INFEMPTY="$TEMP_PROJECT/m-infempty.tsv"; build_matrix "$R_INFRA_EMPTY" "$M_INFEMPTY"

# =============================================================================
# AC3 -- the DIVERGENCE CLASS, not one instance.
# =============================================================================
suite "AC3(a): the TRIPWIRE match set is a SUPERSET of the GATE's, under every config fixture"

# The mechanism, stated so the invariant is not a coincidence of this corpus: the tripwire set
# is literally defaults-UNION-config and the gate set is config-OR-defaults (plus the same
# extra union), so tripwire >= gate as SETS and the path-level superset follows. A fixture
# where they merely happen to agree proves nothing; {migrationGlobs:["db/changes/**"]} is the
# fixture where a naive shared resolver diverges.
superset_violations() { # <tsv> <subset-col> <superset-col>
  local f="$1" sub="$2" sup="$3" a b d e g v err
  local bad=""
  err=$(matrix_error "$f")
  [[ -z "$err" ]] || { printf '%s' "$err"; return 0; }
  while IFS=$'\t' read -r a b d e g; do
    case "$sub" in 2) v="$b";; 3) v="$d";; esac
    # A cell that is neither true nor false is a BROKEN cell, not an absent match. Counting it
    # as "not in the subset" would silently shrink the population the loop quantifies over.
    case "$v" in true) ;; false) continue ;; *) bad="$bad $a=$v"; continue ;; esac
    case "$sup" in 3) v="$d";; 4) v="$e";; esac
    [[ "$v" == "true" ]] || bad="$bad $a"
  done < "$f"
  printf '%s' "${bad# }"
}

assert_eq "no config: every gate match is also a tripwire match" "$(superset_violations "$M_NONE" 2 3)" ""
assert_eq "migrationGlobs []: every gate match is also a tripwire match" "$(superset_violations "$M_EMPTY" 2 3)" ""
assert_eq "migrationGlobs [db/changes/**]: every gate match is also a tripwire match" "$(superset_violations "$M_CUSTOM" 2 3)" ""
assert_eq "migrationGlobs wrong-type: every gate match is also a tripwire match" "$(superset_violations "$M_WRONG" 2 3)" ""
assert_eq "migrationGlobs [null,123,{}]: every gate match is also a tripwire match" "$(superset_violations "$M_POISON" 2 3)" ""
assert_eq "extraMigrationGlobs [sql/tables.sql]: every gate match is also a tripwire match" "$(superset_violations "$M_EXTRA" 2 3)" ""

# NON-ZERO CONTROL for the superset checks. An "every X is also Y" loop over an empty X set is
# vacuously green, which is the shape that lets a dead resolver report perfect compliance. The
# gate must be observed matching SOMETHING under the no-config fixture first.
gate_true_count() { local a b d e g n=0; while IFS=$'\t' read -r a b d e g; do [[ "$b" == "true" ]] && n=$((n+1)); done < "$1"; printf '%s' "$n"; }
assert_eq "non-zero control: the no-config GATE set is not empty (superset checks are not vacuous)" \
  "$([[ "$(gate_true_count "$M_NONE")" -gt 0 ]] && echo yes || echo no)" "yes"
assert_eq "non-zero control: the db/changes GATE set is not empty" \
  "$([[ "$(gate_true_count "$M_CUSTOM")" -gt 0 ]] && echo yes || echo no)" "yes"

suite "AC3(b): the BROAD panel predicate is a superset of the TRIPWIRE's, under the SAME config fixtures"

# Clause (b) carries the SAME fixtures as clause (a) deliberately (DBA M1). Under no-config
# both readings of "effective migrationGlobs" agree, so a no-config-only table would ship the
# defect: implementing dataLayerGlobs' default over migrationGlobsForGATE instead of
# ForTripwire diverges ONLY when migrationGlobs is set.
assert_eq "no config: every tripwire match is also a broad match" "$(superset_violations "$M_NONE" 3 4)" ""
assert_eq "migrationGlobs []: every tripwire match is also a broad match" "$(superset_violations "$M_EMPTY" 3 4)" ""
assert_eq "migrationGlobs [db/changes/**]: every tripwire match is also a broad match" "$(superset_violations "$M_CUSTOM" 3 4)" ""
assert_eq "migrationGlobs wrong-type: every tripwire match is also a broad match" "$(superset_violations "$M_WRONG" 3 4)" ""
assert_eq "migrationGlobs [null,123,{}]: every tripwire match is also a broad match" "$(superset_violations "$M_POISON" 3 4)" ""
assert_eq "extraMigrationGlobs [sql/tables.sql]: every tripwire match is also a broad match" "$(superset_violations "$M_EXTRA" 3 4)" ""

# The three paths DBA verified redden clause (b) under the ForGate misreading. Asserted BY NAME
# as well as by the loop, because a loop reports "one violation" and a name reports which cell.
assert_eq "AC3(b) named cell: Data/Migrations/20240101_Init.cs is broad under migrationGlobs=[db/changes/**]" \
  "$(col "$M_CUSTOM" 'Data/Migrations/20240101_Init.cs' 4)" "true"
assert_eq "AC3(b) named cell: alembic/versions/abc.py is broad under migrationGlobs=[db/changes/**]" \
  "$(col "$M_CUSTOM" 'alembic/versions/abc.py' 4)" "true"
assert_eq "AC3(b) named cell: supabase/schemas/users.sql is broad under migrationGlobs=[db/changes/**]" \
  "$(col "$M_CUSTOM" 'supabase/schemas/users.sql' 4)" "true"

suite "AC3(c): the tripwire-YES / broad-NO cell is PROVEN EMPTY, and the divergences that remain are recorded"

# "Proven empty" is the superset property itself; the loops above are its statement. What this
# block adds is the RECORD: each path where two predicates disagree, with its reason, so a
# divergence is a documented fact rather than something the corpus merely permits.
assert_eq "recorded divergence: db/queries/a.sql is BROAD-only (query layer, not a migration)" \
  "$(col "$M_NONE" 'db/queries/a.sql' 3)/$(col "$M_NONE" 'db/queries/a.sql' 4)" "false/true"
assert_eq "recorded divergence: src/graphql/schema.ts is BROAD-only (a bare **/schema.ts row in the narrow set would be un-narrowable)" \
  "$(col "$M_NONE" 'src/graphql/schema.ts' 3)/$(col "$M_NONE" 'src/graphql/schema.ts' 4)" "false/true"
assert_eq "recorded divergence: app/policies/post_policy.rb is BROAD-only (Pundit authorization is not a schema change)" \
  "$(col "$M_NONE" 'app/policies/post_policy.rb' 3)/$(col "$M_NONE" 'app/policies/post_policy.rb' 4)" "false/true"
assert_eq "recorded divergence: db/changes/015.sql is GATE+tripwire under a custom narrow config but not under no config" \
  "$(col "$M_NONE" 'db/changes/015.sql' 3)/$(col "$M_CUSTOM" 'db/changes/015.sql' 3)" "false/true"
assert_eq "recorded divergence: migrations/016.sql is tripwire-YES gate-NO under migrationGlobs=[db/changes/**] (this is the replace/union asymmetry)" \
  "$(col "$M_CUSTOM" 'migrations/016.sql' 2)/$(col "$M_CUSTOM" 'migrations/016.sql' 3)" "false/true"

# =============================================================================
# AC1 / AC2 -- the headline instances, asserted at the predicate level. Their end-to-end
# form (the diff actually halting the run) lives in test-mis-tier-tripwire.sh; both are
# needed, because a correct predicate wired into a shell shape that discards it is the exact
# pre-fix state this issue exists to remove.
# =============================================================================
suite "AC1/AC2: the paths that ship the production bug today"

assert_eq "AC1: db/migrations/0042.sql is a tripwire match (today's '^migrations/' literal misses it)" \
  "$(col "$M_NONE" 'db/migrations/0042.sql' 3)" "true"
assert_eq "AC2: supabase/migrations/x.sql is a tripwire match" \
  "$(col "$M_NONE" 'supabase/migrations/x.sql' 3)" "true"
assert_eq "AC2: supabase/migrations/x.sql is ALSO a broad match, so DBA is seated on the panel" \
  "$(col "$M_NONE" 'supabase/migrations/x.sql' 4)" "true"
assert_eq "AC4 (no-regression guard, KNOWN WEAK): db/migrations/0042.sql seats DBA" \
  "$(col "$M_NONE" 'db/migrations/0042.sql' 4)" "true"
# AC4 is the recorded EXPECTED SURVIVOR of this change's mutation battery: reverting the
# tripwire predicate to '^migrations/' -- the mutation that reproduces the headline production
# defect -- leaves this assertion GREEN, because panel composition already matched db/ and
# always did. Do NOT strengthen it. It is the proof that AC4 alone cannot see the bug, which
# is why AC1 (the instance) and AC3 (the class) exist. If it ever reddens under the tripwire
# mutation, the panel has been wired to the NARROW predicate by mistake -- fix the wiring.

suite "path normalization is the module's job, not the caller's"

assert_eq "a './' prefix is stripped before matching" "$(col "$M_NONE" './db/migrations/0042.sql' 3)" "true"
BACKSLASH_PATH='db\migrations\0042.sql'
assert_eq "backslash separators are normalized to '/'" \
  "$(dl_run "$R_NONE" narrow-with '["**/migrations/**"]' "$BACKSLASH_PATH")" "true"
assert_eq "a non-string path is false, not a throw" \
  "$(dl_run "$R_NONE" touches-broad '[null,123,{}]')" "false"
assert_eq "diffTouchesDataLayer(undefined) is false, not a throw" \
  "$(dl_run "$R_NONE" touches-broad-undefined)" "false"

# =============================================================================
# AC27 -- FRAMEWORK PRESETS. Every row asserted TWICE: at the repo root and under an
# `apps/web/` monorepo prefix. The rev-2 fixtures all sat at the root, so root-anchored rows
# would have shipped green while reopening the headline bug one directory deeper.
# =============================================================================
suite "AC27: every preset row fires at the repo ROOT"

assert_eq "Rails: db/migrate/20240101_add.rb"                       "$(col "$M_NONE" 'db/migrate/20240101_add.rb' 3)" "true"
assert_eq "Django: app/migrations/0002_auto.py"                     "$(col "$M_NONE" 'app/migrations/0002_auto.py' 3)" "true"
assert_eq "Alembic: alembic/versions/abc.py"                        "$(col "$M_NONE" 'alembic/versions/abc.py' 3)" "true"
assert_eq "Prisma single-file: prisma/schema.prisma"                "$(col "$M_NONE" 'prisma/schema.prisma' 3)" "true"
assert_eq "Prisma folder layout: prisma/schema/user.prisma"         "$(col "$M_NONE" 'prisma/schema/user.prisma' 3)" "true"
assert_eq "Drizzle output: drizzle/0000_snapshot.sql"               "$(col "$M_NONE" 'drizzle/0000_snapshot.sql' 3)" "true"
assert_eq "Drizzle schema: db/schema.ts"                            "$(col "$M_NONE" 'db/schema.ts' 3)" "true"
assert_eq "Drizzle multi-file schema: src/db/schema/users.ts"       "$(col "$M_NONE" 'src/db/schema/users.ts' 3)" "true"
assert_eq "Supabase migrations: supabase/migrations/x.sql"          "$(col "$M_NONE" 'supabase/migrations/x.sql' 3)" "true"
assert_eq "Supabase declarative: supabase/schemas/users.sql"        "$(col "$M_NONE" 'supabase/schemas/users.sql' 3)" "true"
assert_eq "Flyway: src/main/resources/db/migration/V1__init.sql"    "$(col "$M_NONE" 'src/main/resources/db/migration/V1__init.sql' 3)" "true"
assert_eq "Liquibase: db/changelog/001-init.xml"                    "$(col "$M_NONE" 'db/changelog/001-init.xml' 3)" "true"
assert_eq "EF Core (case-sensitive row): Data/Migrations/20240101_Init.cs" "$(col "$M_NONE" 'Data/Migrations/20240101_Init.cs' 3)" "true"
assert_eq "Laravel: database/migrations/2024_create.php"            "$(col "$M_NONE" 'database/migrations/2024_create.php' 3)" "true"
assert_eq "SQL policy source under supabase/: supabase/policies/rls.sql" "$(col "$M_NONE" 'supabase/policies/rls.sql' 3)" "true"
assert_eq "SQL policy source anywhere: db/policies/rls.sql"         "$(col "$M_NONE" 'db/policies/rls.sql' 3)" "true"
assert_eq "generic declarative dump: schema.sql"                    "$(col "$M_NONE" 'schema.sql' 3)" "true"
# The row '**/supabase/policies/**' is specified as covering RLS sources "regardless of
# extension", which no path in the spec's own fixture list exercises uniquely -- every listed
# policy path ends .sql and is therefore already covered by '**/policies/**.sql'. Without this
# case, deleting that row reddens NOTHING and the fifteen-row leave-one-out battery has a dead
# cell. Flagged to BA as a fixture-list gap rather than silently omitted.
assert_eq "non-.sql RLS source under supabase/ (the ONLY path that justifies the **/supabase/policies/** row on its own)" \
  "$(col "$M_NONE" 'supabase/policies/rls.pgsql' 3)" "true"

suite "AC27: every preset row fires again under an 'apps/web/' MONOREPO prefix"

assert_eq "Rails, prefixed"           "$(col "$M_NONE" 'apps/web/db/migrate/20240101_add.rb' 3)" "true"
assert_eq "Django, prefixed"          "$(col "$M_NONE" 'apps/web/app/migrations/0002_auto.py' 3)" "true"
assert_eq "Alembic, prefixed"         "$(col "$M_NONE" 'apps/web/alembic/versions/abc.py' 3)" "true"
assert_eq "Prisma single-file, prefixed" "$(col "$M_NONE" 'apps/web/prisma/schema.prisma' 3)" "true"
assert_eq "Prisma folder, prefixed"   "$(col "$M_NONE" 'apps/web/prisma/schema/user.prisma' 3)" "true"
assert_eq "Drizzle output, prefixed"  "$(col "$M_NONE" 'apps/web/drizzle/0000_snapshot.sql' 3)" "true"
assert_eq "Drizzle schema, prefixed"  "$(col "$M_NONE" 'apps/web/db/schema.ts' 3)" "true"
assert_eq "Drizzle multi-file, prefixed" "$(col "$M_NONE" 'apps/web/src/db/schema/users.ts' 3)" "true"
assert_eq "Supabase migrations, prefixed" "$(col "$M_NONE" 'apps/web/supabase/migrations/x.sql' 3)" "true"
assert_eq "Supabase declarative, prefixed" "$(col "$M_NONE" 'apps/web/supabase/schemas/users.sql' 3)" "true"
assert_eq "Flyway, prefixed"          "$(col "$M_NONE" 'apps/web/src/main/resources/db/migration/V1__init.sql' 3)" "true"
assert_eq "Liquibase, prefixed"       "$(col "$M_NONE" 'apps/web/db/changelog/001-init.xml' 3)" "true"
assert_eq "EF Core, prefixed"         "$(col "$M_NONE" 'apps/web/Data/Migrations/20240101_Init.cs' 3)" "true"
assert_eq "Laravel, prefixed"         "$(col "$M_NONE" 'apps/web/database/migrations/2024_create.php' 3)" "true"
assert_eq "supabase policy, prefixed" "$(col "$M_NONE" 'apps/web/supabase/policies/rls.sql' 3)" "true"
assert_eq "sql policy, prefixed"      "$(col "$M_NONE" 'apps/web/db/policies/rls.sql' 3)" "true"
assert_eq "generic dump, prefixed"    "$(col "$M_NONE" 'apps/web/schema.sql' 3)" "true"

suite "AC27: NEGATIVE CONTROLS -- each one is load-bearing for a specific defect"

assert_eq "src/graphql/schema.ts does NOT trip (a bare **/schema.ts narrow row would be un-narrowable)" \
  "$(col "$M_NONE" 'src/graphql/schema.ts' 3)" "false"
assert_eq "docs/migrations-guide.md matches nothing" "$(col "$M_NONE" 'docs/migrations-guide.md' 3)" "false"
assert_eq "app/policies/post_policy.rb does NOT trip (Pundit authorization is not a schema change)" \
  "$(col "$M_NONE" 'app/policies/post_policy.rb' 3)" "false"
assert_eq "src/generated/prisma/client.ts does NOT trip (the generated client is routinely committed)" \
  "$(col "$M_NONE" 'src/generated/prisma/client.ts' 3)" "false"
assert_eq "src/generated/prisma/runtime/library.js does NOT trip" \
  "$(col "$M_NONE" 'src/generated/prisma/runtime/library.js' 3)" "false"
assert_eq "docs/migrations/upgrade-v2.md does NOT trip (.md exclusion: a migration is never markdown)" \
  "$(col "$M_NONE" 'docs/migrations/upgrade-v2.md' 3)" "false"
assert_eq "website/content/docs/migrations/index.mdx does NOT trip (.mdx exclusion)" \
  "$(col "$M_NONE" 'website/content/docs/migrations/index.mdx' 3)" "false"
assert_eq "docs/migrations/guide.md does NOT trip" "$(col "$M_NONE" 'docs/migrations/guide.md' 3)" "false"
assert_eq "drizzle.config.ts does NOT trip (recorded residual RES-2, asserted so it is a fact and not an assumption)" \
  "$(col "$M_NONE" 'drizzle.config.ts' 3)" "false"
assert_eq "src/x.ts does NOT trip" "$(col "$M_NONE" 'src/x.ts' 3)" "false"

# The .md/.mdx exclusion is code-resident and NARROW-only. Asserted through the pure form as
# well, so the exclusion is proven to live in the PREDICATE rather than in an absent row: with
# '**/migrations/**' handed in explicitly, a .md path must still be refused.
assert_eq "the .md exclusion lives in the predicate, not in a missing glob row" \
  "$(dl_run "$R_NONE" narrow-with '["**/migrations/**"]' 'docs/migrations/upgrade-v2.md')" "false"
assert_eq "non-zero control for the .md exclusion: the SAME glob matches the same directory's .sql file" \
  "$(dl_run "$R_NONE" narrow-with '["**/migrations/**"]' 'docs/migrations/0001.sql')" "true"

# The exclusion is TWO EXTENSIONS, not a notion of "documentation", and the fixtures have to be
# able to tell those two readings apart. Without a non-.md docs path in the corpus, every
# fixture sat in the cell where the two readings agree, so the README could claim "a docs path
# under migrations/ does not halt" and no assertion could contradict it. These two can.
assert_eq "docs/migrations/notes.txt DOES trip: a .txt docs file is not excluded" \
  "$(col "$M_NONE" 'docs/migrations/notes.txt' 3)" "true"
assert_eq "docs/migrations/diagram.png DOES trip: nor is an image" \
  "$(col "$M_NONE" 'docs/migrations/diagram.png' 3)" "true"
assert_eq "and its .md sibling in the SAME directory does not, so the difference is the EXTENSION" \
  "$(col "$M_NONE" 'docs/migrations/upgrade-v2.md' 3)" "false"
assert_eq "the extension exclusion is exactly two entries, so the README cannot drift into claiming more" \
  "$(dl_run "$R_NONE" narrow-with '["**/migrations/**"]' 'docs/migrations/notes.txt')" "true"

suite "AC27 EXPECTED SURVIVOR: the redundant preset row changes no verdict"

# Re-adding '**/prisma/migrations/**' must change NOTHING, because it matches nothing
# '**/migrations/**' does not already match. This is the survivor that keeps the fifteen-row
# leave-one-out battery from being a rubber stamp: if EVERY glob mutation reddens something,
# the corpus is measuring breadth rather than coverage. If this assertion ever goes RED, the
# generic migrations row has been narrowed or removed -- investigate that, do not delete this.
assert_real_eq "survivor: adding the redundant row changes no verdict for apps/api/prisma/migrations/0001.sql" \
  "$(dl_run "$R_NONE" narrow-with '["**/migrations/**","**/prisma/migrations/**"]' 'apps/api/prisma/migrations/0001.sql')" \
  "$(dl_run "$R_NONE" narrow-with '["**/migrations/**"]' 'apps/api/prisma/migrations/0001.sql')"
assert_eq "survivor non-zero control: that path is a real MATCH, so the comparison is not two falses" \
  "$(dl_run "$R_NONE" narrow-with '["**/migrations/**"]' 'apps/api/prisma/migrations/0001.sql')" "true"
assert_eq "survivor: and the redundant row does not rescue the generated client either" \
  "$(dl_run "$R_NONE" narrow-with '["**/migrations/**","**/prisma/migrations/**"]' 'src/generated/prisma/client.ts')" "false"

# =============================================================================
# AC8 / AC9 -- the BROAD and INFRA sets, one asserted path per class.
# =============================================================================
suite "AC8: the broad predicate covers one path per class, and refuses the two excluded ones"

assert_eq "class 1 migration/schema source: db/migrations/0042.sql"    "$(col "$M_NONE" 'db/migrations/0042.sql' 4)" "true"
assert_eq "class 2 policy source: supabase/policies/rls.sql"           "$(col "$M_NONE" 'supabase/policies/rls.sql' 4)" "true"
assert_eq "class 2 declarative schema: prisma/schema.prisma"           "$(col "$M_NONE" 'prisma/schema.prisma' 4)" "true"
assert_eq "class 3 query layer: packages/data/queries/foo.ts"          "$(col "$M_NONE" 'packages/data/queries/foo.ts' 4)" "true"
assert_eq "class 4 generated DB types: packages/data/database.types.ts" "$(col "$M_NONE" 'packages/data/database.types.ts' 4)" "true"
assert_eq "class 4 generated DB types: packages/data/user.generated.types.ts" "$(col "$M_NONE" 'packages/data/user.generated.types.ts' 4)" "true"
assert_eq "broad-only path is seated: src/graphql/schema.ts"           "$(col "$M_NONE" 'src/graphql/schema.ts' 4)" "true"
assert_eq "broad-only path is seated: app/policies/post_policy.rb"     "$(col "$M_NONE" 'app/policies/post_policy.rb' 4)" "true"
assert_eq "deliberately excluded: src/models/user.ts (collides with view models)"  "$(col "$M_NONE" 'src/models/user.ts' 4)" "false"
assert_eq "deliberately excluded: src/entities/order.ts"               "$(col "$M_NONE" 'src/entities/order.ts' 4)" "false"
assert_eq "non-zero control: src/x.ts is not a data-layer path"        "$(col "$M_NONE" 'src/x.ts' 4)" "false"
assert_eq "diffTouchesDataLayer is true when ANY path in the diff qualifies" \
  "$(dl_run "$R_NONE" touches-broad '["src/x.ts","README.md","packages/data/queries/foo.ts"]')" "true"
assert_eq "diffTouchesDataLayer is false for a diff of only unrelated paths" \
  "$(dl_run "$R_NONE" touches-broad '["src/x.ts","README.md"]')" "false"

suite "AC9: the infra predicate is fixed in BOTH reported directions"

assert_eq "under-inclusion fixed: services/api/deploy.config (devops.md's own worked example)" \
  "$(col "$M_NONE" 'services/api/deploy.config' 5)" "true"
assert_eq "deploy.sh"                        "$(col "$M_NONE" 'deploy.sh' 5)" "true"
assert_eq "infra/prod.tf"                    "$(col "$M_NONE" 'infra/prod.tf' 5)" "true"
assert_eq "services/api/infra/db.tf"         "$(col "$M_NONE" 'services/api/infra/db.tf' 5)" "true"
assert_eq ".github/workflows/manifests.yml"  "$(col "$M_NONE" '.github/workflows/manifests.yml' 5)" "true"
assert_eq "over-inclusion fixed: deployment-notes.md is NOT infra (today's unanchored '^deploy' matches it)" \
  "$(col "$M_NONE" 'deployment-notes.md' 5)" "false"
assert_eq "non-zero control: src/x.ts is not infra" "$(col "$M_NONE" 'src/x.ts' 5)" "false"
assert_eq "diffTouchesInfra is true when ANY path qualifies" \
  "$(dl_run "$R_NONE" touches-infra '["src/x.ts","services/api/deploy.config"]')" "true"
assert_eq "diffTouchesInfra is false otherwise" \
  "$(dl_run "$R_NONE" touches-infra '["src/x.ts","deployment-notes.md"]')" "false"

# =============================================================================
# AC25 (predicate half) -- CONFIG MAY ONLY WIDEN THE TRIPWIRE, NEVER NARROW IT.
# The end-to-end half (the run actually halting) is in test-mis-tier-tripwire.sh.
# =============================================================================
suite "AC25: five config shapes, and the tripwire survives all five"

assert_eq "shape 1 {migrationGlobs:[]}: migrations/0001.sql still trips" \
  "$(col "$M_EMPTY" 'migrations/0001.sql' 3)" "true"
# LOAD-BEARING CELL, marked so a later trim cannot delete the only falsifying case and leave
# four green ones behind: this is the ONLY one of the five that reddens under the
# `cfg.length ? cfg : DEFAULTS` mutation (a fallback masquerading as a union). Verified 1 of 5.
assert_eq "shape 2 {migrationGlobs:[db/changes/**]}: supabase/migrations/x.sql still trips (LOAD-BEARING -- do not remove)" \
  "$(col "$M_CUSTOM" 'supabase/migrations/x.sql' 3)" "true"
assert_eq "shape 3 wrong-type migrationGlobs: db/migrations/0042.sql still trips" \
  "$(col "$M_WRONG" 'db/migrations/0042.sql' 3)" "true"
# The SECOND load-bearing cell, for a different mutation: dropping the
# `.filter(g => typeof g === "string")` element guard. globToRegExp(null) THROWS TypeError
# (verified), while 123/{}/[] compile harmlessly to /^$/ -- so this is the only shape that
# distinguishes a guarded union from an unguarded spread, and a thrown resolver is how the
# halt silently fails to fire.
assert_eq "shape 5 {migrationGlobs:[null,123,{}]}: db/migrations/0042.sql still trips (LOAD-BEARING -- do not remove)" \
  "$(col "$M_POISON" 'db/migrations/0042.sql' 3)" "true"
assert_eq "shape 5: the resolver returns an array and does not THROW on the poisoned config" \
  "$(dl_run "$R_POISON" globs migrationGlobsForTripwire | cut -c1)" "["
assert_eq "shape 5: every non-string element is DROPPED before compilation (globToRegExp(null) throws)" \
  "$(dl_run "$R_POISON" globs-nonstring migrationGlobsForTripwire)" "0"
assert_eq "shape 5: the same guard applies to the gate resolver" \
  "$(dl_run "$R_POISON" globs-nonstring migrationGlobsForGate)" "0"
assert_eq "shape 5: and to the broad resolver" \
  "$(dl_run "$R_POISON" globs-nonstring dataLayerGlobs)" "0"

# NON-ZERO CONTROL, mandatory: without it the criterion is satisfied by a predicate that
# returns true for every path.
assert_eq "control: src/x.ts does NOT trip under {migrationGlobs:[]}"        "$(col "$M_EMPTY" 'src/x.ts' 3)" "false"
assert_eq "control: src/x.ts does NOT trip under {migrationGlobs:[db/changes/**]}" "$(col "$M_CUSTOM" 'src/x.ts' 3)" "false"
assert_eq "control: src/x.ts does NOT trip under a wrong-type value"         "$(col "$M_WRONG" 'src/x.ts' 3)" "false"
assert_eq "control: src/x.ts does NOT trip under {migrationGlobs:[null,123,{}]}" "$(col "$M_POISON" 'src/x.ts' 3)" "false"
assert_eq "control: src/x.ts does NOT trip with no config"                   "$(col "$M_NONE" 'src/x.ts' 3)" "false"

suite "AC25: config WIDENS the tripwire, which is the only direction it may move it"

assert_eq "a configured narrow glob is honored ADDITIVELY: db/changes/015.sql trips" \
  "$(col "$M_CUSTOM" 'db/changes/015.sql' 3)" "true"
assert_eq "and the defaults it did not name still trip: db/migrate/20240101_add.rb" \
  "$(col "$M_CUSTOM" 'db/migrate/20240101_add.rb' 3)" "true"

# =============================================================================
# AC26 -- EMPTY MEANS DEFAULTS for the PANEL keys. The one key that keeps
# replace-to-nothing is migrationGlobs, and only on migrationGlobsForGate.
# =============================================================================
suite "AC26: an explicit [] must never mean 'seat nobody'"

assert_eq "{dataLayerGlobs:[]}: db/migrations/0042.sql still seats DBA" \
  "$(col "$M_DLEMPTY" 'db/migrations/0042.sql' 4)" "true"
assert_eq "{migrationGlobs:[]} and no dataLayerGlobs: packages/data/queries/foo.ts still seats DBA" \
  "$(col "$M_EMPTY" 'packages/data/queries/foo.ts' 4)" "true"
assert_eq "{infraGlobs:[]}: infra/prod.tf still seats DevOps" \
  "$(col "$M_INFEMPTY" 'infra/prod.tf' 5)" "true"
assert_eq "{extraMigrationGlobs:[]}: a preset path still trips" \
  "$(col "$M_XEMPTY" 'db/migrate/20240101_add.rb' 3)" "true"
assert_eq "non-zero control: docs/readme.md seats neither DBA..." "$(col "$M_DLEMPTY" 'docs/readme.md' 4)" "false"
assert_eq "...nor DevOps"                                        "$(col "$M_INFEMPTY" 'docs/readme.md' 5)" "false"
# The two guards are mutated SEPARATELY in the battery: a shared length>0 helper with one
# caller omitted survives a single combined test.
assert_eq "the dataLayerGlobs guard is asserted on its own key"  "$(col "$M_DLEMPTY" 'packages/data/queries/foo.ts' 4)" "true"
assert_eq "the infraGlobs guard is asserted on its own key"      "$(col "$M_INFEMPTY" 'services/api/deploy.config' 5)" "true"

# =============================================================================
# AC7 -- upgrade safety: an existing adopter's migrationGlobs widens the BROAD predicate
# automatically, with no dataLayerGlobs configured.
# =============================================================================
suite "AC7: a configured narrow glob widens the panel predicate too"

assert_eq "db/changes/015.sql seats DBA under {migrationGlobs:[db/changes/**]} with no dataLayerGlobs" \
  "$(col "$M_CUSTOM" 'db/changes/015.sql' 4)" "true"
# The obvious control -- "and db/changes/015.sql does NOT seat DBA with no config" -- is a
# MASKED control and was observed passing for the wrong reason against a reference
# implementation: the broad set's own '**/db/**' row already seats any path under any db/
# directory (recorded residual RES-6), so that assertion would be green whether or not the
# configured glob fed the broad predicate at all. The control therefore uses a path OUTSIDE
# db/, where the configured glob is the ONLY thing that can seat DBA.
assert_eq "legacy/changes/015.sql seats DBA under {migrationGlobs:[legacy/changes/**]}" \
  "$(col "$M_CUSTOM2" 'legacy/changes/015.sql' 4)" "true"
assert_eq "non-zero control: legacy/changes/015.sql does NOT seat DBA with no config at all" \
  "$(col "$M_NONE" 'legacy/changes/015.sql' 4)" "false"
assert_eq "and RES-6 is asserted as a recorded FACT, not left as an assumption: '**/db/**' seats DBA on any db/ path" \
  "$(col "$M_NONE" 'db/changes/015.sql' 4)" "true"

# =============================================================================
# AC40 -- extraMigrationGlobs UNIONS EVERYWHERE and NEVER replaces.
# =============================================================================
suite "AC40: extraMigrationGlobs widens all three resolvers"

assert_eq "sql/tables.sql trips the tripwire"        "$(col "$M_EXTRA" 'sql/tables.sql' 3)" "true"
assert_eq "sql/tables.sql is discovered by the gate" "$(col "$M_EXTRA" 'sql/tables.sql' 2)" "true"
assert_eq "sql/tables.sql seats DBA on the panel"    "$(col "$M_EXTRA" 'sql/tables.sql' 4)" "true"
assert_eq "and every default preset path still trips"      "$(col "$M_EXTRA" 'db/migrate/20240101_add.rb' 3)" "true"
assert_eq "and every default preset path is still discovered by the gate" "$(col "$M_EXTRA" 'db/migrate/20240101_add.rb' 2)" "true"
assert_eq "and every default preset path still seats DBA"  "$(col "$M_EXTRA" 'db/migrate/20240101_add.rb' 4)" "true"

suite "AC40: with BOTH keys set, replace still applies to migrationGlobs ALONE"

assert_eq "the GATE discovers db/changes/015.sql"  "$(col "$M_CUSTX" 'db/changes/015.sql' 2)" "true"
assert_eq "the GATE discovers sql/tables.sql"      "$(col "$M_CUSTX" 'sql/tables.sql' 2)" "true"
assert_eq "the GATE does NOT discover migrations/016.sql -- migrationGlobs REPLACED the defaults" \
  "$(col "$M_CUSTX" 'migrations/016.sql' 2)" "false"
assert_eq "the TRIPWIRE fires for db/changes/015.sql" "$(col "$M_CUSTX" 'db/changes/015.sql' 3)" "true"
assert_eq "the TRIPWIRE fires for sql/tables.sql"     "$(col "$M_CUSTX" 'sql/tables.sql' 3)" "true"
assert_eq "the TRIPWIRE fires for migrations/016.sql -- the union is what makes it un-narrowable" \
  "$(col "$M_CUSTX" 'migrations/016.sql' 3)" "true"

suite "AC40 non-zero control: an absent or empty extraMigrationGlobs is byte-identical to the defaults"

assert_real_eq "absent vs []: the gate resolver returns the same set" \
  "$(dl_run "$R_NONE" globs migrationGlobsForGate)" "$(dl_run "$R_EXTRA_EMPTY" globs migrationGlobsForGate)"
assert_real_eq "absent vs []: the tripwire resolver returns the same set" \
  "$(dl_run "$R_NONE" globs migrationGlobsForTripwire)" "$(dl_run "$R_EXTRA_EMPTY" globs migrationGlobsForTripwire)"
assert_real_eq "absent vs []: the broad resolver returns the same set" \
  "$(dl_run "$R_NONE" globs dataLayerGlobs)" "$(dl_run "$R_EXTRA_EMPTY" globs dataLayerGlobs)"
# This is the control that proves the key is ADDITIVE rather than a new default -- and it is
# what keeps tests/test-gate-pre-phase4.sh green unmodified in its entirety (AC6), since no
# shipped test sets the key.
assert_eq "sql/tables.sql does NOT trip when the key is absent" "$(col "$M_NONE" 'sql/tables.sql' 3)" "false"

# =============================================================================
# The GATE keeps its shipped REPLACE contract. AC6 pins tests/test-gate-pre-phase4.sh
# unmodified in its entirety; this block asserts the same property at the resolver, so a
# regression names the resolver rather than surfacing as a distant gate failure.
# =============================================================================
suite "the gate resolver keeps REPLACE semantics (the shipped, tested contract)"

assert_eq "a custom glob matches ONLY what it names: migrations/016.sql is not discovered" \
  "$(col "$M_CUSTOM" 'migrations/016.sql' 2)" "false"
assert_eq "an explicit [] on migrationGlobs replaces to nothing at the GATE: db/migrations/0042.sql not discovered" \
  "$(col "$M_EMPTY" 'db/migrations/0042.sql' 2)" "false"
assert_eq "...while the SAME path still trips the TRIPWIRE under the SAME config (the asymmetry, in one line)" \
  "$(col "$M_EMPTY" 'db/migrations/0042.sql' 3)" "true"
assert_eq "a wrong-typed value falls back to the defaults at the gate" \
  "$(col "$M_WRONG" 'db/migrations/0042.sql' 2)" "true"

finish
