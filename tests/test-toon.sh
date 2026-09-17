#!/usr/bin/env bash
# toon.mjs (C2): the TOON encoder used for data in agent prompts. Artifacts stay JSON; this pins the
# encoded SHAPES a prompt relies on (tabular header, inline list, list items), the quoting rules
# that keep a cell from reading as a number, boolean, null, a second field or a key, and a round
# trip through the test-aid decoder for the subset the renderers emit.
#
# WHY THE CASES ARE A PLAIN TABLE AND NOT ONE assert_eq PER LINE. The first version of this file
# spelled every case as its own shell call with nested single and double quotes around JSON. That
# made it the most punctuation-dense tracked file in the repo, and the PreToolUse timeout-bound
# suite builds its worst-case command body from exactly that file, so a test file changed a gate
# measurement recorded in CHANGELOG item 27. The table below carries the same cases with far less
# shell quoting: one case per line, tab separated, in a quoted heredoc that the shell never parses.
#
# Table format, one case per line, three fields separated by a TAB:
#   label      what the case pins, in words
#   input      a JavaScript expression for the value to encode (and options, see below)
#   expected   the exact encoding, with the pilcrow character standing for a line break
# An input of the form  VALUE ;; OPTIONS  passes OPTIONS as the second argument of encode.

. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
require_node

TOON="$SCRIPTS_DIR/toon.mjs"
make_temp_project || exit 90
CASES="$TEMP_PROJECT/cases.tsv"

cat > "$CASES" <<'EOF'
a uniform array of objects is ONE header plus one row per item	{items:[{id:"qa-1",severity:"high",merge_class:"wrong-pass"},{id:"qa-2",severity:"nit",merge_class:"none"}]}	items[2]{id,severity,merge_class}:¶  qa-1,high,wrong-pass¶  qa-2,nit,none
an array of primitives is inline with its length	{tags:["a","b","c"]}	tags[3]: a,b,c
an empty array still carries its length	{tags:[]}	tags[0]:
nested objects indent two spaces	{a:{b:{c:1}},d:true}	a:¶  b:¶    c: 1¶d: true
objects whose keys differ are NOT tabular and become list items	{xs:[{a:1},{b:2,c:3}]}	xs[2]:¶  - a: 1¶  - b: 2¶    c: 3
an object with a nested value is NOT tabular	{xs:[{a:1,b:{c:2}}]}	xs[1]:¶  - a: 1¶    b:¶      c: 2
a mixed array lists primitives, arrays and objects	{xs:[1,[2,3],{k:"v"}]}	xs[3]:¶  - 1¶  - [2]: 2,3¶  - k: v
a root table has no key	[{a:1,b:2},{a:3,b:4}]	[2]{a,b}:¶  1,2¶  3,4
a root primitive is itself	"plain"	plain
a pipe delimiter is declared in the header	{r:[{a:"x,y",b:1}]} ;; {delimiter:"|"}	r[1|]{a|b}:¶  x,y|1
a plain string is bare	{v:"hello world"}	v: hello world
a string containing the delimiter is quoted	{t:["a,b","c"]}	t[2]: "a,b",c
a string containing a colon-space is quoted	{v:"key: value"}	v: "key: value"
any colon is quoted, the spec rule the module header records	{v:"2026-01-01T00:00:00Z"}	v: "2026-01-01T00:00:00Z"
leading space is quoted	{v:" pad"}	v: " pad"
trailing space is quoted	{v:"pad "}	v: "pad "
a newline is quoted and escaped	{v:"a" + String.fromCharCode(10) + "b"}	v: "a\nb"
a tab and a carriage return are escaped	{v:"a" + String.fromCharCode(9) + "b" + String.fromCharCode(13) + "c"}	v: "a\tb\rc"
a double quote and a backslash are escaped	{v:String.fromCharCode(34) + "hi" + String.fromCharCode(92)}	v: "\"hi\\"
a number-looking string is quoted	{v:"42"}	v: "42"
a decimal-looking string is quoted	{v:"-3.5"}	v: "-3.5"
an exponent-looking string is quoted	{v:"1e5"}	v: "1e5"
a leading-zero string is quoted	{v:"05"}	v: "05"
CONTROL: a sha that merely starts with a digit is bare	{v:"0123abc"}	v: 0123abc
true as a string is quoted	{v:"true"}	v: "true"
null as a string is quoted	{v:"null"}	v: "null"
CONTROL: real booleans and null are bare	{a:true,b:null}	a: true¶b: null
the empty string is quoted	{v:""}	v: ""
a leading hyphen is quoted, it would read as a list item	{v:"- item"}	v: "- item"
brackets are quoted	{v:"a[1]"}	v: "a[1]"
a key that is not an identifier is quoted	{"a b":1,"x-y":2}	"a b": 1¶"x-y": 2
a large number prints without an exponent	{v:1e21}	v: 1000000000000000000000
a small number prints without an exponent	{v:1.5e-7}	v: 0.00000015
minus zero prints as 0 and NaN as null	{a:-0,b:NaN}	a: 0¶b: null
a table cell with a comma is quoted, its neighbours are not	{r:[{a:"x, y",b:"z"}]}	r[1]{a,b}:¶  "x, y",z
EOF

# One node process runs every case and prints one line per case: the verdict, a tab, the label.
# A mismatch line also carries what the encoder produced, so a red row names the actual output.
RESULTS="$(MOD="$TOON" CASES="$CASES" node --input-type=module -e '
import { readFileSync } from "node:fs";
const m = await import(process.env.MOD);
for (const line of readFileSync(process.env.CASES, "utf8").split("\n")) {
  if (!line.trim()) continue;
  const [label, input, expected] = line.split("\t");
  const [valueSrc, optsSrc] = input.split(" ;; ");
  let got;
  try {
    got = m.encode(eval("(" + valueSrc + ")"), optsSrc ? eval("(" + optsSrc + ")") : undefined);
  } catch (e) {
    got = "THREW " + e.message;
  }
  const want = expected.split("¶").join("\n");
  console.log((got === want ? "match" : "MISMATCH got " + JSON.stringify(got)) + "\t" + label);
}
')"

suite "toon: shapes and quoting, from the case table"

CASE_COUNT="$(grep -c . "$CASES" | tr -d ' ')"
assert_eq "VACUITY: every case in the table produced a result line" "$(printf '%s\n' "$RESULTS" | grep -c . | tr -d ' ')" "$CASE_COUNT"
while IFS=$'\t' read -r verdict label; do
  [[ -n "$label" ]] || continue
  assert_eq "$label" "$verdict" "match"
done <<< "$RESULTS"

suite "toon: round trip through the test-aid decoder (tabular subset)"

# Each case is encoded, decoded and compared as JSON. The controls prove the comparison can fail:
# a declared length that disagrees with the rows is refused, and a tampered cell does not match.
RT="$(MOD="$TOON" node --input-type=module -e '
const m = await import(process.env.MOD);
const nl = String.fromCharCode(10), tab = String.fromCharCode(9), dq = String.fromCharCode(34), bs = String.fromCharCode(92);
const cases = [
  { items: [{ id: "qa-1", severity: "high", n: 3, ok: true, loc: null }, { id: "qa-2", severity: "a,b", n: -1.25, ok: false, loc: "f.mjs:10" }] },
  { tags: ["x", "05", "true", " sp", "line" + nl + "break", "q" + dq + "b" + bs + "s"], nested: { deep: { v: "1e5" } }, empty: {}, none: [] },
  [{ a: "", b: "-" }, { a: "tab" + tab + "here", b: "{x}" }],
  { list: ["a", "b c"] },
];
const same = (c) => JSON.stringify(m.decode(m.encode(c))) === JSON.stringify(c);
const bad = cases.map((c, i) => (same(c) ? null : i)).filter((i) => i !== null);
let refused = "accepted";
try { m.decode("t[3]{a}:" + nl + "  1" + nl + "  2"); } catch { refused = "refused"; }
const tampered = JSON.stringify(m.decode(m.encode({ t: [{ a: "x" }] }).replace("x", "y"))) === JSON.stringify({ t: [{ a: "x" }] });
console.log((bad.length ? "mismatch " + bad.join(",") : "all-equal") + " " + refused + " " + (tampered ? "tamper-equal" : "tamper-differs"));
')"
assert_contains "encode then decode returns the same JSON for every subset case" "$RT" "all-equal"
assert_contains "CONTROL: the decoder refuses a table whose declared length is wrong" "$RT" "refused"
assert_contains "CONTROL: a tampered cell does not round-trip equal" "$RT" "tamper-differs"

suite "toon: CLI"

printf '%s' '{"spec":{"acceptance_criteria":[{"id":"AC1","text":"works"},{"id":"AC2","text":"still works"}]}}' > "$TEMP_PROJECT/in.json"
OUT="$(node "$TOON" "$TEMP_PROJECT/in.json" --path spec.acceptance_criteria)"
assert_eq "--path selects a nested value and encodes it" "$OUT" "[2]{id,text}:
  AC1,works
  AC2,still works"
node "$TOON" "$TEMP_PROJECT/in.json" --path spec.nope >/dev/null 2>&1
assert_eq "a missing --path exits non-zero" "$?" "2"
node "$TOON" >/dev/null 2>&1
assert_eq "no file exits non-zero" "$?" "1"

finish
