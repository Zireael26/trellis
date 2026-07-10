// Fixture: a companion whose validator moved beyond the probe's search
// pattern (e.g. a refactor renamed the enum). The preflight must report
// supported_efforts: [] — fail-closed, never a guessed set.
const EFFORT_LEVELS = Object.freeze(["medium", "high"]);
export function checkEffort(e) {
  return EFFORT_LEVELS.includes(e);
}
