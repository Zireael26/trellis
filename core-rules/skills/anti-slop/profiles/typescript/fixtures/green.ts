// Green fixture: idiomatic evidence-preserving TypeScript. Must produce zero findings.
import { z } from "zod";

const userSchema = z.object({ id: z.string(), displayName: z.string() });

export type User = z.infer<typeof userSchema>;

type RequestLimits = { pageSize: number; maxRetries: number };

// `satisfies` checks the literal against the contract without widening it away.
export const defaultLimits = { pageSize: 50, maxRetries: 3 } satisfies RequestLimits;

/** Parse an untrusted payload at its I/O boundary into a named domain type. */
export function parseUser(rawJson: string): User {
	return userSchema.parse(JSON.parse(rawJson));
}

export function slugify(value: string): string {
	return value.toLowerCase().replaceAll(/[^a-z0-9]+/gu, "-");
}

type Slug = string;

export function userSlug(user: User): Slug {
	// SAFETY: slugify only emits lowercase alphanumerics and hyphens, which is the Slug contract.
	return slugify(user.displayName) as Slug;
}
