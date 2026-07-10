// Fixture: fake companion validator source mirroring the installed
// companion's shape (v1.0.5 keeps the enum in scripts/codex-companion.mjs).
const VALID_REASONING_EFFORTS = new Set(["none", "minimal", "low", "medium", "high", "xhigh"]);

export function normalizeReasoningEffort(effort) {
  const normalized = String(effort).trim().toLowerCase();
  if (!VALID_REASONING_EFFORTS.has(normalized)) {
    throw new Error(`Unsupported reasoning effort "${effort}".`);
  }
  return normalized;
}
