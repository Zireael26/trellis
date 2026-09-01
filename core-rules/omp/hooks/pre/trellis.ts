/**
 * trellis.ts — Oh My Pi extension factory bridging OMP lifecycle events to the
 * canonical Trellis shell hooks. Live runtime adapter; never copied policy.
 *
 * Attached projects reach this adapter through the immutable runtime leaf
 * `<project>/.omp/hooks/pre/trellis.ts ->
 * <project>/.trellis/runtime/core-rules/omp/hooks/pre/trellis.ts`.
 *
 * Contract:
 *   - Default export is the OMP extension factory (`(pi: ExtensionAPI) => void`).
 *   - Default lifecycle resolution reads only the event context's attached
 *     project `.trellis/runtime` anchor. It never reads `TRELLIS_ROOT` or
 *     derives policy from this module's checkout.
 *   - A raw/non-Trellis project is inert. A project carrying the managed OMP
 *     adapter leaf whose runtime anchor or payload is missing or wrong fails
 *     closed with a named error.
 *   - Explicit `createTrellisAdapter` inputs remain supported for embeddings
 *     and tests, but must resolve to the same immutable release payload.
 *   - Normalizes OMP events into the canonical Claude hook envelope and
 *     executes scripts from the attached immutable payload with
 *     `CLAUDE_PROJECT_DIR` and `TRELLIS_ROOT` exported.
 *   - Parses the scripts' decision JSON and maps it to OMP results:
 *       tool_call          -> `{block: true, reason}`      (fail closed)
 *       tool_result        -> `isError` + reason in content (gates), or
 *                             advisory context appended     (truncation)
 *       input              -> `{handled: true}`            (slash-command size denial)
 *       session_stop       -> `{decision: "block", reason}` (continuation request)
 *   - Injects the live project `CLAUDE.md` into sessions whose system prompt
 *     lacks it. Top-level sessions already carry it natively via
 *     `.omp/AGENTS.md`; OMP task children exclude `AGENTS.md` from inherited
 *     context files, so the marker check appends the policy before their first
 *     agent run.
 *   - Saves the Trellis context log on `session_before_compact` and
 *     `session_shutdown`.
 *   - Stop hooks receive an adapter-produced transcript (Claude JSONL shape)
 *     derived from `SessionStopEvent.messages`; `CLAUDE_TRANSCRIPT_PATH` is
 *     exported for the hooks that read the env channel. The OMP continuation
 *     ceiling (8 passes) stays authoritative.
 *
 * Dependency-light: Node builtins only, no `@oh-my-pi` imports (the host
 * injects the ExtensionAPI). Erasable-syntax-only TypeScript so both the OMP
 * loader and plain `node --test` type stripping can consume it.
 */
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { createHash } from "node:crypto";
import { spawnSync, type SpawnSyncOptionsWithStringEncoding, type SpawnSyncReturns } from "node:child_process";

// ============================================================================
// Structural OMP types — subset of the installed extension contract. The host
// injects the real ExtensionAPI; these local shapes keep the module free of
// package imports and directly testable in plain Node.
// ============================================================================

export interface OmpLogger {
	warn(...args: unknown[]): void;
	error(...args: unknown[]): void;
}

export interface OmpSessionManager {
	getSessionId?(): string | undefined;
	getSessionFile?(): string | undefined;
}

export interface OmpContext {
	cwd: string;
	sessionManager?: OmpSessionManager;
	getSystemPrompt?(): string[];
	ui?: { notify?(message: string, type?: string): void };
}

export interface OmpInputEvent {
	type: "input";
	text: string;
	source: string;
}

export interface OmpToolCallEvent {
	type: "tool_call";
	toolCallId: string;
	toolName: string;
	input: Record<string, unknown>;
}

export interface OmpToolResultEvent {
	type: "tool_result";
	toolCallId: string;
	toolName: string;
	input: Record<string, unknown>;
	content: unknown[];
	isError: boolean;
}

export interface OmpBeforeAgentStartEvent {
	type: "before_agent_start";
	prompt: string;
	systemPrompt?: string[];
}

export interface OmpSessionStopEvent {
	type: "session_stop";
	messages: unknown[];
	turn_id: number;
	session_id: string;
	session_file?: string;
	stop_hook_active: boolean;
	last_assistant_message?: unknown;
	signal?: AbortSignal;
}

export interface OmpSessionBeforeCompactEvent {
	type: "session_before_compact";
	preparation?: {
		messagesToSummarize?: unknown[];
		turnPrefixMessages?: unknown[];
		recentMessages?: unknown[];
	};
}

export interface OmpSessionCompactEvent {
	type: "session_compact";
}

export interface OmpSessionShutdownEvent {
	type: "session_shutdown";
}

/** Minimal surface of the OMP ExtensionAPI used by this factory. */
export interface OmpApi {
	on(event: string, handler: (event: unknown, ctx: OmpContext) => unknown): void;
	setLabel(label: string): void;
	sendMessage?(
		message: { customType: string; content: string; display?: boolean },
		options?: { triggerTurn?: boolean; deliverAs?: "steer" | "followUp" | "nextTurn" },
	): void;
	logger: OmpLogger;
}

// OMP event result shapes (structural subset).
export interface InputResult {
	handled?: boolean;
	text?: string;
}
export interface ToolCallResult {
	block?: boolean;
	reason?: string;
	input?: Record<string, unknown>;
}
export interface ToolResultPatch {
	content?: unknown[];
	details?: unknown;
	isError?: boolean;
}
export interface AgentStartResult {
	message?: { customType: string; content: string; display?: boolean };
	systemPrompt?: string[];
}
export interface StopResult {
	continue?: boolean;
	additionalContext?: string;
	decision?: "block";
	reason?: string;
}
export interface CompactResult {
	cancel?: boolean;
}

// ============================================================================
// Canonical manifest — the OMP event -> live canonical script mapping. This is
// the adapter-side mirror of the canonical Claude `claude-settings.json` hook
// manifest (core-rules/templates/claude-settings.json). Timeouts match the
// manifest; scripts are never copied, only executed from core-rules/hooks.
//
// No-Anthropic stop guarantee: every model-backed stop script receives
// TRELLIS_OMP=1 in its environment. That flag is the scripts' contract to use
// the non-Anthropic reviewer route (lib/omp-reviewer.sh) instead of the
// Claude/Codex `claude -p` rung, and to skip Claude-only proposal paths — so a
// default claude process is never reachable from an OMP stop.
// ============================================================================

/** OMP tool name -> canonical Claude tool name used in the hook envelope. */
const CLAUDE_TOOL_NAME: Record<string, string> = {
	bash: "Bash",
	read: "Read",
	write: "Write",
	edit: "Edit",
	grep: "Grep",
	glob: "Glob",
	skill: "Skill",
};

const PRE_TOOL_USE: ReadonlyArray<{ tool: string; script: string; timeoutMs: number }> = [
	{ tool: "bash", script: "block-destructive.sh", timeoutMs: 5_000 },
	{ tool: "skill", script: "skill-preload-guard.sh", timeoutMs: 5_000 },
	{ tool: "edit", script: "reread-guard.sh", timeoutMs: 5_000 },
	{ tool: "write", script: "reread-guard.sh", timeoutMs: 5_000 },
];

const POST_TOOL_USE: ReadonlyArray<{ tools: ReadonlyArray<string>; script: string; timeoutMs: number }> = [
	{ tools: ["edit", "write"], script: "post-edit-verify.sh", timeoutMs: 120_000 },
	{ tools: ["grep", "bash", "read"], script: "truncation-check.sh", timeoutMs: 5_000 },
	{ tools: ["read", "write", "edit"], script: "track-read.sh", timeoutMs: 5_000 },
];

const SESSION_START_SCRIPTS: ReadonlyArray<{ script: string; timeoutMs: number; envelope: () => Record<string, unknown> }> = [
	{ script: "session-context.sh", timeoutMs: 10_000, envelope: () => ({ source: "startup" }) },
	{ script: "inject-primer-index.sh", timeoutMs: 5_000, envelope: () => ({ source: "startup" }) },
	{
		script: "skill-size-preflight.sh",
		timeoutMs: 10_000,
		envelope: () => ({ hook_event_name: "SessionStart", source: "startup" }),
	},
];

const STOP_SCRIPTS: ReadonlyArray<{ script: string; timeoutMs: number }> = [
	{ script: "spec-gate.sh", timeoutMs: 15_000 },
	{ script: "decision-receipt.sh", timeoutMs: 15_000 },
	{ script: "stop-verify.sh", timeoutMs: 300_000 },
	{ script: "code-review-subagent.sh", timeoutMs: 120_000 },
	{ script: "propose-rules.sh", timeoutMs: 60_000 },
	{ script: "ui-verify.sh", timeoutMs: 120_000 },
	{ script: "stamp-turn.sh", timeoutMs: 5_000 },
];

const SAVE_CONTEXT_LOG = "save-context-log.sh";
const POST_COMPACT_CONTEXT = "post-compact-context.sh";

// ============================================================================
// Pure helpers (exported for unit tests)
// ============================================================================

/**
 * Compatibility helper for embedding callers. The legacy environment argument
 * remains in the public signature but is deliberately ignored: only a supplied
 * immutable payload path may resolve. Default OMP lifecycle resolution uses
 * `resolveTrellisRuntime` below instead.
 */
export function resolveTrellisRoot(
	moduleDir: string,
	_env: Record<string, string | undefined>,
): string | undefined {
	let dir = path.resolve(moduleDir);
	for (;;) {
		const payloadRoot = immutablePayloadIdentity(dir);
		if (payloadRoot && canonicalHooksDirectory(payloadRoot)) return payloadRoot;
		const parent = path.dirname(dir);
		if (parent === dir) return undefined;
		dir = parent;
	}
}

const SEMVER = /^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-((0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*)(\.(0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*))*))?(\+([0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*))?$/;
const GIT_OID = /^[a-f0-9]{40}$/;
const MANAGED_OMP_ADAPTER_TARGET = "../../../.trellis/runtime/core-rules/omp/hooks/pre/trellis.ts";

interface ReleaseTreeEntry {
	path: string;
	mode: "100644" | "100755" | "120000";
	oid: string;
}

interface ReleaseRecord {
	version: string;
	tree: ReleaseTreeEntry[];
}

interface ReleaseMetadata {
	record: ReleaseRecord;
	fingerprint: string;
	stat: fs.Stats;
}

interface PayloadEntry {
	fullPath: string;
	stat: fs.Stats;
}

interface PayloadInspection {
	files: Map<string, PayloadEntry>;
	directories: Map<string, PayloadEntry>;
	fingerprint: string;
}

interface ImmutablePayloadCacheEntry {
	releaseFingerprint: string;
	payloadFingerprint: string;
}

const immutablePayloadCache = new Map<string, ImmutablePayloadCacheEntry>();

function pathIsContained(root: string, candidate: string): boolean {
	const relative = path.relative(root, candidate);
	return relative.length === 0 || (!path.isAbsolute(relative) && relative !== ".." && !relative.startsWith(`..${path.sep}`));
}

function hasExactKeys(record: Record<string, unknown>, expected: string[]): boolean {
	const actual = Object.keys(record).sort();
	const sortedExpected = [...expected].sort();
	return actual.length === sortedExpected.length && actual.every((key, index) => key === sortedExpected[index]);
}

function isSafeReleasePath(candidate: string): boolean {
	if (
		candidate.length === 0 ||
		candidate.startsWith("/") ||
		candidate.endsWith("/") ||
		candidate.includes("//") ||
		candidate.includes("\0") ||
		candidate.includes("\t") ||
		candidate.includes("\n") ||
		candidate.includes("\r")
	) {
		return false;
	}
	return candidate.split("/").every((component) => component !== "." && component !== ".." && component.length > 0);
}

function isSafeReleaseSymlinkTarget(linkPath: string, target: string): boolean {
	if (
		target.length === 0 ||
		path.posix.isAbsolute(target) ||
		target.includes("//") ||
		target.includes("\0") ||
		target.includes("\t") ||
		target.includes("\n") ||
		target.includes("\r")
	) {
		return false;
	}
	const resolved = path.posix.normalize(path.posix.join(path.posix.dirname(linkPath), target));
	return !path.posix.isAbsolute(resolved) && resolved !== ".." && !resolved.startsWith("../");
}

function statFingerprint(stat: fs.Stats): string {
	return [stat.dev, stat.ino, stat.mode, stat.size, stat.mtimeMs, stat.ctimeMs].join(":");
}

function releaseRecordFromBytes(bytes: Buffer): ReleaseRecord | undefined {
	let parsed: unknown;
	try {
		parsed = JSON.parse(bytes.toString("utf8"));
	} catch {
		return undefined;
	}
	const release = asRecord(parsed);
	if (!release) return undefined;
	const rootKeys =
		typeof release.$schema === "string" && release.$schema.length > 0
			? ["$schema", "schema_version", "version", "tag", "commit", "remote", "tree"]
			: ["schema_version", "version", "tag", "commit", "remote", "tree"];
	if (
		!hasExactKeys(release, rootKeys) ||
		release.schema_version !== 1 ||
		typeof release.version !== "string" ||
		!SEMVER.test(release.version) ||
		release.tag !== `v${release.version}` ||
		typeof release.commit !== "string" ||
		!GIT_OID.test(release.commit) ||
		typeof release.remote !== "string" ||
		release.remote.length === 0 ||
		!Array.isArray(release.tree) ||
		release.tree.length === 0
	) {
		return undefined;
	}

	const paths = new Set<string>();
	const tree: ReleaseTreeEntry[] = [];
	for (const rawEntry of release.tree) {
		const entry = asRecord(rawEntry);
		if (
			!entry ||
			!hasExactKeys(entry, ["path", "mode", "oid"]) ||
			typeof entry.path !== "string" ||
			!isSafeReleasePath(entry.path) ||
			(entry.mode !== "100644" && entry.mode !== "100755" && entry.mode !== "120000") ||
			typeof entry.oid !== "string" ||
			!GIT_OID.test(entry.oid) ||
			paths.has(entry.path)
		) {
			return undefined;
		}
		paths.add(entry.path);
		tree.push({ path: entry.path, mode: entry.mode, oid: entry.oid });
	}
	return { version: release.version, tree };
}

function readReleaseMetadata(releaseJson: string): ReleaseMetadata | undefined {
	try {
		const stat = fs.lstatSync(releaseJson);
		if (!stat.isFile() || stat.isSymbolicLink()) return undefined;
		const bytes = fs.readFileSync(releaseJson);
		const record = releaseRecordFromBytes(bytes);
		if (!record) return undefined;
		return {
			record,
			fingerprint: `${statFingerprint(stat)}\0${bytes.toString("base64")}`,
			stat,
		};
	} catch {
		return undefined;
	}
}

function inspectPayloadTree(releaseDir: string, payloadRoot: string): PayloadInspection {
	const files = new Map<string, PayloadEntry>();
	const directories = new Map<string, PayloadEntry>();
	const state: string[] = [`release:${statFingerprint(fs.lstatSync(releaseDir))}`];

	function inspectDirectory(directory: string, relativeDirectory: string): void {
		const stat = fs.lstatSync(directory);
		if (!stat.isDirectory() || stat.isSymbolicLink()) {
			throw new Error(`invalid release payload directory: ${directory}`);
		}
		if (relativeDirectory.length > 0) {
			directories.set(relativeDirectory, { fullPath: directory, stat });
			state.push(JSON.stringify(["directory", relativeDirectory, statFingerprint(stat)]));
		} else {
			state.push(JSON.stringify(["payload", statFingerprint(stat)]));
		}
		for (const name of fs.readdirSync(directory).sort()) {
			const fullPath = path.join(directory, name);
			const relativePath = relativeDirectory.length > 0 ? `${relativeDirectory}/${name}` : name;
			const entry = fs.lstatSync(fullPath);
			if (entry.isDirectory()) {
				inspectDirectory(fullPath, relativePath);
				continue;
			}
			if (!entry.isFile() && !entry.isSymbolicLink()) {
				throw new Error(`unexpected release payload content type: ${relativePath}`);
			}
			files.set(relativePath, { fullPath, stat: entry });
			state.push(
				JSON.stringify([
					entry.isSymbolicLink() ? "symlink" : "file",
					relativePath,
					statFingerprint(entry),
					entry.isSymbolicLink() ? fs.readlinkSync(fullPath) : "",
				]),
			);
		}
	}

	inspectDirectory(payloadRoot, "");
	return { files, directories, fingerprint: state.join("\n") };
}

function expectedPayloadDirectories(tree: ReleaseTreeEntry[]): Set<string> {
	const directories = new Set<string>();
	for (const entry of tree) {
		const parts = entry.path.split("/");
		for (let index = 1; index < parts.length; index += 1) {
			directories.add(parts.slice(0, index).join("/"));
		}
	}
	return directories;
}

function samePaths(actual: Iterable<string>, actualSize: number, expected: Set<string>): boolean {
	if (actualSize !== expected.size) return false;
	for (const entry of actual) {
		if (!expected.has(entry)) return false;
	}
	return true;
}

function payloadPathForReleaseEntry(payloadRoot: string, relativePath: string): string | undefined {
	const fullPath = path.resolve(payloadRoot, relativePath);
	if (!pathIsContained(payloadRoot, fullPath) || fullPath === payloadRoot) return undefined;
	let current = payloadRoot;
	const components = relativePath.split("/");
	for (const component of components.slice(0, -1)) {
		current = path.join(current, component);
		const stat = fs.lstatSync(current);
		if (!stat.isDirectory() || stat.isSymbolicLink()) return undefined;
	}
	return fullPath;
}

function payloadMode(stat: fs.Stats): ReleaseTreeEntry["mode"] | undefined {
	if (stat.isSymbolicLink()) return "120000";
	if (!stat.isFile()) return undefined;
	return (stat.mode & 0o111) === 0 ? "100644" : "100755";
}

function gitBlobOid(content: Buffer): string {
	return createHash("sha1").update(`blob ${content.length}\0`).update(content).digest("hex");
}

function isWritable(stat: fs.Stats): boolean {
	return (stat.mode & 0o222) !== 0;
}

function verifyImmutablePayload(
	releaseDir: string,
	payloadRoot: string,
	metadata: ReleaseMetadata,
	inspection: PayloadInspection,
): boolean {
	const topLevel = fs.readdirSync(releaseDir).sort();
	if (
		topLevel.length !== 2 ||
		topLevel[0] !== "payload" ||
		topLevel[1] !== "release.json" ||
		isWritable(fs.lstatSync(releaseDir)) ||
		isWritable(metadata.stat)
	) {
		return false;
	}

	const manifestPaths = new Set(metadata.record.tree.map((entry) => entry.path));
	if (
		!samePaths(inspection.files.keys(), inspection.files.size, manifestPaths) ||
		!samePaths(
			inspection.directories.keys(),
			inspection.directories.size,
			expectedPayloadDirectories(metadata.record.tree),
		)
	) {
		return false;
	}

	for (const directory of inspection.directories.values()) {
		if (isWritable(directory.stat)) return false;
	}
	if (isWritable(fs.lstatSync(payloadRoot))) return false;

	for (const expected of metadata.record.tree) {
		const actual = inspection.files.get(expected.path);
		const fullPath = payloadPathForReleaseEntry(payloadRoot, expected.path);
		if (!actual || !fullPath || actual.fullPath !== fullPath || payloadMode(actual.stat) !== expected.mode) {
			return false;
		}
		let content: Buffer;
		if (actual.stat.isSymbolicLink()) {
			const target = fs.readlinkSync(actual.fullPath);
			if (!isSafeReleaseSymlinkTarget(expected.path, target)) return false;
			content = Buffer.from(target);
		} else {
			if (isWritable(actual.stat)) return false;
			content = fs.readFileSync(actual.fullPath);
		}
		if (gitBlobOid(content) !== expected.oid) return false;
	}
	return true;
}

function immutablePayloadIdentity(candidate: string): string | undefined {
	let payloadRoot: string | undefined;
	try {
		payloadRoot = fs.realpathSync(candidate);
		if (!fs.lstatSync(payloadRoot).isDirectory() || path.basename(payloadRoot) !== "payload") return undefined;
		const releaseDir = path.dirname(payloadRoot);
		const releaseStat = fs.lstatSync(releaseDir);
		const payloadPath = path.join(releaseDir, "payload");
		if (
			!path.isAbsolute(releaseDir) ||
			!releaseStat.isDirectory() ||
			releaseStat.isSymbolicLink() ||
			fs.lstatSync(payloadPath).isSymbolicLink() ||
			fs.realpathSync(payloadPath) !== payloadRoot
		) {
			return undefined;
		}
		const metadata = readReleaseMetadata(path.join(releaseDir, "release.json"));
		if (
			!metadata ||
			path.basename(releaseDir) !== metadata.record.version ||
			path.basename(path.dirname(releaseDir)) !== "releases"
		) {
			return undefined;
		}
		const inspection = inspectPayloadTree(releaseDir, payloadRoot);
		const cached = immutablePayloadCache.get(payloadRoot);
		if (
			cached?.releaseFingerprint === metadata.fingerprint &&
			cached.payloadFingerprint === inspection.fingerprint
		) {
			return payloadRoot;
		}
		if (!verifyImmutablePayload(releaseDir, payloadRoot, metadata, inspection)) {
			immutablePayloadCache.delete(payloadRoot);
			return undefined;
		}
		immutablePayloadCache.set(payloadRoot, {
			releaseFingerprint: metadata.fingerprint,
			payloadFingerprint: inspection.fingerprint,
		});
		return payloadRoot;
	} catch {
		if (payloadRoot) immutablePayloadCache.delete(payloadRoot);
		return undefined;
	}
}

function canonicalHooksDirectory(payloadRoot: string): string | undefined {
	try {
		const coreRules = path.join(payloadRoot, "core-rules");
		const hooksDir = path.join(coreRules, "hooks");
		const coreRulesStat = fs.lstatSync(coreRules);
		const hooksStat = fs.lstatSync(hooksDir);
		if (
			!coreRulesStat.isDirectory() ||
			coreRulesStat.isSymbolicLink() ||
			!hooksStat.isDirectory() ||
			hooksStat.isSymbolicLink()
		) {
			return undefined;
		}
		const canonicalHooks = fs.realpathSync(hooksDir);
		return canonicalHooks === hooksDir && pathIsContained(payloadRoot, canonicalHooks) ? canonicalHooks : undefined;
	} catch {
		return undefined;
	}
}

function pathsResolveToSameTarget(left: string, right: string): boolean {
	try {
		return fs.realpathSync(left) === fs.realpathSync(right);
	} catch {
		return false;
	}
}

function hasOmpAdapterLeaf(projectDir: string): boolean {
	try {
		const adapterLeaf = path.join(projectDir, ".omp", "hooks", "pre", "trellis.ts");
		const entry = fs.lstatSync(adapterLeaf);
		return entry.isSymbolicLink() && fs.readlinkSync(adapterLeaf) === MANAGED_OMP_ADAPTER_TARGET;
	} catch {
		return false;
	}
}

function isGitProjectRoot(candidate: string): boolean {
	try {
		const git = fs.lstatSync(path.join(candidate, ".git"));
		return git.isDirectory() || git.isFile();
	} catch {
		return false;
	}
}

function nearestProjectBoundary(startDir: string): string {
	let current = startDir;
	for (;;) {
		if (isGitProjectRoot(current)) return current;
		const parent = path.dirname(current);
		if (parent === current) return current;
		current = parent;
	}
}

export interface TrellisRuntime {
	projectDir: string;
	trellisRoot: string;
	hooksDir: string;
}

/**
 * Resolve an explicitly attached OMP project's immutable runtime. A project
 * with no managed OMP adapter leaf is intentionally inert. Once that leaf is
 * present, every invalid anchor state is a named failure rather than a fallback
 * to a mutable checkout.
 */
export function resolveTrellisRuntime(startDir: string): TrellisRuntime | undefined {
	if (typeof startDir !== "string" || startDir.length === 0) return undefined;
	const boundary = nearestProjectBoundary(path.resolve(startDir));
	let projectDir = path.resolve(startDir);
	for (;;) {
		if (hasOmpAdapterLeaf(projectDir)) {
			const trellisRoot = path.join(projectDir, ".trellis", "runtime");
			let anchor: fs.Stats;
			try {
				anchor = fs.lstatSync(trellisRoot);
			} catch {
				throw new Error(`trellis adapter: attached OMP project is missing immutable runtime anchor at ${trellisRoot}`);
			}
			if (!anchor.isSymbolicLink()) {
				throw new Error(`trellis adapter: attached OMP runtime anchor is not a symlink at ${trellisRoot}`);
			}
			const payloadRoot = immutablePayloadIdentity(trellisRoot);
			if (!payloadRoot) {
				throw new Error(`trellis adapter: attached OMP runtime anchor does not resolve to an immutable payload at ${trellisRoot}`);
			}
			const hooksDir = path.join(trellisRoot, "core-rules", "hooks");
			const canonicalHooks = canonicalHooksDirectory(payloadRoot);
			if (!canonicalHooks || !pathsResolveToSameTarget(hooksDir, canonicalHooks)) {
				throw new Error(`trellis adapter: attached OMP immutable payload lacks canonical hooks at ${hooksDir}`);
			}
			return { projectDir, trellisRoot, hooksDir };
		}
		if (projectDir === boundary) return undefined;
		projectDir = path.dirname(projectDir);
	}
}

/** Map an OMP tool name to the canonical Claude tool name, or undefined. */
export function canonicalToolName(ompName: string): string | undefined {
	return CLAUDE_TOOL_NAME[ompName];
}

function firstString(...values: unknown[]): string {
	for (const value of values) {
		if (typeof value === "string" && value.length > 0) return value;
	}
	return "";
}

/**
 * Extract the canonical `tool_input` fields a script reads from an OMP tool
 * call/result input. OMP uses `path`; the canonical envelope uses `file_path`.
 */
export function normalizeToolInput(
	ompToolName: string,
	input: Record<string, unknown> | undefined,
): Record<string, unknown> {
	const raw = input ?? {};
	const normalized: Record<string, unknown> = {};
	switch (ompToolName) {
		case "bash":
			normalized.command = typeof raw.command === "string" ? raw.command : "";
			break;
		case "skill":
			normalized.skill = firstString(raw.skill, raw.name);
			break;
		default: {
			const filePath = firstString(raw.path, raw.file_path, raw.filePath, raw.file);
			if (filePath) normalized.file_path = filePath;
			if (typeof raw.pattern === "string" && raw.pattern.length > 0) normalized.pattern = raw.pattern;
			break;
		}
	}
	return normalized;
}

/** Extract every file touched by an OMP hashline edit patch. */
export function editPatchPaths(input: Record<string, unknown> | undefined): string[] {
	const raw = input ?? {};
	const patch = firstString(raw.input, raw.patch, raw.content, raw.text);
	if (!patch) {
		const explicit = firstString(raw.path, raw.file_path, raw.filePath, raw.file);
		return explicit ? [explicit] : [];
	}
	const paths: string[] = [];
	const seen = new Set<string>();
	for (const match of patch.matchAll(/^\[([^#\]\r\n]+)#[0-9A-F]{4}\]$/gm)) {
		const filePath = (match[1] ?? "").trim();
		if (!filePath || seen.has(filePath)) continue;
		seen.add(filePath);
		paths.push(filePath);
	}
	return paths;
}

function normalizedToolInputs(
	ompToolName: string,
	input: Record<string, unknown> | undefined,
): Record<string, unknown>[] {
	if (ompToolName !== "edit") return [normalizeToolInput(ompToolName, input)];
	return editPatchPaths(input).map((filePath) => ({ file_path: filePath }));
}

/** Join OMP tool-result content blocks into the `tool_response` string scripts read. */
export function toolResponseText(content: unknown[] | undefined): string {
	if (!Array.isArray(content)) return "";
	const parts: string[] = [];
	for (const block of content) {
		if (block === null || typeof block !== "object") continue;
		if (!("type" in block) || !("text" in block)) continue;
		if (block.type !== "text" || typeof block.text !== "string") continue;
		parts.push(block.text);
	}
	return parts.join("\n");
}

export type HookDecision =
	| { kind: "block"; reason: string }
	| { kind: "context"; context: string }
	| { kind: "error"; message: string }
	| { kind: "pass" };

/**
 * Parse a canonical hook run into a decision.
 *
 * Recognized outputs (stdout, last JSON line wins; hooks emit exactly one JSON
 * line and may precede it with warnings):
 *   - `{"hookSpecificOutput":{"permissionDecision":"deny","permissionDecisionReason":…}}`
 *     (Claude PreToolUse denial)
 *   - `{"decision":"block","reason":…}` (PostToolUse/Stop/slash guard; exit may
 *     be 0 or 2)
 *   - `{"additionalContext":…}` or `{"hookSpecificOutput":{"additionalContext":…}}`
 *     (advisory)
 * Fallbacks: exit 2 with stderr -> block; any other non-zero exit or spawn
 * failure with no parseable JSON -> error (never silently pass as parity).
 */
export function parseHookOutput(
	result: { stdout: string; stderr: string; status: number | null },
	script: string,
): HookDecision {
	const payload = lastJsonLine(result.stdout);
	if (payload !== undefined) {
		const blockReason = decisionBlockReason(payload);
		if (blockReason) return { kind: "block", reason: blockReason };
		const context = decisionContext(payload);
		if (context) return { kind: "context", context };
	}
	if (result.status === 2 && result.stderr.trim().length > 0) {
		return { kind: "block", reason: result.stderr.split(/\r?\n/, 1)[0] ?? result.stderr };
	}
	if (result.status === null) {
		// Spawn/run failure (missing script, timeout, ENOENT) — never pass as parity.
		const detail = result.stderr.trim() || "script failed to run";
		return { kind: "error", message: `${script}: ${detail}` };
	}
	if (result.status !== 0) {
		const detail = result.stderr.trim() || "no output";
		const firstLine = detail.split(/\r?\n/, 1)[0] ?? detail;
		return { kind: "error", message: `${script}: exit ${String(result.status)}: ${firstLine}` };
	}
	return { kind: "pass" };
}

function lastJsonLine(stdout: string): Record<string, unknown> | undefined {
	const lines = stdout.split("\n");
	for (let i = lines.length - 1; i >= 0; i -= 1) {
		const line = lines[i]?.trim() ?? "";
		if (line.length === 0) continue;
		try {
			const parsed: unknown = JSON.parse(line);
			if (parsed !== null && typeof parsed === "object" && !Array.isArray(parsed)) {
				return parsed as Record<string, unknown>;
			}
		} catch {
			// Not JSON — keep scanning; a warning line must not shadow a decision.
		}
	}
	return undefined;
}

function decisionBlockReason(payload: Record<string, unknown>): string | undefined {
	const hookOutput = asRecord(payload.hookSpecificOutput);
	if (hookOutput !== undefined && hookOutput.permissionDecision === "deny") {
		return firstString(hookOutput.permissionDecisionReason, "denied by Trellis hook");
	}
	if (payload.decision === "block") {
		return firstString(payload.reason, "blocked by Trellis hook");
	}
	return undefined;
}

function decisionContext(payload: Record<string, unknown>): string | undefined {
	const direct = payload.additionalContext;
	if (typeof direct === "string" && direct.length > 0) return direct;
	const hookOutput = asRecord(payload.hookSpecificOutput);
	const nested = hookOutput?.additionalContext;
	if (typeof nested === "string" && nested.length > 0) return nested;
	return undefined;
}

function asRecord(value: unknown): Record<string, unknown> | undefined {
	return value !== null && typeof value === "object" && !Array.isArray(value)
		? (value as Record<string, unknown>)
		: undefined;
}

/** Build a Claude-shaped JSONL transcript from OMP session messages. */
export function buildTranscriptJsonl(messages: unknown[]): string {
	const lines: string[] = [];
	for (const message of messages) {
		let role = "unknown";
		let normalizedMessage = message ?? null;
		if (message !== null && typeof message === "object" && "role" in message && typeof message.role === "string") {
			role = message.role;
			if ("content" in message && role === "user" && Array.isArray(message.content)) {
				const content = message.content
					.filter(
						(block): block is { type: "text"; text: string } =>
							block !== null &&
							typeof block === "object" &&
							"type" in block &&
							block.type === "text" &&
							"text" in block &&
							typeof block.text === "string",
					)
					.map((block) => block.text)
					.join("\n");
				normalizedMessage = { ...message, content };
			} else if ("content" in message && role === "assistant" && typeof message.content === "string") {
				normalizedMessage = { ...message, content: [{ type: "text", text: message.content }] };
			}
		}
		lines.push(JSON.stringify({ type: role, message: normalizedMessage }));
	}
	return lines.length === 0 ? "" : `${lines.join("\n")}\n`;
}

/**
 * First non-empty line of the project CLAUDE.md (padded with the second when
 * the first is too short) — the distinctive marker used to decide whether a
 * session's system prompt already carries the live project policy. Undefined
 * when there is no policy text to inject.
 */
export function policyMarker(claudeMd: string): string | undefined {
	const lines = claudeMd
		.split(/\r?\n/)
		.map((line) => line.trim())
		.filter((line) => line.length > 0);
	if (lines.length === 0) return undefined;
	let marker = lines[0] ?? "";
	if (marker.length < 16 && lines.length > 1) marker = `${marker}\n${lines[1] ?? ""}`;
	return marker;
}

/**
 * Whether the session's system prompt already contains the live project policy.
 * An absent marker (no policy to inject) counts as satisfied.
 */
export function systemPromptHasPolicy(systemPrompt: string[] | undefined, marker: string | undefined): boolean {
	if (!marker) return true;
	const needle = marker.replace(/\s+/g, " ").trim();
	if (needle.length === 0) return true;
	const haystack = (systemPrompt ?? []).join("\n").replace(/\s+/g, " ").trim();
	return haystack.includes(needle);
}

const TRELLIS_ORCHESTRATION_STYLE_PATH = path.join(
	"core-rules",
	"templates",
	"claude-output-styles",
	"trellis-orchestration.md",
);

/**
 * Read the release-owned orchestration style without exposing its YAML
 * frontmatter to OMP. A style is valid only when it starts with a frontmatter
 * opener and has a standalone `---` closing line.
 */
export function readTrellisOrchestrationStyle(trellisRoot: string): string | undefined {
	let source: string;
	try {
		source = fs.readFileSync(path.join(trellisRoot, TRELLIS_ORCHESTRATION_STYLE_PATH), "utf8");
	} catch {
		return undefined;
	}
	const frontmatter = source.match(/^---\r?\n[\s\S]*?\r?\n---(?:\r?\n|$)/);
	if (!frontmatter) return undefined;
	const body = source.slice(frontmatter[0].length).trim();
	return body.length > 0 ? body : undefined;
}

/**
 * Live Trellis preset policies enabled for this project. Claude Code loads the
 * managed `.claude/rules/preset-*.md` links natively; OMP does not, so the
 * adapter adds only links that resolve inside the canonical presets root.
 */
export function trellisPresetPolicies(projectDir: string, trellisRoot: string): string[] {
	const rulesDir = path.join(projectDir, ".claude", "rules");
	const presetsDir = path.join(trellisRoot, "core-rules", "presets");
	let presetRoot: string;
	let names: string[];
	try {
		presetRoot = fs.realpathSync(presetsDir);
		names = fs.readdirSync(rulesDir).filter((name) => /^preset-[a-z0-9][a-z0-9-]*\.md$/.test(name));
	} catch {
		return [];
	}

	const policies: string[] = [];
	for (const name of names.sort()) {
		const rulePath = path.join(rulesDir, name);
		try {
			const resolved = fs.realpathSync(rulePath);
			const relative = path.relative(presetRoot, resolved);
			if (relative.length === 0 || path.isAbsolute(relative) || relative === ".." || relative.startsWith(`..${path.sep}`)) {
				continue;
			}
			const content = fs.readFileSync(resolved, "utf8");
			if (content.trim().length > 0) policies.push(content);
		} catch {
			// A broken or unreadable optional preset is reported by doctor; the
			// adapter must not replace it with guessed policy.
		}
	}
	return policies;
}


/** Extract the slash-command name from user input (`/name args`), if any. */
export function slashCommandName(text: string): string | undefined {
	if (typeof text !== "string") return undefined;
	const match = text.match(/^\/([A-Za-z0-9][A-Za-z0-9_-]*)(?:\s|$)/);
	return match?.[1];
}

export interface RunHookOptions {
	hooksDir: string;
	trellisRoot: string;
	script: string;
	projectDir: string;
	envelope: Record<string, unknown>;
	timeoutMs: number;
	/** When set, exported as CLAUDE_TRANSCRIPT_PATH (Claude Code env channel). */
	transcriptPath?: string;
	env?: Record<string, string>;
}

export interface RunHookResult {
	stdout: string;
	stderr: string;
	status: number | null;
	scriptPath: string;
}

export type SpawnFn = (
	command: string,
	args: string[],
	options: SpawnSyncOptionsWithStringEncoding,
) => SpawnSyncReturns<string>;

function canonicalHookScriptPath(options: RunHookOptions): string | undefined {
	try {
		if (!isSafeReleasePath(options.script)) return undefined;
		const payloadRoot = immutablePayloadIdentity(options.trellisRoot);
		if (!payloadRoot) return undefined;
		const canonicalHooks = canonicalHooksDirectory(payloadRoot);
		if (!canonicalHooks || !pathsResolveToSameTarget(options.hooksDir, canonicalHooks)) return undefined;
		const requestedScript = path.join(options.hooksDir, options.script);
		const canonicalScript = fs.realpathSync(requestedScript);
		if (!pathIsContained(payloadRoot, canonicalScript) || !fs.statSync(canonicalScript).isFile()) return undefined;
		return canonicalScript;
	} catch {
		return undefined;
	}
}

/**
 * Execute a live canonical hook with the normalized envelope on stdin.
 * `CLAUDE_PROJECT_DIR` and `TRELLIS_ROOT` are exported for every script, plus
 * `CLAUDE_TRANSCRIPT_PATH` when a transcript is provided and `TRELLIS_OMP=1`
 * so model-backed scripts take their non-Anthropic OMP route. A missing script
 * yields a non-null-status-style error result carrying the exact path — callers
 * decide the fail-closed mapping.
 */
export function runCanonicalHook(options: RunHookOptions, spawn: SpawnFn = spawnSync): RunHookResult {
	const requestedScript = path.join(options.hooksDir, options.script);
	if (!fs.existsSync(requestedScript)) {
		return { stdout: "", stderr: `missing canonical hook: ${requestedScript}`, status: null, scriptPath: requestedScript };
	}
	const scriptPath = canonicalHookScriptPath(options);
	if (!scriptPath) {
		return {
			stdout: "",
			stderr: `canonical hook escapes immutable payload: ${requestedScript}`,
			status: null,
			scriptPath: requestedScript,
		};
	}
	let result: SpawnSyncReturns<string>;
	try {
		result = spawn("/bin/bash", [scriptPath], {
			input: JSON.stringify(options.envelope),
			encoding: "utf8",
			timeout: options.timeoutMs,
			env: {
				...process.env,
				CLAUDE_PROJECT_DIR: options.projectDir,
				TRELLIS_ROOT: options.trellisRoot,
				// Harness marker consumed by lib/omp-reviewer.sh and propose-rules.sh:
				// "you are running under OMP — never shell out to claude."
				TRELLIS_OMP: "1",
				...(options.transcriptPath ? { CLAUDE_TRANSCRIPT_PATH: options.transcriptPath } : {}),
				...(options.env ?? {}),
			},
		});
	} catch (error) {
		return {
			stdout: "",
			stderr: `failed to spawn ${scriptPath}: ${error instanceof Error ? error.message : String(error)}`,
			status: null,
			scriptPath,
		};
	}
	if (result.error) {
		return {
			stdout: "",
			stderr: `failed to run ${scriptPath}: ${result.error.message}`,
			status: null,
			scriptPath,
		};
	}
	return {
		stdout: result.stdout ?? "",
		stderr: result.stderr ?? "",
		status: result.status,
		scriptPath,
	};
}

// ============================================================================
// Adapter core
// ============================================================================

export interface TrellisAdapterOptions {
	/** Attached runtime anchor or verified immutable payload root. */
	trellisRoot: string;
	/** Must resolve to `trellisRoot/core-rules/hooks`. */
	hooksDir: string;
	logger?: OmpLogger;
	/** Override for transcript temp files (default os.tmpdir()). */
	tmpDir?: string;
	/** Injectable spawn for tests. */
	spawn?: SpawnFn;
}

export interface TrellisAdapter {
	onInput(event: OmpInputEvent, ctx: OmpContext): Promise<InputResult | undefined>;
	onToolCall(event: OmpToolCallEvent, ctx: OmpContext): Promise<ToolCallResult | undefined>;
	onToolResult(event: OmpToolResultEvent, ctx: OmpContext): Promise<ToolResultPatch | undefined>;
	onBeforeAgentStart(event: OmpBeforeAgentStartEvent, ctx: OmpContext): Promise<AgentStartResult | undefined>;
	onBeforeCompact(event: OmpSessionBeforeCompactEvent, ctx: OmpContext): Promise<CompactResult | undefined>;
	onCompact(event: OmpSessionCompactEvent, ctx: OmpContext): Promise<string | undefined>;
	onShutdown(event: OmpSessionShutdownEvent, ctx: OmpContext): Promise<void>;
	onStop(event: OmpSessionStopEvent, ctx: OmpContext): Promise<StopResult | undefined>;
}

/**
 * Create the adapter from an explicitly supplied immutable payload. A broken,
 * mismatched, or mutable source input must never silently run as canonical
 * policy.
 */
export function createTrellisAdapter(options: TrellisAdapterOptions): TrellisAdapter {
	const payloadRoot = immutablePayloadIdentity(options.trellisRoot);
	const canonicalHooks = payloadRoot ? canonicalHooksDirectory(payloadRoot) : undefined;
	if (!canonicalHooks || !pathsResolveToSameTarget(options.hooksDir, canonicalHooks)) {
		throw new Error(
			`trellis adapter: canonical hooks directory missing or not from immutable payload at ${options.hooksDir} (root ${options.trellisRoot})`,
		);
	}
	const logger = options.logger ?? defaultLogger;
	const spawn = options.spawn ?? spawnSync;
	const tmpDir = options.tmpDir ?? os.tmpdir();
	const seenAgentStarts = new Set<string>();

	function projectDirFor(ctx: OmpContext): string | undefined {
		if (typeof ctx.cwd !== "string" || ctx.cwd.length === 0) return undefined;
		let current = path.resolve(ctx.cwd);
		for (;;) {
			if (fs.existsSync(path.join(current, ".omp", "AGENTS.md"))) return current;
			const parent = path.dirname(current);
			if (parent === current) return path.resolve(ctx.cwd);
			current = parent;
		}
	}

	function sessionIdOf(ctx: OmpContext): string {
		return ctx.sessionManager?.getSessionId?.() ?? ctx.cwd ?? "<unknown>";
	}

	function run(
		script: string,
		projectDir: string,
		envelope: Record<string, unknown>,
		timeoutMs: number,
		transcriptPath?: string,
		extraEnv?: Record<string, string>,
	): RunHookResult {
		return runCanonicalHook(
			{
				hooksDir: options.hooksDir,
				trellisRoot: options.trellisRoot,
				script,
				projectDir,
				envelope,
				timeoutMs,
				transcriptPath,
				env: extraEnv,
			},
			spawn,
		);
	}

	function logScriptFailure(script: string, message: string): void {
		logger.error(`trellis adapter: ${script} failed: ${message}`);
	}

	// One-time no-Anthropic guarantee check (hooks.md: OMP owns its stop
	// event; a model-backed hook reached from it must never inherit a Claude
	// default). runCanonicalHook exports TRELLIS_OMP=1 for every script; this
	// proves the plumbing through a real spawn so a regression here fails at
	// attach time, not silently on the first model-backed stop script. The
	// probe script ships in the canonical payload and echoes one env var.
	// Deliberately the REAL spawnSync, never the injectable `spawn`: an
	// injected fake could claim any output, making the proof vacuous. One real
	// ~5ms bash invocation at attach time is the cost of the guarantee.
	const markerProbe = runCanonicalHook(
		{
			hooksDir: options.hooksDir,
			trellisRoot: options.trellisRoot,
			script: "env-echo.sh",
			projectDir: options.trellisRoot,
			envelope: {},
			timeoutMs: 5_000,
			env: { TRELLIS_PROBE_VARS: "TRELLIS_OMP" },
		},
		spawnSync,
	);
	if (markerProbe.status !== 0 || !markerProbe.stdout.split("\n").includes("TRELLIS_OMP=1")) {
		throw new Error(
			`trellis adapter: TRELLIS_OMP=1 was not exported to canonical scripts (${markerProbe.stderr.trim() || "no marker in child environment"})`,
		);
	}

	// --- input: slash-skill size guard -------------------------------------
	async function onInput(event: OmpInputEvent, ctx: OmpContext): Promise<InputResult | undefined> {
		const commandName = slashCommandName(event.text);
		if (!commandName) return undefined;
		const projectDir = projectDirFor(ctx);
		if (!projectDir) return undefined;

		const result = run(
			"skill-slash-guard.sh",
			projectDir,
			{
				hook_event_name: "UserPromptExpansion",
				expansion_type: "slash_command",
				command_name: commandName,
			},
			5_000,
		);
		const decision = parseHookOutput(result, "skill-slash-guard.sh");
		if (decision.kind === "block") {
			// Consume the input: a denied slash command must not reach the agent.
			ctx.ui?.notify?.(decision.reason, "error");
			return { handled: true, text: "" };
		}
		if (decision.kind === "error") {
			logScriptFailure("skill-slash-guard.sh", decision.message);
		}
		return undefined;
	}

	// --- tool_call: destructive/secret, reread, and skill-preload gates -----
	async function onToolCall(event: OmpToolCallEvent, ctx: OmpContext): Promise<ToolCallResult | undefined> {
		const entry = PRE_TOOL_USE.find((candidate) => candidate.tool === event.toolName);
		if (!entry) return undefined; // unmanaged tool: safe pass-through
		const projectDir = projectDirFor(ctx);
		if (!projectDir) {
			return { block: true, reason: `trellis adapter: no project dir for tool_call (${event.toolName})` };
		}
		const toolName = canonicalToolName(event.toolName) ?? event.toolName;
		const toolInputs = normalizedToolInputs(event.toolName, event.input);
		if (event.toolName === "edit" && toolInputs.length === 0) {
			return { block: true, reason: "trellis adapter: cannot determine files in edit patch" };
		}
		for (const toolInput of toolInputs) {
			const result = run(
				entry.script,
				projectDir,
				{ tool_name: toolName, tool_input: toolInput },
				entry.timeoutMs,
			);
			const decision = parseHookOutput(result, entry.script);
			if (decision.kind === "block") {
				return { block: true, reason: decision.reason };
			}
			if (decision.kind === "error") {
				// Fail closed: an unresponsive/broken gate must never read as consent.
				return { block: true, reason: `trellis adapter: ${decision.message}` };
			}
		}
		return undefined;
	}

	// --- tool_result: post-edit, truncation, and read-tracking gates --------
	async function onToolResult(event: OmpToolResultEvent, ctx: OmpContext): Promise<ToolResultPatch | undefined> {
		const projectDir = projectDirFor(ctx);
		if (!projectDir) return undefined;
		const toolName = canonicalToolName(event.toolName);
		if (!toolName) return undefined;

		const toolInputs = normalizedToolInputs(event.toolName, event.input);
		if (event.toolName === "edit" && toolInputs.length === 0) {
			const reason = "trellis adapter: cannot determine files in completed edit patch";
			return { content: [{ type: "text", text: reason }, ...event.content], isError: true };
		}
		let isError = event.isError;
		const prepended: string[] = [];
		const appended: string[] = [];

		for (const entry of POST_TOOL_USE) {
			if (!entry.tools.includes(event.toolName)) continue;
			for (const toolInput of toolInputs) {
				const result = run(
					entry.script,
					projectDir,
					{
						tool_name: toolName,
						tool_input: toolInput,
						tool_response: toolResponseText(event.content),
					},
					entry.timeoutMs,
				);
				const decision = parseHookOutput(result, entry.script);
				if (decision.kind === "block") {
					isError = true;
					prepended.push(decision.reason);
				} else if (decision.kind === "context") {
					appended.push(decision.context);
				} else if (decision.kind === "error") {
					logScriptFailure(entry.script, decision.message);
				}
			}
		}

		if (isError === event.isError && appended.length === 0 && prepended.length === 0) return undefined;
		const content = [...event.content];
		for (const reason of prepended) content.unshift({ type: "text", text: reason });
		for (const context of appended) content.push({ type: "text", text: context });
		return { content, isError };
	}

	// --- before_agent_start (first per session): context + child policy -----
	async function onBeforeAgentStart(
		event: OmpBeforeAgentStartEvent,
		ctx: OmpContext,
	): Promise<AgentStartResult | undefined> {
		const sessionId = sessionIdOf(ctx);
		if (seenAgentStarts.has(sessionId)) return undefined;
		seenAgentStarts.add(sessionId);

		const projectDir = projectDirFor(ctx);
		if (!projectDir) return undefined;

		const sections: string[] = [];
		for (const entry of SESSION_START_SCRIPTS) {
			const result = run(entry.script, projectDir, entry.envelope(), entry.timeoutMs);
			const decision = parseHookOutput(result, entry.script);
			if (decision.kind === "context") {
				sections.push(decision.context);
			} else if (decision.kind === "error") {
				logScriptFailure(entry.script, decision.message);
			}
			// Session-start scripts never block; a block decision is logged only.
		}

		const result: AgentStartResult = {};
		if (sections.length > 0) {
			result.message = {
				customType: "trellis-session-context",
				content: sections.join("\n\n"),
				display: false,
			};
		}
		// Context parity: OMP task children exclude AGENTS.md from inherited
		// context files, and OMP does not natively load Claude's managed preset
		// rules. Append any missing project policy and the immutable payload
		// fallback used by the managed `.omp/AGENTS.md` link.
		const rootPolicyPath = path.join(projectDir, "CLAUDE.md");
		const policyPath = fs.existsSync(rootPolicyPath)
			? rootPolicyPath
			: path.join(options.trellisRoot, "core-rules", "CLAUDE.md");
		const systemPrompt = typeof ctx.getSystemPrompt === "function" ? ctx.getSystemPrompt() : event.systemPrompt;
		const additions: string[] = [];
		if (fs.existsSync(policyPath)) {
			let claudeMd: string;
			try {
				claudeMd = fs.readFileSync(policyPath, "utf8");
			} catch {
				claudeMd = "";
			}
			if (!systemPromptHasPolicy(systemPrompt, policyMarker(claudeMd)) && claudeMd.trim().length > 0) {
				additions.push(claudeMd);
			}
		}
		for (const preset of trellisPresetPolicies(projectDir, options.trellisRoot)) {
			if (!systemPromptHasPolicy([...(systemPrompt ?? []), ...additions], policyMarker(preset))) {
				additions.push(preset);
			}
		}
		const orchestrationStyle = readTrellisOrchestrationStyle(options.trellisRoot);
		if (!orchestrationStyle) {
			logger.error(
				`trellis adapter: release-owned orchestration style missing, malformed, or unreadable at ${path.join(
					options.trellisRoot,
					TRELLIS_ORCHESTRATION_STYLE_PATH,
				)}`,
			);
		} else if (
			!systemPromptHasPolicy(
				[...(systemPrompt ?? []), ...additions],
				policyMarker(orchestrationStyle),
			)
		) {
			additions.push(orchestrationStyle);
		}
		if (additions.length > 0) result.systemPrompt = [...(systemPrompt ?? []), ...additions];

		return Object.keys(result).length > 0 ? result : undefined;
	}

	// --- session_before_compact / session_shutdown: context-log preservation -
	function writeTranscript(messages: unknown[], sessionId: string, turnLabel: string): string | undefined {
		const jsonl = buildTranscriptJsonl(messages);
		const safeId = String(sessionId || "session").replace(/[^A-Za-z0-9._-]/g, "_");
		const safeTurn = String(turnLabel || "turn").replace(/[^A-Za-z0-9._-]/g, "_");
		const transcriptPath = path.join(
			tmpDir,
			`trellis-omp-${safeId}-${safeTurn}-${process.pid}-${Date.now().toString(36)}.jsonl`,
		);
		try {
			fs.writeFileSync(transcriptPath, jsonl, "utf8");
			return transcriptPath;
		} catch (error) {
			logger.error(
				`trellis adapter: cannot write transcript ${transcriptPath}: ${error instanceof Error ? error.message : String(error)}`,
			);
			return undefined;
		}
	}

	function removeTranscript(transcriptPath: string | undefined): void {
		if (!transcriptPath) return;
		try {
			fs.rmSync(transcriptPath, { force: true });
		} catch {
			// Best-effort temp cleanup; a stale transcript is harmless.
		}
	}

	function saveContextLog(ctx: OmpContext, messages: unknown[] = []): void {
		const projectDir = projectDirFor(ctx);
		if (!projectDir) return;
		const transcriptPath =
			messages.length > 0 ? writeTranscript(messages, sessionIdOf(ctx), "compact") : undefined;
		try {
			const result = run(
				SAVE_CONTEXT_LOG,
				projectDir,
				{ transcript_path: transcriptPath ?? "" },
				10_000,
				transcriptPath,
			);
			const decision = parseHookOutput(result, SAVE_CONTEXT_LOG);
			if (decision.kind === "error") {
				logScriptFailure(SAVE_CONTEXT_LOG, decision.message);
			}
		} finally {
			removeTranscript(transcriptPath);
		}
	}

	async function onBeforeCompact(
		event: OmpSessionBeforeCompactEvent,
		ctx: OmpContext,
	): Promise<CompactResult | undefined> {
		const preparation = event.preparation;
		const messages = [
			...(preparation?.messagesToSummarize ?? []),
			...(preparation?.turnPrefixMessages ?? []),
			...(preparation?.recentMessages ?? []),
		];
		saveContextLog(ctx, messages);
		return undefined; // never cancels compaction
	}

	async function onCompact(_event: OmpSessionCompactEvent, ctx: OmpContext): Promise<string | undefined> {
		const projectDir = projectDirFor(ctx);
		if (!projectDir) return undefined;
		const result = run(POST_COMPACT_CONTEXT, projectDir, { source: "compact" }, 5_000);
		const decision = parseHookOutput(result, POST_COMPACT_CONTEXT);
		if (decision.kind === "context") return decision.context;
		if (decision.kind === "error") logScriptFailure(POST_COMPACT_CONTEXT, decision.message);
		return undefined;
	}

	async function onShutdown(_event: OmpSessionShutdownEvent, ctx: OmpContext): Promise<void> {
		saveContextLog(ctx);
		seenAgentStarts.delete(sessionIdOf(ctx));
	}

	// --- session_stop: completion/testing/spec/review/UI receipts -----------

	async function onStop(event: OmpSessionStopEvent, ctx: OmpContext): Promise<StopResult | undefined> {
		// A continuation pass re-enters session_stop with stop_hook_active set;
		// the canonical hooks self-guard on it too — skip the whole adapter pass.
		if (event.stop_hook_active === true) return undefined;
		if (event.signal?.aborted === true) return undefined;
		const projectDir = projectDirFor(ctx);
		if (!projectDir) return undefined;

		const transcriptPath = writeTranscript(event.messages, event.session_id, String(event.turn_id));
		const envelope: Record<string, unknown> = {
			transcript_path: transcriptPath ?? "",
			session_id: event.session_id,
			stop_hook_active: event.stop_hook_active === true,
			session_file: event.session_file ?? "",
			last_assistant_message: event.last_assistant_message ?? null,
		};

		try {
			for (const entry of STOP_SCRIPTS) {
				const result = run(entry.script, projectDir, envelope, entry.timeoutMs, transcriptPath);
				const decision = parseHookOutput(result, entry.script);
				if (decision.kind === "block") {
					return { decision: "block", reason: decision.reason };
				}
				if (decision.kind === "error") {
					logScriptFailure(entry.script, decision.message);
					if (entry.script === "decision-receipt.sh") {
						return { decision: "block", reason: decision.message };
					}
				}
				// Advisory context on stop is deliberately not turned into a
				// continuation — that would burn an OMP continuation pass.
			}
			return undefined;
		} finally {
			removeTranscript(transcriptPath);
		}
	}

	return { onInput, onToolCall, onToolResult, onBeforeAgentStart, onBeforeCompact, onCompact, onShutdown, onStop };
}

const defaultLogger: OmpLogger = {
	warn(...args: unknown[]): void {
		console.warn(...args);
	},
	error(...args: unknown[]): void {
		console.error(...args);
	},
};

// ============================================================================
// OMP extension factory (default export)
// ============================================================================

/**
 * Default export consumed by the OMP extension loader. It resolves adapters
 * lazily from each event context's attached `.trellis/runtime` anchor, so a
 * raw project remains inert and no mutable source checkout can affect policy.
 */
export default function trellisExtension(pi: OmpApi): void {
	const adapters = new Map<string, TrellisAdapter>();
	let labeled = false;

	function adapterFor(ctx: OmpContext): TrellisAdapter | undefined {
		const runtime = resolveTrellisRuntime(ctx.cwd);
		if (!runtime) return undefined;
		const existing = adapters.get(runtime.projectDir);
		if (existing) return existing;
		const adapter = createTrellisAdapter({
			trellisRoot: runtime.trellisRoot,
			hooksDir: runtime.hooksDir,
			logger: pi.logger,
		});
		adapters.set(runtime.projectDir, adapter);
		if (!labeled) {
			pi.setLabel("Trellis canonical policy adapter");
			labeled = true;
		}
		return adapter;
	}

	pi.on("input", (event: unknown, ctx: OmpContext) => {
		return adapterFor(ctx)?.onInput(event as OmpInputEvent, ctx);
	});
	pi.on("tool_call", (event: unknown, ctx: OmpContext) => {
		return adapterFor(ctx)?.onToolCall(event as OmpToolCallEvent, ctx);
	});
	pi.on("tool_result", (event: unknown, ctx: OmpContext) => {
		return adapterFor(ctx)?.onToolResult(event as OmpToolResultEvent, ctx);
	});
	pi.on("before_agent_start", (event: unknown, ctx: OmpContext) => {
		return adapterFor(ctx)?.onBeforeAgentStart(event as OmpBeforeAgentStartEvent, ctx);
	});
	pi.on("session_before_compact", (event: unknown, ctx: OmpContext) => {
		return adapterFor(ctx)?.onBeforeCompact(event as OmpSessionBeforeCompactEvent, ctx);
	});
	pi.on("session_compact", async (event: unknown, ctx: OmpContext) => {
		const adapter = adapterFor(ctx);
		if (!adapter) return;
		const context = await adapter.onCompact(event as OmpSessionCompactEvent, ctx);
		if (!context) return;
		if (!pi.sendMessage) {
			pi.logger.error("trellis adapter: session_compact context could not be injected (sendMessage unavailable)");
			return;
		}
		pi.sendMessage(
			{ customType: "trellis-post-compact-context", content: context, display: false },
			{ triggerTurn: false },
		);
	});
	pi.on("session_shutdown", (event: unknown, ctx: OmpContext) => {
		return adapterFor(ctx)?.onShutdown(event as OmpSessionShutdownEvent, ctx);
	});
	pi.on("session_stop", (event: unknown, ctx: OmpContext) => {
		return adapterFor(ctx)?.onStop(event as OmpSessionStopEvent, ctx);
	});
}
