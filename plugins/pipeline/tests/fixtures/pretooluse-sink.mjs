#!/usr/bin/env node
// Snapshot and diff the FILE sinks of the #106 gate.
//
// TWO CRITERIA SHARE THIS ONE OBSERVATION, and they read it in opposite directions:
//   AC19 (leak):        the caller's command string must appear in NO file the gate created or
//                       appended to under any resolved root or temp dir.
//   AC20 (attribution): each fail-open gap and each abstention must leave a DISTINCT, recoverable
//                       record -- and the non-acting fast path must leave NONE.
// Both are questions about "what did this process write, where the test can see it", so they are
// answered by one before/after walk rather than by two mechanisms that could disagree.
//
// WHY DISCOVERY AND NOT A FIXED PATH. QA authors this contract before the implementation exists,
// and naming an attribution file would be authoring the implementation's shape. R15 already
// enumerates the sinks the gate may write ("any file created or appended under any resolved root
// or temp dir"), so the suite binds every root it hands the gate -- CLAUDE_PROJECT_DIR, the
// payload's cwd, and TMPDIR -- and reads whatever appears. If the shipped gate persists its
// attribution somewhere outside every root the test controls, that is a finding for Dev to raise
// with QA, not a fixture to widen silently: an attribution a suite cannot reach is one an
// operator cannot reach either.
//
// Usage:
//   pretooluse-sink.mjs snap <manifest.json> <root> [root ...]
//   pretooluse-sink.mjs diff <manifest.json> <root> [root ...]
//       -> prints, for every file that is NEW or whose CONTENT CHANGED since the snapshot:
//            === <abs path>
//            <content>
//          Empty output means the gate wrote nothing under any bound root.
//   pretooluse-sink.mjs count <manifest.json> <root> [root ...]
//       -> prints the number of new/changed files, and nothing else.

import { readdirSync, readFileSync, writeFileSync, statSync, existsSync } from "node:fs";
import path from "node:path";
import { createHash } from "node:crypto";

const [, , mode, manifest, ...roots] = process.argv;

function walk(dir, out) {
  let entries;
  try {
    entries = readdirSync(dir, { withFileTypes: true });
  } catch {
    return out;
  }
  for (const e of entries) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) {
      walk(p, out);
    } else if (e.isFile()) {
      let buf;
      try {
        buf = readFileSync(p);
      } catch {
        continue;
      }
      out[p] = createHash("sha1").update(buf).digest("hex");
    }
  }
  return out;
}

function scan() {
  const out = {};
  for (const r of roots) {
    if (!r) continue;
    walk(path.resolve(r), out);
  }
  return out;
}

if (mode === "snap") {
  writeFileSync(manifest, JSON.stringify(scan()));
  process.exit(0);
}

const before = existsSync(manifest) ? JSON.parse(readFileSync(manifest, "utf8")) : {};
const after = scan();
const changed = Object.keys(after)
  .filter((p) => before[p] !== after[p])
  .sort();

if (mode === "count") {
  process.stdout.write(String(changed.length));
  process.exit(0);
}

let acc = "";
for (const p of changed) {
  let body = "";
  try {
    body = readFileSync(p, "utf8");
  } catch {
    body = "<unreadable>";
  }
  acc += `=== ${p}\n${body}\n`;
}
process.stdout.write(acc);
