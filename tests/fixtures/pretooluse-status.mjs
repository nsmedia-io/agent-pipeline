#!/usr/bin/env node
// Write a status.json record for the #106 gate suites.
//
// Usage: pretooluse-status.mjs <outfile> [key=value ...]
//   updated_at=agoms:<n>   -> now minus <n> ms, ISO (the in-flight / stale axis, by CONTENT)
//   <key>=json:<literal>   -> parsed as JSON, which is how the datability cells get their
//                             null / {} / true / [] / 12345 spellings (R5, AC13)
//   <key>=__ABSENT__       -> key deleted (an ABSENT updated_at is a distinct cell from an
//                             unparseable one; AC37 asserts both)
//   anything else          -> a string
//
// The default record is in flight by CONTENT: no final_verdict and updated_at = now. The grain
// is the FIELD, never the file mtime (R5), so nothing here touches mtimes on purpose -- a suite
// that wants an mtime ordering sets it explicitly with `touch`, and AC13's stability pair proves
// the answer does not move when it does.

import { writeFileSync, mkdirSync } from "node:fs";
import path from "node:path";

const [, , out, ...rest] = process.argv;
if (!out) {
  process.stderr.write("pretooluse-status.mjs: <outfile> required\n");
  process.exit(2);
}

const status = {
  issue_number: 106,
  title: "qa contract fixture",
  risk_tier: "architectural",
  current_phase: "0-setup",
  updated_at: new Date().toISOString(),
  events: [],
  flags: [],
};

for (const kv of rest) {
  const i = kv.indexOf("=");
  if (i < 0) continue;
  const k = kv.slice(0, i);
  const v = kv.slice(i + 1);
  if (v === "__ABSENT__") {
    delete status[k];
    continue;
  }
  if (v.startsWith("agoms:")) {
    status[k] = new Date(Date.now() - Number(v.slice(6))).toISOString();
    continue;
  }
  if (v.startsWith("json:")) {
    status[k] = JSON.parse(v.slice(5));
    continue;
  }
  status[k] = v;
}

mkdirSync(path.dirname(out), { recursive: true });
writeFileSync(out, JSON.stringify(status, null, 2) + "\n");
