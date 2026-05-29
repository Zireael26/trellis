---
autonomy_ceiling: 2
---

# Preset: compliance-strict

**Posture:** strict
**Purpose:** add audit-grade discipline on top of the parent rules for projects that handle regulated data, are under customer-contract controls, or face external compliance review.
**Use when:** the project processes PII / payments / health data, has signed a customer contract that mandates change-control or sign-off discipline, or is subject to SOC 2 / HIPAA / PCI-style audits.

---

## Additions

These extend the parent discipline. Each rule has a one-line *why*.

- **Mandatory ADR for every architectural change.** Any change that introduces a new dependency, alters a data store, changes auth flow, or modifies a public API requires a new file under `docs/adr/<date>-<topic>.md` *before* the implementation PR. *Why:* compliance auditors need a paper trail of design decisions, not just commit history.
- **Two-human sign-off on every PR.** Process-gate's standard one-reviewer rule is not enough. A second reviewer must explicitly approve. *Why:* segregation-of-duties — single-reviewer approval doesn't satisfy audit requirements for change control.
- **No `--no-verify` ever.** The standard bypass-tripwire warns; under this preset the husky `pre-push` MUST refuse the override even with `TRELLIS_ALLOW_MAIN_PUSH=1`. *Why:* the override is a signal to auditors that controls can be bypassed. Removing it removes the bypass surface.
- **Mandatory CHANGELOG entry per PR.** Every PR that ships behaviour change must append a row to `CHANGELOG.md` describing what changed and why. *Why:* changelog IS the audit trail; missing entries break the trail.
- **Secrets-scan failure is a hard block.** Under parent rules, `process-gate`'s secrets gate emits warnings the operator can ack. Under this preset, secrets findings are pass/fail — no overrides. *Why:* a leaked credential in a compliance-bound project is a reportable incident.
- **All deploys carry a deploy ID linked to the change.** The deploy artifact (image, bundle, package) must encode the merge commit SHA. *Why:* incident response needs to map a runtime artifact back to a specific change for audit replay.

## Carve-outs

This preset has no carve-outs. It is strictly additive on top of parent discipline.

## Notes

- Two-human sign-off is enforced at GitHub branch-protection level, not at hook level (Trellis doesn't intercept the PR merge button). Project must configure branch protection separately; this preset documents the requirement.
- The "no `--no-verify` ever" rule requires either editing the project's `.husky/pre-push` to strip the override OR setting `TRELLIS_ALLOW_MAIN_PUSH` to an empty string in CI. Project-local enforcement detail.
- If a project under this preset finds itself needing a carve-out, it probably belongs in a sibling preset (e.g., `compliance-strict-with-fast-fix`), not as a hole in this one.
- **Autonomy ceiling: L2.** Compliance-strict requires human-in-the-loop on every non-trivial decision; two-human PR sign-off cannot exist if one of the two is the agent acting autonomously. Sessions cannot exceed L2 even via `/autonomy N` slash override; the command clamps and warns.
