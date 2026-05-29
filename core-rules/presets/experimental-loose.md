---
autonomy_ceiling: 5
autonomy_default: 4
---

# Preset: experimental-loose

**Posture:** loose
**Purpose:** relax ceremony for short-lived projects where the surgical-default discipline is more friction than it's worth.
**Use when:** the project is a throwaway prototype, a hackathon entry, an internal-only spike, or a single-author script that won't outlive the next two weeks. Re-evaluate before the project crosses three weeks of life or gains a second author.

---

## Additions

This preset adds nothing on top of parent rules. It's all carve-outs.

## Carve-outs

These RELAX parent discipline. Each carve-out names the parent rule by section and explains why it's safe to skip in the experimental context.

- **Direct commits to `main` are allowed.** Parent rule `engineering-process.md §6` requires every change to land via PR. *Carve-out:* solo author, no reviewers, no external consumers — PR ceremony adds friction without catching anything. *Constraint:* the moment a second author touches the repo, this carve-out is void and the project switches to a real branch-and-PR flow.
- **No `tasks.md` discipline.** Parent rule `engineering-process.md §14.7` recommends the spec-kit pipeline for multi-step features. *Carve-out:* experimental work explores; specs lock in assumptions too early. Use `TodoWrite` only; skip the committed pipeline artifacts.
- **CHANGELOG entries optional.** Parent rule asks every PR to update `CHANGELOG.md`. *Carve-out:* prototype iteration is the changelog. Re-enable for the rewrite when the prototype proves out.
- **`process-gate`'s PR-size ceiling is informational only.** Parent rule treats PR size >800 as a hard fail. *Carve-out:* exploratory commits are larger by nature. The gate still reports size; the fail tier becomes warn.
- **Test coverage is not required to ship.** Parent rule requires receipts on every "done" claim. *Carve-out:* the test we'd write is "does this experiment teach us what we wanted to know"; that test is the operator's eyes on a running prototype, not a CI job. Add real tests when the experiment outgrows that.

## Notes

- This preset is **time-bound**. Set a calendar reminder when enabling it; revisit at the project's three-week mark. If the project survives three weeks, the carve-outs come off and standard discipline kicks back in.
- Do NOT enable this preset on a project that has external consumers (production traffic, paying customers, dependent services). The carve-outs assume the blast radius is the operator's own machine.
- The `security-gate` baseline still runs under this preset. Throwaway code is still attack surface; secrets and high-severity findings get reported. The carve-outs are about ceremony, not safety.
- If you find yourself wanting to keep this preset on indefinitely, that's a signal the project has graduated past experimental status — switch to the parent rules + (if needed) a stricter preset.
- **Autonomy ceiling L5, default L4.** Experimental work explores; the agent should not have to ask permission for routine decisions. L4 is a sensible default (single plan-approval, batched questions, architectural decisions still surface inline). L5 available for pure-chore sessions.
