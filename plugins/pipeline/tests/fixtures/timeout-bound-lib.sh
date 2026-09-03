#!/usr/bin/env bash
# Shared fixture for the two #132 PreToolUse-timeout suites. SOURCED, never run: it lives under
# fixtures/ so run.sh's flat `test-*.sh` glob does not pick it up as a suite.
#
# ---------------------------------------------------------------------------------------------
# WHAT THIS FILE IS FOR, AND THE ONE THING IT REFUSES TO DO.
#
# #132 raises the PreToolUse hook's declared `timeout` out of a value the gate demonstrably
# outruns. Almost every criterion in that spec is a statement about a MEASUREMENT and about the
# corpus the measurement was taken over, so the fixture's job is to make both reproducible:
#
#   * tb_materialize        -- AC1's corpus: the tracked content of the tree under test, laid out
#                             in a directory with NO .git, so that any rule expressed in git
#                             (`git check-ignore`, `git ls-files`) reports NOTHING there rather
#                             than silently reporting the checkout's answer.
#   * tb_struct_class       -- the hook's OWN structural-character set, obtained by EVALUATING
#                             pre-tool-use.sh's `_STRUCT=` line, never by reading its source text.
#   * tb_struct_count       -- bytes-per-structural-character over that class.
#   * tb_enumerate_*        -- a content-only enumeration of a materialized tree.
#
# THE ONE THING IT REFUSES: it holds no second copy of the structural class. `_STRUCT` is assigned
# from a DOUBLE-QUOTED shell string that opens with the variable reference `$_NL` and carries a
# deliberately DOUBLED backslash (pre-tool-use.sh:1183-1190 documents at length why the doubling is
# load-bearing). Reading that line AS TEXT and using it as a character class yields a FIFTEEN
# member set: it ADDS `$`, `_`, `N` and `L`, and it LOSES the newline, which is the most frequent
# structural character in every file in the population. Measured at 62d7a17, the consequence is not
# cosmetic: plugins/pipeline/schemas/impl-report.schema.json reads 8.38 B/struct and ranks 2nd
# densest of the 159 tracked files at or above 2000 bytes under the evaluated 12-character set, and
# 11.44 B/struct at rank 47 under the source-text set. A density ranking built on the source text
# therefore never selects the densest end of the corpus at all.
# ---------------------------------------------------------------------------------------------

TB_FIXTURES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TB_TESTS_DIR="$(cd "$TB_FIXTURES_DIR/.." && pwd)"
TB_PLUGIN_DIR="$(cd "$TB_TESTS_DIR/.." && pwd)"
TB_REPO_ROOT="$(cd "$TB_PLUGIN_DIR/../.." && pwd)"

TB_REAL_NODE="$(command -v node 2>/dev/null || true)"

TB_MAT_SHA=""
TB_MAT_ERR=""

# ---- AC1: the corpus, materialized from the tree under test ------------------------------------
#
# tb_materialize <destdir> -> 0 on success, non-zero with TB_MAT_ERR set otherwise.
#
# The SOURCE is the working tree's tracked content, not `HEAD`, because Phase 3 runs this suite
# against a tree Dev has edited and an assertion evaluated against HEAD would be measuring the
# commit BEFORE the change on every run but the last. `git stash create` writes a commit object
# for the working tree without touching the index, the worktree or the stash ref; on a clean tree
# it prints nothing and HEAD is the right answer. Either way the sha is RECORDED, so a transcript
# says which tree the figures below were taken over.
tb_materialize() {
  local dest="$1" sha=""
  TB_MAT_ERR=""
  [[ -n "$dest" && -d "$dest" ]] || { TB_MAT_ERR="destination is not a directory: [$dest]"; return 1; }
  sha="$(git -C "$TB_REPO_ROOT" stash create 2>/dev/null | tr -d ' \n')"
  if [[ -z "$sha" ]]; then
    sha="$(git -C "$TB_REPO_ROOT" rev-parse HEAD 2>/dev/null | tr -d ' \n')"
  fi
  [[ -n "$sha" ]] || { TB_MAT_ERR="no sha: neither \`git stash create\` nor \`git rev-parse HEAD\` answered"; return 1; }
  git -C "$TB_REPO_ROOT" archive "$sha" 2>/dev/null | ( cd "$dest" && tar xf - ) || {
    TB_MAT_ERR="git archive $sha | tar x failed into $dest"; return 1; }
  TB_MAT_SHA="$sha"
  return 0
}

# tb_mat_file_count <root> -> how many regular files the materialized tree holds.
tb_mat_file_count() {
  find "$1" -type f 2>/dev/null | grep -c . | tr -d ' \n'
}

# ---- the hook's own structural class ------------------------------------------------------------
#
# tb_struct_assign_lines <pre-tool-use.sh> -> every line assigning _STRUCT, one per line.
# The caller asserts there is EXACTLY ONE. Two matches or zero must fail the suite rather than
# fall back to the first, because the fallback is what turns a refactor into a plausible wrong
# number instead of a loud red. A red here means THE HOOK'S SET MOVED SHAPE (e.g. it was rewritten
# as a concatenation, which is the shape `_DELIMS` immediately below it already uses); it does NOT
# mean the density figures are wrong.
tb_struct_assign_lines() {
  grep '^_STRUCT=' "$1" 2>/dev/null
}

# tb_struct_class <pre-tool-use.sh> -> the VALUE of _STRUCT, evaluated the way the hook computes
# it, with $_NL bound to a newline. Prints nothing when the extraction is not unique.
tb_struct_class() {
  local src="$1" line n
  n="$(tb_struct_assign_lines "$src" | grep -c . | tr -d ' \n')"
  [[ "$n" == "1" ]] || return 1
  line="$(tb_struct_assign_lines "$src")"
  (
    _NL='
'
    eval "$line" || exit 1
    printf '%s' "$_STRUCT"
  )
}

# tb_struct_distinct <class> -> the number of DISTINCT characters in the class.
# `_STRUCT`'s value is 13 bytes and 12 distinct characters, because the backslash appears twice:
# the string is re-read AS A BRACKET PATTERN (`[$_STRUCT]`) where `\\` is one escaped backslash
# and therefore one member.
tb_struct_distinct() {
  TB_CLASS="$1" "$TB_REAL_NODE" -e '
    const s = process.env.TB_CLASS || "";
    process.stdout.write(String(new Set(Array.from(s)).size));
  ' 2>/dev/null
}

# tb_struct_has <class> <one-character> -> "yes" | "no"
tb_struct_has() {
  TB_CLASS="$1" TB_CH="$2" "$TB_REAL_NODE" -e '
    const s = new Set(Array.from(process.env.TB_CLASS || ""));
    process.stdout.write(s.has(process.env.TB_CH) ? "yes" : "no");
  ' 2>/dev/null
}

# tb_density <class> <file> -> "<bytes> <structural-chars> <bytes-per-struct, 2dp>"
# Counted over BYTES (latin1), because "bytes per structural character" is a byte figure and every
# member of the class is ASCII; decoding as UTF-8 would make a multi-byte character count as one.
tb_density() {
  TB_CLASS="$1" "$TB_REAL_NODE" -e '
    const fs = require("node:fs");
    const set = new Set(Array.from(process.env.TB_CLASS || ""));
    let b; try { b = fs.readFileSync(process.argv[1]); } catch { process.stdout.write("0 0 0.00"); process.exit(0); }
    const s = b.toString("latin1");
    let n = 0; for (const ch of s) if (set.has(ch)) n++;
    process.stdout.write(b.length + " " + n + " " + (n ? (b.length / n).toFixed(2) : "0.00"));
  ' "$2" 2>/dev/null
}

# ---- the population, enumerated from a materialized tree ----------------------------------------
#
# CONTENT-ONLY AND EXTENSION-OPEN, and both halves are load-bearing.
#
# CONTENT-ONLY: inside a `git archive | tar x` tree there is no `.git`, so `git rev-parse` and
# `git check-ignore` exit 128. A population rule expressed in git therefore enumerates ZERO there
# and reports a clean scan -- and that tree is the one AC1 mandates, which is the tree CI runs
# against, so the failure is not hypothetical.
#
# EXTENSION-OPEN: at 62d7a17 the densest tracked file at or above 2000 bytes is NOT a `.json`. It
# is plugins/pipeline/tests/test-frontend-surface.sh at 8.30 B/struct, ahead of
# plugins/pipeline/schemas/impl-report.schema.json at 8.38; ranks 3 and 4 are also `.sh`. A rule
# restricted to `.json` is already selecting the wrong rank-1 density row.
#
# tb_enumerate <root> <floor-bytes> -> one line per file: "<bytes>\t<relative-path>"
tb_enumerate() {
  local root="$1" floor="$2"
  ( cd "$root" 2>/dev/null || exit 0
    find . -type f -size +$(( floor - 1 ))c 2>/dev/null |
      while IFS= read -r f; do
        printf '%s\t%s\n' "$(wc -c < "$f" | tr -d ' ')" "${f#./}"
      done
  )
}

# tb_enumerate_count <root> <floor-bytes>
tb_enumerate_count() {
  tb_enumerate "$1" "$2" | grep -c . | tr -d ' \n'
}

# ---- reading numbers out of prose ----------------------------------------------------------------
#
# tb_numbers <text> <unit-regex> -> every integer immediately preceding the unit, one per line.
tb_numbers() {
  printf '%s' "$1" | grep -oE "[0-9][0-9,._]*[[:space:]]*(${2})" | grep -oE '^[0-9][0-9,._]*' |
    tr -d ',' | sed 's/\.$//'
}

# tb_min3 <a> <b> <c> -> the smallest. Integer only.
tb_min3() {
  local m="$1"
  [[ "$2" -lt "$m" ]] && m="$2"
  [[ "$3" -lt "$m" ]] && m="$3"
  printf '%s' "$m"
}

# tb_loadavg -> the 1-minute load average, or "unknown". RECORDED beside every timing figure,
# because a millisecond number without the load it was taken under is not re-takeable.
tb_loadavg() {
  uptime 2>/dev/null | sed -n 's/.*load averages\{0,1\}:[[:space:]]*\([0-9.,]*\).*/\1/p' | tr -d ' ' |
    grep -E '^[0-9]' || printf 'unknown'
}

# ---- payloads whose command is too large for argv ------------------------------------------------
#
# tb_payload_file <command-file> <cwd> [key=value ...] -> the payload JSON on stdout.
#
# WHY THIS EXISTS BESIDE gate_payload. The shared helper passes the command as a node ARGV, which is
# the right shape for every fixture in the #106 suites. AC11's fail-open pair is not one of them: it
# has to build a command LARGER than the gate can decide inside the declared timeout, and at the
# raised bound that is megabytes. MEASURED: a 3,111,437-byte command handed to the argv builder made
# the exec fail, the payload came back EMPTY, and the gate returned `none` in 352 ms -- a fixture
# reporting an ALLOW for a gate that was working, which is the exact reading AC11's arm one exists to
# refuse. Reading the command from a FILE has no such ceiling. The payload SHAPE is the same one
# fixtures/pretooluse-payload.mjs builds (Claude Code 2.1.85: hook_event_name, session_id,
# tool_name, tool_input.command, agent_id present only for a subagent-originated call), and `cwd` is
# REQUIRED here for the same reason it is required there.
tb_payload_file() {
  local cmdfile="$1" cwd="$2"; shift 2
  [[ -n "$cwd" ]] || { printf 'tb_payload_file: a cwd is required and is never inferred\n' >&2; return 2; }
  TB_CMD_FILE="$cmdfile" "$TB_REAL_NODE" -e '
    const fs = require("node:fs");
    const cmd = fs.readFileSync(process.env.TB_CMD_FILE, "utf8");
    const payload = {
      hook_event_name: "PreToolUse",
      session_id: "qa-132-contract",
      transcript_path: "/dev/null",
      cwd: process.argv[1],
      tool_name: "Bash",
      tool_input: { command: cmd },
    };
    for (const kv of process.argv.slice(2)) {
      const i = kv.indexOf("=");
      if (i < 0) continue;
      payload[kv.slice(0, i)] = kv.slice(i + 1);
    }
    process.stdout.write(JSON.stringify(payload));
  ' "$cwd" "$@"
}

# tb_rank <class> <root> <floor-bytes> -> "<bytes>\t<struct>\t<B-per-struct>\t<relative-path>" for
# every file at or above the floor, ranked DENSEST FIRST.
#
# ONE node process for the whole tree, not one per file. The obvious spelling -- a shell loop
# calling tb_density per path -- spawns a node start per row, and at 159 rows that is about twenty
# seconds of a suite whose whole point is to measure something else. The enumeration itself stays
# content-only: `find -size`, no git, no extension filter.
tb_rank() {
  local class="$1" root="$2" floor="$3"
  TB_CLASS="$class" "$TB_REAL_NODE" -e '
    const fs = require("node:fs"), path = require("node:path");
    const root = process.argv[1], floor = Number(process.argv[2]);
    const set = new Set(Array.from(process.env.TB_CLASS || ""));
    const rows = [];
    const walk = (d) => {
      let ents; try { ents = fs.readdirSync(d, { withFileTypes: true }); } catch { return; }
      for (const e of ents) {
        const p = path.join(d, e.name);
        if (e.isDirectory()) { walk(p); continue; }
        if (!e.isFile()) continue;
        let b; try { b = fs.readFileSync(p); } catch { continue; }
        if (b.length < floor) continue;
        const s = b.toString("latin1");
        let n = 0; for (const ch of s) if (set.has(ch)) n++;
        rows.push([b.length, n, n ? b.length / n : Infinity, path.relative(root, p)]);
      }
    };
    walk(root);
    rows.sort((a, b) => a[2] - b[2]);
    process.stdout.write(rows.map((r) => r[0] + "\t" + r[1] + "\t" + (Number.isFinite(r[2]) ? r[2].toFixed(2) : "inf") + "\t" + r[3]).join("\n"));
  ' "$root" "$floor" 2>/dev/null
}
