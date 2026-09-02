// Spelled counts in the Upgrading lead paragraph -> the distinct integers they denote.
// Compound-aware ("twenty-five"), because the section passed nine a long time ago.
const UNITS = { zero:0, one:1, two:2, three:3, four:4, five:5, six:6, seven:7, eight:8, nine:9,
  ten:10, eleven:11, twelve:12, thirteen:13, fourteen:14, fifteen:15, sixteen:16, seventeen:17,
  eighteen:18, nineteen:19 };
const TENS = { twenty:20, thirty:30, forty:40, fifty:50, sixty:60, seventy:70, eighty:80, ninety:90 };
const WORD = Object.keys(UNITS).concat(Object.keys(TENS)).sort((a,b)=>b.length-a.length).join("|");
// A compound is tens-hyphen-unit; the alternation puts it first so "twenty-five" is not read
// as "twenty" followed by a separate "five".
const RE = new RegExp(`\\b(?:(${Object.keys(TENS).join("|")})-(${Object.keys(UNITS).join("|")})|(${WORD}))\\b`, "gi");
// The largest integer this table can denote in valid English, DERIVED from the table rather
// than written down, so extending either map moves it. A caller asserts its own input against
// this: a bullet count above it cannot be spelled here, and a parse that silently reduces
// "one hundred" to 1 must be reported as out of range, not as a stale README.
const MAX = Math.max(...Object.values(TENS)) + Math.max(...Object.values(UNITS).filter((n) => n <= 9));
if (process.argv[2] === "--max") { console.log(MAX); process.exit(0); }
const text = process.argv[2] || "";
const out = new Set();
for (const m of text.matchAll(RE)) {
  if (m[1]) out.add(TENS[m[1].toLowerCase()] + UNITS[m[2].toLowerCase()]);
  else { const w = m[3].toLowerCase(); out.add(w in UNITS ? UNITS[w] : TENS[w]); }
}
console.log([...out].sort((a,b)=>a-b).join(","));
