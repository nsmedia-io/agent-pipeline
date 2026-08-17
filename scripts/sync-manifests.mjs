#!/usr/bin/env node
// The marketplace manifest is DERIVED from the plugin manifest. Run this after any version bump.
//
// Why it exists: `plugins/pipeline/.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json`
// each carry a version, and a consumer of the marketplace is offered an update based on the
// marketplace's copy. Those two drifted for TWELVE releases — plugin.json reached 0.17.0 while
// marketplace.json still advertised 0.6.1 — so every release since 2026-08-06 was invisible to
// anyone installing from the marketplace. Nothing failed. A hand-copied number in a second file is
// a fact asserted twice, and the second copy is the one nobody looks at.
//
// It also checks the parts of the marketplace description that make a factual claim about what
// ships: the agent roster and the command list. The description claimed eight agents while nine
// shipped, because Art Director was added and the sentence was not.
//
//   node scripts/sync-manifests.mjs           # write marketplace.json from plugin.json
//   node scripts/sync-manifests.mjs --check   # verify only; exit 1 on drift (for CI)
//
// Exit codes: 0 in sync (or written), 1 drift found in --check mode, 2 a manifest is unreadable.

import { readFileSync, writeFileSync, readdirSync } from "node:fs";

const CHECK_ONLY = process.argv.includes("--check");
const PLUGIN = "plugins/pipeline/.claude-plugin/plugin.json";
const MARKET = ".claude-plugin/marketplace.json";

function readJson(p) {
  try {
    return JSON.parse(readFileSync(p, "utf8"));
  } catch (err) {
    console.error(`sync-manifests: cannot read ${p} (${err.message})`);
    process.exit(2);
  }
}

const plugin = readJson(PLUGIN);
const market = readJson(MARKET);

const entry = (market.plugins ?? []).find((p) => p.name === plugin.name);
if (!entry) {
  console.error(
    `sync-manifests: marketplace.json has no plugin entry named "${plugin.name}". ` +
      `The marketplace cannot advertise a plugin it does not list.`,
  );
  process.exit(2);
}

// ── What the description asserts about what ships ────────────────────────────────────────────────
// Only checked as a SUBSTRING presence, deliberately. The description is prose and should stay
// readable; the failure worth catching is a role that ships and is never mentioned, not a wording
// preference. A roster that grows is the case that actually happened.
const agents = readdirSync("plugins/pipeline/agents")
  .filter((f) => f.endsWith(".md"))
  .map((f) => f.replace(/\.md$/, ""));
const commands = readdirSync("plugins/pipeline/commands")
  .filter((f) => f.endsWith(".md"))
  .map((f) => f.replace(/\.md$/, ""));

// How each on-disk file name is expected to read in prose.
const PROSE = {
  "art-director": "Art Director",
  ba: "BA",
  dba: "DBA",
  design: "Design",
  dev: "Dev",
  devops: "DevOps",
  librarian: "Librarian",
  qa: "QA",
  secops: "SecOps",
};

const desc = entry.description ?? "";
const missingAgents = agents.filter((a) => !desc.includes(PROSE[a] ?? a));
const missingCommands = commands.filter((c) => !desc.includes(`/${c}`));

const drift = [];
if (market.metadata?.version !== plugin.version)
  drift.push(`marketplace metadata.version ${market.metadata?.version} != plugin ${plugin.version}`);
if (entry.version !== plugin.version)
  drift.push(`marketplace plugins[${plugin.name}].version ${entry.version} != plugin ${plugin.version}`);
for (const a of missingAgents)
  drift.push(`agent "${a}" ships but the marketplace description never mentions it`);
for (const c of missingCommands)
  drift.push(`command "/${c}" ships but the marketplace description never mentions it`);

if (drift.length === 0) {
  console.log(`sync-manifests: in sync at ${plugin.version} (${agents.length} agents, ${commands.length} commands)`);
  process.exit(0);
}

if (CHECK_ONLY) {
  console.error(`sync-manifests: ${drift.length} drift(s) found\n`);
  for (const d of drift) console.error(`  - ${d}`);
  console.error(`\nRun: node scripts/sync-manifests.mjs`);
  process.exit(1);
}

// ── Write ────────────────────────────────────────────────────────────────────────────────────────
// Versions are derived. The description is NOT rewritten automatically: it is prose with a point of
// view, and a generated sentence would be worse than the one a person wrote. Report it instead.
market.metadata = { ...(market.metadata ?? {}), version: plugin.version };
entry.version = plugin.version;
writeFileSync(MARKET, JSON.stringify(market, null, 2) + "\n");

console.log(`sync-manifests: marketplace.json set to ${plugin.version}`);
const prose = [...missingAgents.map((a) => `agent "${a}"`), ...missingCommands.map((c) => `command "/${c}"`)];
if (prose.length > 0) {
  console.log(`\n  NOT fixed automatically — the description is prose, edit it by hand:`);
  for (const p of prose) console.log(`    - ${p} ships but is never mentioned`);
  process.exit(1);
}
