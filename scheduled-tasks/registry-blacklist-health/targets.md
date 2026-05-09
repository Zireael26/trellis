# Targets — registry-blacklist-health

This task is the **control-plane sanity check**. It doesn't iterate over the
registry — it *audits* the registry itself. The "target set" is just the
three files/directories below.

## Inputs

1. `__SE_CORE_PATH__/registry.md`
2. `__SE_CORE_PATH__/blacklist.md`
3. Filesystem: `__PROJECTS_ROOT__/*/` (scan for git repos)

## Scope

- Weekly, Monday at 10:30 AM — after `cross-project-process-audit` (10 AM)
  and before `test-health` (11 AM). Ordering intentional: downstream audits
  that iterate `registry \ blacklist` need these two files to be sane.

## Personal projects root override

If the personal projects root ever moves, record it here:
```
PERSONAL_ROOT=__PROJECTS_ROOT__
```

Current: `__PROJECTS_ROOT__/` (as of 2026-04-20).
