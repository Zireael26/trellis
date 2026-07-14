# Provenance & attribution

This template is a redacted snapshot of an active Trellis deployment, packaged for re-use. (The framework was renamed from "SE Core" to "Trellis" on 2026-05-12; this document and the lineage diagram below preserve the historical name where it refers to pre-rename artefacts.)

## Lineage

```
github.com/iamfakeguru/claude-md   (MIT)
        │
        │   Seed: block-destructive, post-edit-verify, stop-verify, truncation-check
        │   hooks. Two-tier hook architecture concept.
        ▼
Trellis instance (live)            (private source repository; pre-2026-05-12 name: "SE Core")
        │
        │   Extensions: three-tier hook architecture (fast-local + heavy-gated + git-boundary),
        │   stop-verify TodoWrite guard, code-review-subagent + ui-verify hook skeletons,
        │   session-context / save-context-log / post-compact-context hooks, scheduled
        │   audit stack (cross-project process audit, dep-currency, dep-vulnerabilities,
        │   dep-major-upgrade-watch, bypass-tripwire, parent-hook-drift, gotchas-rollup,
        │   audit-report-rollup, registry-blacklist-health, test-health), inheritance
        │   mechanism (`.claude/rules/` symlink as primary, `@`-import as fallback),
        │   Rule-of-Three discipline with `core-rules/deferred.md`.
        ▼
Trellis (this repo)                (public framework; pre-2026-05-12 name: "SE Core Template")
        │
        │   Same structure, redacted: project names replaced with `project-a..f`,
        │   absolute paths replaced with `__TRELLIS_PATH__` / `__PROJECTS_ROOT__`
        │   placeholders, real audit history reduced to four representative examples
        │   under `examples/audits/`.
        ▼
Your fork                          (you fill in placeholders during AGENT_SETUP.md)
```

## What's verbatim from upstream (`iamfakeguru/claude-md`)

The following hook scripts under `core-rules/hooks/` carry "upstream" or "upstream, extended" markers in their headers — those parts trace to iamfakeguru/claude-md (MIT):

- `block-destructive.sh` (extended: `DELETE FROM` w/o `WHERE`, `**/secrets/**` glob, exfil patterns)
- `post-edit-verify.sh` (extended: Go and Rust support)
- `stop-verify.sh` (extended: TodoWrite guard, Go support, last-30-lines slicing for tests)
- `truncation-check.sh` (extended: explicit 50K-char threshold per spec)

## What's net-new in this template (vs. upstream)

- Three-tier hook architecture (`core-rules/hooks.md`)
- `code-review-subagent.sh` + `ui-verify.sh` hook skeletons (no upstream equivalents)
- Inheritance mechanism: `.claude/rules/trellis.md` symlink as load-bearing primary, `@`-import as interactive fallback (`core-rules/inheritance.md`)
- Registry-driven audit/report conventions; operator schedules, prompts, targets, and fleet inventory are deliberately excluded
- Rule of Three / `core-rules/deferred.md` discipline
- `engineering-process.md` narrative manual

## License

MIT, same as the upstream. See `LICENSE`.
