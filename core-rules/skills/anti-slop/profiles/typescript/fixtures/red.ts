// Red fixture: every construct here must produce at least one anti-slop finding.
// Inverting a rule must break this file's expectation, so keep one pattern per export.
import { vi } from "vitest";

// no-module-mocking: replaces a real seam with a patched module.
vi.mock("./user-service.ts");

// no-unknown-returns: hands the caller an unparsed value.
export function loadConfig(rawJson: string): unknown {
	return JSON.parse(rawJson);
}

// no-chained-type-assertions: launders a string into a number.
export function coerceCount(input: string): number {
	return input as unknown as number;
}

// no-known-value-widening: an open dictionary annotation discards the known flag set.
export const featureFlags: Record<string, boolean> = { fastPath: true };

// require-safety-comment-for-type-assertion: `as any` with no stated invariant.
export function readTitle(rawJson: string): string {
	return (JSON.parse(rawJson) as any).title;
}
