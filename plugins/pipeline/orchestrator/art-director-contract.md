**Art Director is contract-conditional, at every tier.** It is NOT a standing panel role and NOT a taste second-opinion on Design. It joins only when a binding visual contract exists for this issue, and it owns that contract.

**Duty A, before Phase 3.** When the spec is frontend-scoped AND the ask is a redesign, a rejected surface, or a new visual surface (not a bugfix on an existing one), dispatch `art-director` ONCE after the spec locks and before Dev starts. It writes `<ARTIFACT_DIR>/visual-contract.json`: a thesis, three to six falsifiable clauses each carrying how it would be checked, `would_be_failure`, `inherited_unexamined`, and `the_risk`. Dev then treats that file as a Phase-2-equivalent hard constraint, exactly like `constraints.md`.

Two rules that make the contract worth having, both paid for on the run that produced this role:

- **A clause must bind on a measurable property, never on a proposed fix.** Asked to either build a control or downgrade an untested claim, the Art Director built three variants and its control proved its own instinct wrong: the fix it wanted to mandate measured as a regression on a second axis. Had the clause named the fix, the contract would have caused the defect it existed to prevent. Clause text that names a solution is a defect in the clause.
- **The binding marker is the STRING `"BINDING"`, not a boolean.** A `=== true` check reads zero clauses and every gate silently passes.

**Duty B, on the Phase 4 panel.** Seated only when `<ARTIFACT_DIR>/visual-contract.json` exists; `panel-roles.mjs full` decides (a cost_class `tooling` panel omits it). It renders the result itself, rules clause by clause, and writes a bare `peer-review.art_director.json`. Its `REQUEST_CHANGES` is BINDING on one narrow ground: the result materially fails a CITED clause, with rendered evidence it captured itself. Pure preference stays advisory no matter how strongly held, and it must say which it is doing every time. It may also return `ESCALATE`, meaning the contract itself was wrong; that is a finding, not a failure, and it returns the question to BA.

