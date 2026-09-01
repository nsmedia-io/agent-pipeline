#!/usr/bin/env node
// Read a PreToolUse hook's stdout on stdin; print the decision a CALLER would receive.
//
// R13/AC13: "Assertions are taken on the parsed decision a caller receives, never on raw stdout."
// A suite that greps stdout for the string `"deny"` passes on a hook that emits it inside a
// diagnostic, inside the wrong hookEventName, or inside invalid JSON -- three states where the
// real consumer does something else entirely. So the consumer's own reading is modelled here,
// against Claude Code 2.1.85:
//
//   * it reads `H.hookSpecificOutput.permissionDecisionReason || H.reason || "Blocked by hook"`
//     for the reason it renders, so that precedence is reproduced rather than guessed;
//   * it THROWS on a hookSpecificOutput whose hookEventName does not match the event, so a
//     mismatch is reported here as BAD-EVENT and is a distinct outcome from a deny and from a
//     no-op -- otherwise a gate that emitted the wrong event name would read as "denies fine".
//
// Output: three TAB-separated fields on one line: <decision>\t<reason>\t<rawEventName>
//   deny | allow | ask   -- an explicit permissionDecision
//   none                 -- no decision reached the caller (empty output, or no
//                           hookSpecificOutput). This is the FAIL-OPEN outcome AC21 asserts.
//   NOT-JSON             -- output present but unparseable. Distinct from `none` ON PURPOSE:
//                           the runtime treats it as no decision, but a suite that could not
//                           tell the two apart would call a crashing gate "correctly silent".
//   BAD-EVENT            -- hookSpecificOutput.hookEventName is not "PreToolUse".

let raw = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (c) => (raw += c));
process.stdin.on("end", () => {
  const emit = (d, r = "", e = "") =>
    process.stdout.write(`${d}\t${String(r).replace(/[\t\n\r]/g, " ")}\t${e}`);

  if (raw.trim() === "") return emit("none");

  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return emit("NOT-JSON");
  }
  if (parsed === null || typeof parsed !== "object") return emit("NOT-JSON");

  const hso = parsed.hookSpecificOutput;
  if (hso === undefined || hso === null) {
    // No hookSpecificOutput at all: nothing the PreToolUse consumer acts on.
    return emit("none", parsed.reason || "", "");
  }
  if (hso.hookEventName !== "PreToolUse") {
    return emit("BAD-EVENT", "", String(hso.hookEventName));
  }
  const decision = hso.permissionDecision;
  const reason = hso.permissionDecisionReason || parsed.reason || "Blocked by hook";
  if (decision === undefined || decision === null || decision === "") {
    return emit("none", reason, "PreToolUse");
  }
  return emit(String(decision), reason, "PreToolUse");
});
