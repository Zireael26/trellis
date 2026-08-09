/**
 * trellis.ts — Oh My Pi extension factory bridging OMP lifecycle events to the
 * canonical Trellis shell hooks. Live runtime adapter; never copied policy.
 *
 * Source: Trellis / core-rules / omp hooks. Projects reach it via the
 * machine-local link `<project>/.omp/hooks -> <trellis_root>/core-rules/omp/hooks`
 * (see docs/specs/2026-08-09-omp-full-inheritance-design.md).
 *
 * Contract:
 *   - Default export is the OMP extension factory (`(pi: ExtensionAPI) => void`).
 *   - Resolves `trellis_root` at load time: `TRELLIS_ROOT` env (when it carries
 *     `core-rules/hooks`), else walk up from this module's own directory. An
 *     unresolvable setup throws — a dangling/wrong-root install must never
 *     silently pass as parity.
 *   - Resolves the project dir live per event from `ctx.cwd`.
 *   - Normalizes OMP events into the canonical Claude hook envelope and executes
 *     the live scripts under `<trellis_root>/core-rules/hooks` with
 *     `CLAUDE_PROJECT_DIR` and `TRELLIS_ROOT` exported.
 *   - Parses the scripts' decision JSON and maps it to OMP results:
 *       tool_call          -> `{block: true, reason}`      (fail closed)
 *       tool_result        -> `isError` + reason in content (gates), or
 *                             advisory context appended     (truncation)
 *       input              -> `{handled: true}`            (slash-command size denial)
 *       session_stop       -> `{decision: "block", reason}` (continuation request)
 *   - Injects the live project `CLAUDE.md` into sessions whose system prompt
 *     lacks it. Top-level sessions already carry it natively via
 *     `.omp/AGENTS.md -> <project>/CLAUDE.md`; OMP task children exclude
 *     `AGENTS.md` from inherited context files, so the marker check appends the
 *     policy to their system prompt before their first agent run.
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
import { spawnSync, type SpawnSyncOptionsWithStringEncoding, type SpawnSyncReturns } from "node:child_process";
import { fileURLToPath } from "node:url";

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
 * Resolve `trellis_root` for this adapter. `TRELLIS_ROOT` env wins when it
 * carries `core-rules/hooks`; otherwise walk up from `moduleDir` looking for an
 * ancestor that has a `core-rules/hooks` directory (the adapter itself lives at
 * `<trellis_root>/core-rules/omp/hooks/pre/`). Returns undefined when no valid
 * root exists — callers must refuse to operate in that case.
 */
export function resolveTrellisRoot(
	moduleDir: string,
	env: Record<string, string | undefined>,
): string | undefined {
	const fromEnv = env.TRELLIS_ROOT;
	if (fromEnv && isHooksDir(path.join(fromEnv, "core-rules", "hooks"))) {
		return fromEnv;
	}
	let dir = path.resolve(moduleDir);
	for (;;) {
		if (isHooksDir(path.join(dir, "core-rules", "hooks"))) {
			return dir;
		}
		const parent = path.dirname(dir);
		if (parent === dir) return undefined;
		dir = parent;
	}
}

function isHooksDir(candidate: string): boolean {
	try {
		return fs.statSync(candidate).isDirectory();
	} catch {
		return false;
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

/**
 * Execute a live canonical hook with the normalized envelope on stdin.
 * `CLAUDE_PROJECT_DIR` and `TRELLIS_ROOT` are exported for every script, plus
 * `CLAUDE_TRANSCRIPT_PATH` when a transcript is provided. A missing script
 * yields a non-null-status-style error result carrying the exact path — callers
 * decide the fail-closed mapping.
 */
export function runCanonicalHook(options: RunHookOptions, spawn: SpawnFn = spawnSync): RunHookResult {
	const scriptPath = path.join(options.hooksDir, options.script);
	if (!fs.existsSync(scriptPath)) {
		return { stdout: "", stderr: `missing canonical hook: ${scriptPath}`, status: null, scriptPath };
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
	trellisRoot: string;
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
 * Create the adapter. Throws when the canonical hooks directory is missing —
 * a broken/dangling Trellis install must not silently run with no policy.
 */
export function createTrellisAdapter(options: TrellisAdapterOptions): TrellisAdapter {
	if (!isHooksDir(options.hooksDir)) {
		throw new Error(
			`trellis adapter: canonical hooks directory missing at ${options.hooksDir} — re-run onboarding or fix the .omp/hooks link`,
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
			},
			spawn,
		);
	}

	function logScriptFailure(script: string, message: string): void {
		logger.error(`trellis adapter: ${script} failed: ${message}`);
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
		// rules. Append any missing live project policy and canonical presets
		// before the first run. The private control-plane checkout has no root
		// CLAUDE.md, so it points directly at canonical core-rules policy.
		const rootPolicyPath = path.join(projectDir, "CLAUDE.md");
		const policyPath =
			fs.existsSync(rootPolicyPath) || path.resolve(projectDir) !== path.resolve(options.trellisRoot)
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
 * Default export consumed by the OMP extension loader. Resolves trellis_root
 * from this module's location and wires the canonical event mappings. Throws on
 * an unresolvable root so a broken install surfaces as an extension load error
 * instead of silently passing as parity.
 */
export default function trellisExtension(pi: OmpApi): void {
	const moduleDir = path.dirname(fileURLToPath(import.meta.url));
	const trellisRoot = resolveTrellisRoot(moduleDir, process.env);
	if (!trellisRoot) {
		throw new Error(
			`trellis adapter: cannot resolve trellis_root (no TRELLIS_ROOT env and no core-rules/hooks ancestor of ${moduleDir})`,
		);
	}
	const hooksDir = path.join(trellisRoot, "core-rules", "hooks");
	const adapter = createTrellisAdapter({ trellisRoot, hooksDir, logger: pi.logger });

	pi.setLabel("Trellis canonical policy adapter");
	pi.on("input", adapter.onInput);
	pi.on("tool_call", adapter.onToolCall);
	pi.on("tool_result", adapter.onToolResult);
	pi.on("before_agent_start", adapter.onBeforeAgentStart);
	pi.on("session_before_compact", adapter.onBeforeCompact);
	pi.on("session_compact", async (event: unknown, ctx: OmpContext) => {
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
	pi.on("session_shutdown", adapter.onShutdown);
	pi.on("session_stop", adapter.onStop);
}
