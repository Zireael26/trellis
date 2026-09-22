# Pi setup parity ships as one PR: the omp-statusline vendor fork lands with its guide

- Status: accepted
- Date: 2026-09-23

## Context

The public pi setup guide (`AGENT_PI_SETUP.md`) pinned pi 0.84.4, four npm
packages, and the 11-segment upstream footer, while the operator runs pi 0.87.0
with six packages plus the local adapter path and the `omp-statusline`
`0.50.0-omp.1` fork rendering the 19-segment OMP-parity footer. A mirror
checkout following the old steps gets a different status line with no usage
row. The fix updates the guide (steps 1, 2, 5, 7, 12 plus reasoning) and
publishes the fork source at `core-rules/pi/statusline/omp-statusline/` so the
path the guide copies from exists for every reader.

The range is ~4,100 countable lines over the 800-line hard PR-size cap. Roughly
3,900 of those are the 30 vendored fork files (upstream
`@narumitw/pi-statusline` MIT code plus the OMP-parity segments); the executable
change is three edited docs files. This ADR is the size-cap exception the
process gate permits when splitting harms clarity.

## Decision

Ship guide + fork source as one PR rather than splitting per file or per step.

1. **The fork is the unit of review, and it only works whole.** Its 30 files
   import across `src/` (`statusline.ts`, `render.ts`, `settings.ts`,
   `presets/`, …); landing a subset is a broken package that neither installs
   (`npm install --omit=dev --legacy-peer-deps` resolves the tree) nor renders.
   File-by-file PRs would each carry the same guide context to be reviewable.
2. **Guide and payload must land together.** Step 2 copies
   `core-rules/pi/statusline/omp-statusline` and step 7 asserts the 19-segment
   config it renders. Landing the guide first leaves a dangling source path;
   landing the fork first publishes an unexplained payload directory.
3. **The fork is vendored, not authored, code.** Review is provenance-led: the
   fork README credits upstream, `LICENSE` is preserved, `node_modules` is
   excluded, and no absolute operator paths are present (verified by grep).
   A reviewer diffs against upstream 0.50.x and spot-checks the added segments
   rather than reading 3,900 lines as new logic.

## Consequences

- Review is provenance-led; the PR description links this ADR and the gate output.
- Rollback is a revert of the single commit (guide + fork leave together, so no
  dangling path in either direction).
- The reviewer acknowledges the size in the PR description.
- No VERSION bump and no `vX.Y.Z` tag here: the footer is guide-installed into
  `~/.pi/agent`, not attachment-rendered, so no immutable-release change is
  required for the fix. The payload addition rides the next normal release.
