#!/usr/bin/env node
// Build a PreToolUse hook payload for the #106 gate suites.
//
// WHY A HELPER AND NOT printf IN BASH. Half of AC7/AC9's population is commands carrying single
// quotes, double quotes, `&&` and `;` INSIDE a -m operand -- this issue's own doc-retirement
// commit message is one of them. Hand-escaping those into a JSON literal in bash is where a
// fixture stops being the shape it claims to be, and a mis-escaped fixture is a test that passes
// for a reason nobody wrote down.
//
// Usage: pretooluse-payload.mjs <command> cwd=<root> [key=value ...]
//   key=value      sets a TOP-LEVEL payload field (agent_id, agent_type, cwd, active_issue, ...)
//   key=__ABSENT__ deletes the key, which is how the agent_id-ABSENT population is built. The
//                  distinction between "absent" and "empty string" is the whole of R2, so it has
//                  to be expressible.
//   tool_name=X    overrides the tool name (the non-Bash population).
//
// `cwd` IS REQUIRED AND IS NEVER GUESSED. It used to default to process.cwd(), and that one line
// leaked the CALLER's working directory into the fixture: run from the repository root -- which
// holds a real, in-flight .pipeline -- the resolver unioned the checkout's own record store with
// the temp root, found two candidates and abstained, so this suite reported 64 passed / 83 failed
// from one cwd and 147 / 0 from another at the same commit. The 64 that still passed were worse
// than the 83 that failed: every allow-side row was satisfied by a gate that had gone inert. The
// suite's hermeticity was accidental (run.sh cds into a directory with no .pipeline sibling); it
// is constructed now, and a caller that forgets to name a root gets an error rather than a leak.
//
// The payload's SHAPE follows Claude Code 2.1.85: hook_event_name, session_id, tool_name,
// tool_input.command, and agent_id present ONLY for a subagent-originated call.

const [, , cmd, ...rest] = process.argv;

if (!rest.some((kv) => kv.startsWith("cwd="))) {
  process.stderr.write(
    "pretooluse-payload.mjs: a cwd=<root> argument is required; the payload cwd is never inferred " +
      "from the caller's working directory (see the comment above).\n",
  );
  process.exit(2);
}

const payload = {
  hook_event_name: "PreToolUse",
  session_id: "qa-106-contract",
  transcript_path: "/dev/null",
  cwd: undefined, // set from the required cwd= argument below; declared here to fix its position
  tool_name: "Bash",
  tool_input: { command: cmd === undefined ? "" : cmd },
};

for (const kv of rest) {
  const i = kv.indexOf("=");
  if (i < 0) continue;
  const k = kv.slice(0, i);
  const v = kv.slice(i + 1);
  if (v === "__ABSENT__") {
    delete payload[k];
    continue;
  }
  if (v.startsWith("json:")) {
    payload[k] = JSON.parse(v.slice(5));
    continue;
  }
  payload[k] = v;
}

process.stdout.write(JSON.stringify(payload));
