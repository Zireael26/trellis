# Targets — audit-report-rollup

This task reads the `audits/` directory, not the registry. It doesn't
iterate over projects.

## Scope

- Monthly, 1st at 10 AM — immediately after `gotchas-rollup` (9 AM) so this
  rollup can also cite the gotchas rollup's findings.
- Window: previous 30 days of audit files.

## Audit directory

`__SE_CORE_PATH__/audits/`

Naming convention: `YYYY-MM-DD-<task-name>.md`
