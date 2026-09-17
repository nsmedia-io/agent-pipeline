### Live-verification gate (data-migration / security-sensitive changes; opt-in)

# CUSTOMIZE: this gate is a no-op for projects with no schema migrations and no self-skipping
# integration suite. Enable it when your project has an integration suite that self-skips
# when its backing service or env is absent (the common CI shape).

A self-SKIPPED integration suite is NOT verification. Suites that self-skip when their backing env is absent (as in default CI) prove nothing about a data migration's access-control or table behavior when they skip. If the diff ADDS or ALTERS a data migration touching access controls or a security-sensitive table and there is NO recorded local pass of that suite (only skips), HALT before the panel:

This is a **full voice mode** moment (see "Human-facing responses"): the owner has to go run something themselves, and the change is a migration, so `voice.md` requires the words "this is a one way door" in the first three lines. The line below is the factual spine, not the whole message:

```
**[Orchestrator]:** HALTED at Phase 3 to 4 gate. Live-verification suite unverified: run it locally against a real backing service before merge. The data-migration or security-sensitive change in this diff has only a skipped integration suite; CI-green-with-skips does not count as verification.
```

Update `status.json` with `current_phase: "3-impl-live-verify-unverified"` and loop back to Phase 3 (Dev/QA) to produce a RECORDED local pass. Run the self-skipping suite locally against a real backing service (# CUSTOMIZE: your live-integration test command, e.g. one that starts a local stack, exports the credentials the suite needs so it un-skips, runs it, and ALWAYS tears the stack down on exit). Do not treat CI-green-with-skips as done for such a change. A recommended infra follow-up is to extend your migration-validation CI job to run the self-skipping suites against a disposable local stack, so this verification stops being manual.

