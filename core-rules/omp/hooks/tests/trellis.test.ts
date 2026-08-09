/**
 * trellis.test.ts — focused unit tests for the OMP Trellis adapter
 * (core-rules/omp/hooks/pre/trellis.ts).
 *
 * Covers, per the inheritance plan: envelope translation, destructive denial,
 * safe pass-through, output parsing, fail-closed tool_call behavior,
 * child-context injection, context-log save on compaction/shutdown, stop-hook
 * continuation, and unsupported/missing-setup failure.
 *
 * The adapter is dependency-light (Node builtins only, no @oh-my-pi imports),
 * so these tests run under plain Node type stripping:
 *   node --test core-rules/omp/hooks/tests/trellis.test.ts
 * Canonical scripts are never executed — a fake spawn returns canned stdout per
 * script name, so behavior is deterministic and offline.
 */
import { describe, it } from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

import {
	buildTranscriptJsonl,
	canonicalToolName,
	createTrellisAdapter,
	editPatchPaths,
	normalizeToolInput,
	parseHookOutput,
	policyMarker,
	resolveTrellisRoot,
	runCanonicalHook,
	slashCommandName,
	systemPromptHasPolicy,
	toolResponseText,
	trellisPresetPolicies,
	type OmpBeforeAgentStartEvent,
	type OmpContext,
	type OmpInputEvent,
	type OmpSessionStopEvent,
	type OmpToolCallEvent,
	type OmpToolResultEvent,
	type SpawnFn,
	type TrellisAdapter,
} from "../pre/trellis.ts";

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

interface SpawnCall {
	script: string;
	args: string[];
	options: {
		input: string;
		env: Record<string, string>;
	};
	transcript?: string;
}

/** Temp dir with the given script names created as empty files. */
function makeHooksDir(scripts: string[]): string {
	const root = fs.mkdtempSync(path.join(os.tmpdir(), "trellis-omp-root-"));
	const dir = path.join(root, "core-rules", "hooks");
	fs.mkdirSync(dir, { recursive: true });
	for (const script of scripts) {
		fs.writeFileSync(path.join(dir, script), "");
	}
	return dir;
}

/** Temp project dir with an optional CLAUDE.md. */
function makeProjectDir(claudeMd: string): string {
	const dir = fs.mkdtempSync(path.join(os.tmpdir(), "trellis-omp-project-"));
	fs.writeFileSync(path.join(dir, "CLAUDE.md"), claudeMd, "utf8");
	return dir;
}

/** Fake spawn returning canned stdout per script; records calls for assertions. */
function makeSpawn(
	responses: Record<string, { stdout?: string; stderr?: string; status?: number }>,
): { spawn: SpawnFn; calls: SpawnCall[] } {
	const calls: SpawnCall[] = [];
	const spawn: SpawnFn = (_command, args, options) => {
		const script = path.basename(args[0] ?? "");
		const response = responses[script] ?? {};
		const env = (options.env ?? {}) as Record<string, string>;
		const transcriptPath = env.CLAUDE_TRANSCRIPT_PATH;
		calls.push({
			script,
			args: [...args],
			options: {
				input: options.input ?? "",
				env,
			},
			transcript:
				transcriptPath && fs.existsSync(transcriptPath)
					? fs.readFileSync(transcriptPath, "utf8")
					: undefined,
		});
		return {
			pid: 1,
			output: [],
			stdout: response.stdout ?? "",
			stderr: response.stderr ?? "",
			status: response.status ?? 0,
			signal: null,
			error: undefined,
		};
	};
	return { spawn, calls };
}

const PROJECT_CLAUDE_MD = `# Celeste project policy
First overlay line.
@/opt/trellis/core-rules/CLAUDE.md
Second overlay line.`;

const PROJECT_POLICY_MARKER = "# Celeste project policy";

function makeCtx(overrides: Partial<OmpContext> = {}): OmpContext {
	return {
		cwd: makeProjectDir(PROJECT_CLAUDE_MD),
		sessionManager: { getSessionId: () => "sess-main" },
		getSystemPrompt: () => ["system prompt without policy marker"],
		...overrides,
	};
}

function makeAdapter(
	options: { spawn?: SpawnFn; hooksDir?: string; tmpDir?: string; trellisRoot?: string } = {},
): { adapter: TrellisAdapter; spawn: SpawnFn; calls: SpawnCall[] } {
	const hooksDir = options.hooksDir ?? makeHooksDir(ALL_CANONICAL_SCRIPTS);
	const trellisRoot = options.trellisRoot ?? path.dirname(path.dirname(hooksDir));
	const spawnSetup = makeSpawn({});
	const spawn = options.spawn ?? spawnSetup.spawn;
	const calls = options.spawn ? [] : spawnSetup.calls;
	const adapter = createTrellisAdapter({
		trellisRoot,
		hooksDir,
		spawn,
		tmpDir: options.tmpDir ?? fs.mkdtempSync(path.join(os.tmpdir(), "trellis-omp-tmp-")),
	});
	return { adapter, spawn, calls };
}

const ALL_CANONICAL_SCRIPTS = [
	"block-destructive.sh",
	"skill-preload-guard.sh",
	"reread-guard.sh",
	"skill-slash-guard.sh",
	"post-edit-verify.sh",
	"truncation-check.sh",
	"track-read.sh",
	"session-context.sh",
	"inject-primer-index.sh",
	"skill-size-preflight.sh",
	"save-context-log.sh",
	"post-compact-context.sh",
	"spec-gate.sh",
	"stop-verify.sh",
	"code-review-subagent.sh",
	"propose-rules.sh",
	"ui-verify.sh",
	"stamp-turn.sh",
];

// ---------------------------------------------------------------------------
// Path and envelope translation
// ---------------------------------------------------------------------------

describe("resolveTrellisRoot", () => {
	it("prefers a valid TRELLIS_ROOT env var", () => {
		const root = makeHooksDir(["block-destructive.sh"]);
		const trellisRoot = path.dirname(path.dirname(root)); // .../core-rules/hooks -> root
		const env = { TRELLIS_ROOT: trellisRoot };
		assert.equal(resolveTrellisRoot("/elsewhere/deep/path", env), trellisRoot);
	});

	it("ignores a dangling TRELLIS_ROOT and falls back to the module walk-up", () => {
		const root = makeHooksDir(["block-destructive.sh"]);
		const trellisRoot = path.dirname(path.dirname(root));
		const adapterDir = path.join(trellisRoot, "core-rules", "omp", "hooks", "pre");
		const env = { TRELLIS_ROOT: "/nonexistent/trellis" };
		assert.equal(resolveTrellisRoot(adapterDir, env), trellisRoot);
	});

	it("walks up from the adapter directory to the ancestor carrying core-rules/hooks", () => {
		const root = makeHooksDir(["block-destructive.sh"]);
		const trellisRoot = path.dirname(path.dirname(root));
		const adapterDir = path.join(trellisRoot, "core-rules", "omp", "hooks", "pre");
		assert.equal(resolveTrellisRoot(adapterDir, {}), trellisRoot);
	});

	it("returns undefined when no root exists", () => {
		assert.equal(resolveTrellisRoot("/nonexistent/a/b/c", {}), undefined);
	});
});

describe("canonicalToolName", () => {
	it("maps managed OMP tools to Claude tool names", () => {
		assert.equal(canonicalToolName("bash"), "Bash");
		assert.equal(canonicalToolName("read"), "Read");
		assert.equal(canonicalToolName("write"), "Write");
		assert.equal(canonicalToolName("edit"), "Edit");
		assert.equal(canonicalToolName("grep"), "Grep");
		assert.equal(canonicalToolName("glob"), "Glob");
		assert.equal(canonicalToolName("skill"), "Skill");
	});

	it("leaves unmanaged tools unmapped", () => {
		assert.equal(canonicalToolName("task"), undefined);
		assert.equal(canonicalToolName("mcp__github_search"), undefined);
	});
});

describe("normalizeToolInput", () => {
	it("extracts the bash command", () => {
		assert.deepEqual(normalizeToolInput("bash", { command: "rm -rf /tmp/x" }), {
			command: "rm -rf /tmp/x",
		});
	});

	it("maps OMP path to canonical file_path for edit/write", () => {
		assert.deepEqual(normalizeToolInput("edit", { path: "src/a.ts", old_string: "x" }), {
			file_path: "src/a.ts",
		});
		assert.deepEqual(normalizeToolInput("write", { filePath: "src/b.ts", content: "y" }), {
			file_path: "src/b.ts",
		});
	});

	it("passes the grep pattern through", () => {
		assert.deepEqual(normalizeToolInput("grep", { pattern: "foo.*", path: "src" }), {
			file_path: "src",
			pattern: "foo.*",
		});
	});

	it("extracts the skill name for skill preload", () => {
		assert.deepEqual(normalizeToolInput("skill", { skill: "process-gate" }), { skill: "process-gate" });
		assert.deepEqual(normalizeToolInput("skill", { name: "process-gate" }), { skill: "process-gate" });
	});

	it("returns an empty object when nothing maps", () => {
		assert.deepEqual(normalizeToolInput("read", { limit: 40 }), {});
	});

	it("extracts every unique hashline edit path", () => {
		const patch = [
			"*** Begin Patch",
			"[src/a.ts#A1B2]",
			"PUT 1.=1:",
			"+a",
			"[src/b.ts#C3D4]",
			"PUT 2.=2:",
			"+b",
			"[src/a.ts#A1B2]",
			"PUT >1:",
			"+again",
			"*** End Patch",
		].join("\n");
		assert.deepEqual(editPatchPaths({ input: patch }), ["src/a.ts", "src/b.ts"]);
	});
});

describe("toolResponseText", () => {
	it("joins text blocks and ignores non-text content", () => {
		const content = [
			{ type: "text", text: "line one" },
			{ type: "image", source: { data: "abc" } },
			{ type: "text", text: "line two" },
			"not a block",
		];
		assert.equal(toolResponseText(content), "line one\nline two");
	});

	it("handles empty or missing content", () => {
		assert.equal(toolResponseText(undefined), "");
		assert.equal(toolResponseText([]), "");
	});
});

// ---------------------------------------------------------------------------
// Output parsing
// ---------------------------------------------------------------------------

describe("parseHookOutput", () => {
	it("parses a Claude PreToolUse denial", () => {
		const result = parseHookOutput(
			{
				stdout: JSON.stringify({
					hookSpecificOutput: {
						hookEventName: "PreToolUse",
						permissionDecision: "deny",
						permissionDecisionReason: "Blocked destructive rm",
					},
				}),
				stderr: "",
				status: 0,
			},
			"block-destructive.sh",
		);
		assert.deepEqual(result, { kind: "block", reason: "Blocked destructive rm" });
	});

	it("parses a decision block with exit 2", () => {
		const result = parseHookOutput(
			{ stdout: JSON.stringify({ decision: "block", reason: "lint failed" }), stderr: "", status: 2 },
			"post-edit-verify.sh",
		);
		assert.deepEqual(result, { kind: "block", reason: "lint failed" });
	});

	it("parses a decision block even when the script exits 0 (slash guard)", () => {
		const result = parseHookOutput(
			{ stdout: JSON.stringify({ decision: "block", reason: "oversized skill" }), stderr: "", status: 0 },
			"skill-slash-guard.sh",
		);
		assert.deepEqual(result, { kind: "block", reason: "oversized skill" });
	});

	it("parses top-level and hookSpecificOutput advisory context", () => {
		const direct = parseHookOutput(
			{ stdout: JSON.stringify({ additionalContext: "Result was truncated." }), stderr: "", status: 0 },
			"truncation-check.sh",
		);
		assert.deepEqual(direct, { kind: "context", context: "Result was truncated." });

		const nested = parseHookOutput(
			{
				stdout: JSON.stringify({
					hookSpecificOutput: { hookEventName: "SessionStart", additionalContext: "Branch: main" },
				}),
				stderr: "",
				status: 0,
			},
			"session-context.sh",
		);
		assert.deepEqual(nested, { kind: "context", context: "Branch: main" });
	});

	it("passes when a script exits 0 with no output", () => {
		assert.deepEqual(parseHookOutput({ stdout: "", stderr: "", status: 0 }, "track-read.sh"), { kind: "pass" });
	});

	it("blocks on exit 2 with stderr when stdout is not JSON", () => {
		const result = parseHookOutput({ stdout: "", stderr: "boom\nline two", status: 2 }, "stop-verify.sh");
		assert.deepEqual(result, { kind: "block", reason: "boom" });
	});

	it("errors on other non-zero exits with the script name", () => {
		const result = parseHookOutput({ stdout: "", stderr: "jq missing", status: 1 }, "block-destructive.sh");
		assert.deepEqual(result, { kind: "error", message: "block-destructive.sh: exit 1: jq missing" });
	});

	it("errors on a null status carrying the exact script path", () => {
		const result = parseHookOutput({ stdout: "", stderr: "missing canonical hook: /x/hooks/a.sh", status: null }, "a.sh");
		assert.deepEqual(result, { kind: "error", message: "a.sh: missing canonical hook: /x/hooks/a.sh" });
	});

	it("ignores warning lines preceding the JSON decision", () => {
		const result = parseHookOutput(
			{
				stdout: `note to stderr-capturing readers\n${JSON.stringify({ decision: "block", reason: "no receipt" })}`,
				stderr: "",
				status: 2,
			},
			"stop-verify.sh",
		);
		assert.deepEqual(result, { kind: "block", reason: "no receipt" });
	});
});

describe("buildTranscriptJsonl", () => {
	it("emits Claude-shaped JSONL lines with roles", () => {
		const messages = [
			{ role: "user", content: "ask" },
			{ role: "assistant", content: [{ type: "text", text: "answer" }] },
		];
		const jsonl = buildTranscriptJsonl(messages);
		const lines = jsonl.trimEnd().split("\n");
		assert.equal(lines.length, 2);
		assert.deepEqual(JSON.parse(lines[0] ?? "{}"), { type: "user", message: messages[0] });
		assert.deepEqual(JSON.parse(lines[1] ?? "{}"), { type: "assistant", message: messages[1] });
	});

	it("normalizes OMP content arrays to the Claude transcript shapes hooks parse", () => {
		const jsonl = buildTranscriptJsonl([
			{
				role: "user",
				content: [
					{ type: "text", text: "first" },
					{ type: "image", data: "ignored" },
					{ type: "text", text: "second" },
				],
			},
			{ role: "assistant", content: "answer" },
		]);
		const lines = jsonl.trimEnd().split("\n");
		assert.equal(JSON.parse(lines[0] ?? "{}").message.content, "first\nsecond");
		assert.deepEqual(JSON.parse(lines[1] ?? "{}").message.content, [{ type: "text", text: "answer" }]);
	});

	it("tolerates non-message entries", () => {
		const jsonl = buildTranscriptJsonl([null, "raw", { role: "user", content: "x" }]);
		const lines = jsonl.trimEnd().split("\n");
		assert.equal(JSON.parse(lines[0] ?? "{}").type, "unknown");
		assert.equal(JSON.parse(lines[1] ?? "{}").type, "unknown");
		assert.equal(JSON.parse(lines[2] ?? "{}").type, "user");
	});

	it("returns empty string for no messages", () => {
		assert.equal(buildTranscriptJsonl([]), "");
	});
});

describe("policy marker detection", () => {
	it("derives a marker from the first non-empty line", () => {
		assert.equal(policyMarker(PROJECT_CLAUDE_MD), PROJECT_POLICY_MARKER);
	});

	it("returns undefined for empty policy text", () => {
		assert.equal(policyMarker(""), undefined);
		assert.equal(policyMarker("   \n\t\n"), undefined);
	});

	it("reports the policy present only when the system prompt contains the marker", () => {
		const marker = policyMarker(PROJECT_CLAUDE_MD);
		assert.equal(systemPromptHasPolicy([PROJECT_CLAUDE_MD, "other"], marker), true);
		assert.equal(systemPromptHasPolicy(["no policy here"], marker), false);
		assert.equal(systemPromptHasPolicy(undefined, marker), false);
		assert.equal(systemPromptHasPolicy(["anything"], undefined), true);
	});
});

describe("Trellis preset policy discovery", () => {
	it("loads only managed preset links resolving inside the canonical preset root", () => {
		const hooksDir = makeHooksDir([]);
		const trellisRoot = path.dirname(path.dirname(hooksDir));
		const presetsDir = path.join(trellisRoot, "core-rules", "presets");
		const projectDir = makeProjectDir(PROJECT_CLAUDE_MD);
		const rulesDir = path.join(projectDir, ".claude", "rules");
		fs.mkdirSync(presetsDir, { recursive: true });
		fs.mkdirSync(rulesDir, { recursive: true });

		const strictPolicy = "# Compliance strict preset\nCanonical preset body.";
		const strictPath = path.join(presetsDir, "compliance-strict.md");
		fs.writeFileSync(strictPath, strictPolicy);
		fs.symlinkSync(strictPath, path.join(rulesDir, "preset-compliance-strict.md"));

		const outsidePath = path.join(projectDir, "outside.md");
		fs.writeFileSync(outsidePath, "# User-owned lookalike");
		fs.symlinkSync(outsidePath, path.join(rulesDir, "preset-lookalike.md"));

		assert.deepEqual(trellisPresetPolicies(projectDir, trellisRoot), [strictPolicy]);
	});
});

describe("slashCommandName", () => {
	it("extracts the command from slash input", () => {
		assert.equal(slashCommandName("/primer-refresh"), "primer-refresh");
		assert.equal(slashCommandName("/compact now"), "compact");
	});
	it("ignores plain text and bare slashes", () => {
		assert.equal(slashCommandName("just text"), undefined);
		assert.equal(slashCommandName("//"), undefined);
		assert.equal(slashCommandName("/"), undefined);
	});
});

// ---------------------------------------------------------------------------
// tool_call: destructive denial, pass-through, fail-closed
// ---------------------------------------------------------------------------

describe("tool_call", () => {
	it("blocks a destructive bash command with the canonical reason", async () => {
		const deny = JSON.stringify({
			hookSpecificOutput: {
				hookEventName: "PreToolUse",
				permissionDecision: "deny",
				permissionDecisionReason: "Blocked destructive rm targeting absolute path",
			},
		});
		const { spawn, calls } = makeSpawn({ "block-destructive.sh": { stdout: deny } });
		const { adapter } = makeAdapter({ spawn });

		const event: OmpToolCallEvent = {
			type: "tool_call",
			toolCallId: "c1",
			toolName: "bash",
			input: { command: "rm -rf /Users/me/important" },
		};
		const ctx = makeCtx();
		const result = await adapter.onToolCall(event, ctx);

		assert.deepEqual(result, { block: true, reason: "Blocked destructive rm targeting absolute path" });
		assert.equal(calls.length, 1);
		assert.equal(calls[0]?.script, "block-destructive.sh");
		const envelope = JSON.parse(calls[0]?.options.input ?? "{}") as Record<string, unknown>;
		assert.equal(envelope.tool_name, "Bash");
		assert.deepEqual(envelope.tool_input, { command: "rm -rf /Users/me/important" });
		assert.equal(calls[0]?.options.env.CLAUDE_PROJECT_DIR, ctx.cwd);
	});

	it("passes through unmanaged tools untouched", async () => {
		const { spawn, calls } = makeSpawn({});
		const { adapter } = makeAdapter({ spawn });
		const ctx = makeCtx();

		const taskCall: OmpToolCallEvent = { type: "tool_call", toolCallId: "t", toolName: "task", input: { task: "x" } };
		assert.equal(await adapter.onToolCall(taskCall, ctx), undefined);

		const mcpCall: OmpToolCallEvent = {
			type: "tool_call",
			toolCallId: "m",
			toolName: "mcp__github_search",
			input: {},
		};
		assert.equal(await adapter.onToolCall(mcpCall, ctx), undefined);
		assert.equal(calls.length, 0);
	});

	it("passes through when the canonical gate allows", async () => {
		const { spawn, calls } = makeSpawn({ "block-destructive.sh": { stdout: "", status: 0 } });
		const { adapter } = makeAdapter({ spawn });
		const event: OmpToolCallEvent = {
			type: "tool_call",
			toolCallId: "c2",
			toolName: "bash",
			input: { command: "npm test" },
		};
		assert.equal(await adapter.onToolCall(event, makeCtx()), undefined);
		assert.equal(calls.length, 1);
	});

	it("fails closed when the canonical script is missing", async () => {
		const { spawn, calls } = makeSpawn({});
		const hooksDir = makeHooksDir(["reread-guard.sh"]); // no block-destructive.sh
		const { adapter } = makeAdapter({ spawn, hooksDir });
		const event: OmpToolCallEvent = {
			type: "tool_call",
			toolCallId: "c3",
			toolName: "bash",
			input: { command: "rm -rf /" },
		};
		const result = await adapter.onToolCall(event, makeCtx());
		assert.ok(result?.block === true, "expected a block");
		assert.match(result?.reason ?? "", /block-destructive\.sh/);
		assert.equal(calls.length, 0); // existence check failed before spawn
	});

	it("fails closed when the canonical script errors", async () => {
		const { spawn, calls } = makeSpawn({ "reread-guard.sh": { stdout: "", stderr: "jq missing", status: 1 } });
		const { adapter } = makeAdapter({ spawn });
		const event: OmpToolCallEvent = {
			type: "tool_call",
			toolCallId: "c4",
			toolName: "write",
			input: { path: "src/x.ts", content: "y" },
		};
		const result = await adapter.onToolCall(event, makeCtx());
		assert.ok(result?.block === true);
		assert.match(result?.reason ?? "", /reread-guard\.sh/);
		assert.equal(calls.length, 1);
	});

	it("runs the reread guard for edits with a normalized file_path", async () => {
		const { spawn, calls } = makeSpawn({ "reread-guard.sh": { stdout: "", status: 0 } });
		const { adapter } = makeAdapter({ spawn });
		const event: OmpToolCallEvent = {
			type: "tool_call",
			toolCallId: "c5",
			toolName: "edit",
			input: { path: "src/a.ts" },
		};
		assert.equal(await adapter.onToolCall(event, makeCtx()), undefined);
		const envelope = JSON.parse(calls[0]?.options.input ?? "{}") as Record<string, unknown>;
		assert.equal(envelope.tool_name, "Edit");
		assert.deepEqual(envelope.tool_input, { file_path: "src/a.ts" });
	});

	it("runs the reread guard once for every file in a hashline edit", async () => {
		const { spawn, calls } = makeSpawn({ "reread-guard.sh": { stdout: "", status: 0 } });
		const { adapter } = makeAdapter({ spawn });
		const event: OmpToolCallEvent = {
			type: "tool_call",
			toolCallId: "c6",
			toolName: "edit",
			input: {
				input: [
					"*** Begin Patch",
					"[src/a.ts#A1B2]",
					"PUT 1.=1:",
					"+a",
					"[src/b.ts#C3D4]",
					"PUT 1.=1:",
					"+b",
					"*** End Patch",
				].join("\n"),
			},
		};
		assert.equal(await adapter.onToolCall(event, makeCtx()), undefined);
		const toolInputs = calls.map((call) => {
			const envelope: unknown = JSON.parse(call.options.input);
			assert.ok(envelope !== null && typeof envelope === "object" && "tool_input" in envelope);
			return envelope.tool_input;
		});
		assert.deepEqual(toolInputs, [{ file_path: "src/a.ts" }, { file_path: "src/b.ts" }]);
	});

	it("resolves a nested cwd to the project carrying the OMP surface", async () => {
		const { spawn, calls } = makeSpawn({ "block-destructive.sh": { stdout: "", status: 0 } });
		const { adapter } = makeAdapter({ spawn });
		const projectDir = fs.mkdtempSync(path.join(os.tmpdir(), "trellis-omp-project-root-"));
		fs.mkdirSync(path.join(projectDir, ".omp"), { recursive: true });
		fs.writeFileSync(path.join(projectDir, ".omp", "AGENTS.md"), "policy");
		const nested = path.join(projectDir, "src", "nested");
		fs.mkdirSync(nested, { recursive: true });
		const event: OmpToolCallEvent = {
			type: "tool_call",
			toolCallId: "c7",
			toolName: "bash",
			input: { command: "npm test" },
		};
		assert.equal(await adapter.onToolCall(event, makeCtx({ cwd: nested })), undefined);
		assert.equal(calls[0]?.options.env.CLAUDE_PROJECT_DIR, projectDir);
	});
});

// ---------------------------------------------------------------------------
// tool_result: post-edit gate, truncation advisory, read tracking
// ---------------------------------------------------------------------------

describe("tool_result", () => {
	it("marks a post-edit gate block as an error with the reason in content", async () => {
		const { spawn, calls } = makeSpawn({
			"post-edit-verify.sh": { stdout: JSON.stringify({ decision: "block", reason: "eslint: no-unused-vars" }), status: 2 },
			"track-read.sh": { stdout: "", status: 0 },
		});
		const { adapter } = makeAdapter({ spawn });
		const event: OmpToolResultEvent = {
			type: "tool_result",
			toolCallId: "r1",
			toolName: "edit",
			input: { path: "src/a.ts" },
			content: [{ type: "text", text: "edit applied" }],
			isError: false,
		};
		const result = await adapter.onToolResult(event, makeCtx());
		assert.ok(result, "expected a patch");
		assert.equal(result.isError, true);
		assert.equal(result.content?.[0]?.type, "text");
		assert.equal(result.content?.[0]?.text, "eslint: no-unused-vars");
		assert.equal(result.content?.at(-1)?.text, "edit applied");
		const scripts = calls.map((call) => call.script);
		assert.ok(scripts.includes("post-edit-verify.sh"));
		assert.ok(scripts.includes("track-read.sh"));
		assert.ok(!scripts.includes("truncation-check.sh"), "edit is not in the truncation matcher");
	});

	it("appends a truncation advisory without marking an error", async () => {
		const { spawn, calls } = makeSpawn({
			"truncation-check.sh": { stdout: JSON.stringify({ additionalContext: "Result was truncated. Re-run with narrower scope." }), status: 0 },
			"track-read.sh": { stdout: "", status: 0 },
		});
		const { adapter } = makeAdapter({ spawn });
		const event: OmpToolResultEvent = {
			type: "tool_result",
			toolCallId: "r2",
			toolName: "read",
			input: { path: "big.ts" },
			content: [{ type: "text", text: "lots of output" }],
			isError: false,
		};
		const result = await adapter.onToolResult(event, makeCtx());
		assert.ok(result, "expected a patch");
		assert.equal(result.isError, false);
		assert.equal(result.content?.at(-1)?.text, "Result was truncated. Re-run with narrower scope.");
		assert.ok(calls.some((call) => call.script === "truncation-check.sh"));
		assert.ok(calls.some((call) => call.script === "track-read.sh"));
	});

	it("passes through when every gate allows", async () => {
		const { spawn } = makeSpawn({});
		const { adapter } = makeAdapter({ spawn });
		const event: OmpToolResultEvent = {
			type: "tool_result",
			toolCallId: "r3",
			toolName: "read",
			input: { path: "ok.ts" },
			content: [{ type: "text", text: "fine" }],
			isError: false,
		};
		assert.equal(await adapter.onToolResult(event, makeCtx()), undefined);
	});

	it("passes through unmanaged tools", async () => {
		const { spawn, calls } = makeSpawn({});
		const { adapter } = makeAdapter({ spawn });
		const event: OmpToolResultEvent = {
			type: "tool_result",
			toolCallId: "r4",
			toolName: "mcp__x",
			input: {},
			content: [],
			isError: false,
		};
		assert.equal(await adapter.onToolResult(event, makeCtx()), undefined);
		assert.equal(calls.length, 0);
	});
});

// ---------------------------------------------------------------------------
// input: slash-skill size guard
// ---------------------------------------------------------------------------

describe("input", () => {
	it("consumes a slash command denied by the skill-size guard", async () => {
		const { spawn, calls } = makeSpawn({
			"skill-slash-guard.sh": { stdout: JSON.stringify({ decision: "block", reason: "oversized skill: process-gate" }), status: 0 },
		});
		const { adapter } = makeAdapter({ spawn });
		const event: OmpInputEvent = { type: "input", text: "/process-gate run", source: "interactive" };
		const result = await adapter.onInput(event, makeCtx());
		assert.deepEqual(result, { handled: true, text: "" });
		const envelope = JSON.parse(calls[0]?.options.input ?? "{}") as Record<string, unknown>;
		assert.equal(envelope.hook_event_name, "UserPromptExpansion");
		assert.equal(envelope.expansion_type, "slash_command");
		assert.equal(envelope.command_name, "process-gate");
	});

	it("passes through plain text and allowed slash commands", async () => {
		const { spawn, calls } = makeSpawn({
			"skill-slash-guard.sh": { stdout: "", status: 0 },
		});
		const { adapter } = makeAdapter({ spawn });
		const ctx = makeCtx();
		assert.equal(await adapter.onInput({ type: "input", text: "hello there", source: "interactive" }, ctx), undefined);
		assert.equal(await adapter.onInput({ type: "input", text: "/status", source: "interactive" }, ctx), undefined);
		assert.equal(calls.length, 1, "plain text must not invoke the guard");
	});

	it("passes through when the guard errors (logged, not swallowed)", async () => {
		const { spawn, calls } = makeSpawn({
			"skill-slash-guard.sh": { stdout: "", stderr: "jq missing", status: 1 },
		});
		const { adapter } = makeAdapter({ spawn });
		const result = await adapter.onInput({ type: "input", text: "/surgical fix", source: "interactive" }, makeCtx());
		assert.equal(result, undefined);
		assert.equal(calls.length, 1);
	});
});

// ---------------------------------------------------------------------------
// before_agent_start: session context + child policy injection
// ---------------------------------------------------------------------------

describe("before_agent_start", () => {
	const sessionContextOut = JSON.stringify({
		hookSpecificOutput: { hookEventName: "SessionStart", additionalContext: "Branch: main\nDirty files: 2" },
	});

	function agentStartEvent(): OmpBeforeAgentStartEvent {
		return { type: "before_agent_start", prompt: "do the thing", systemPrompt: ["base system prompt"] };
	}

	it("injects live project CLAUDE.md into a session whose prompt lacks it (child)", async () => {
		const { spawn, calls } = makeSpawn({
			"session-context.sh": { stdout: sessionContextOut, status: 0 },
			"inject-primer-index.sh": { stdout: "", status: 0 },
			"skill-size-preflight.sh": { stdout: "", status: 0 },
		});
		const { adapter } = makeAdapter({ spawn });
		const ctx = makeCtx({ getSystemPrompt: () => ["task child prompt without policy"] });

		const result = await adapter.onBeforeAgentStart(agentStartEvent(), ctx);

		assert.ok(result, "expected an injection result");
		// Session context rides as a hidden custom message.
		assert.equal(result.message?.customType, "trellis-session-context");
		assert.match(result.message?.content ?? "", /Branch: main/);
		assert.equal(result.message?.display, false);
		// Live project policy appended to the system prompt for the child.
		assert.ok(result.systemPrompt, "expected policy appended to systemPrompt");
		assert.deepEqual(result.systemPrompt, ["task child prompt without policy", PROJECT_CLAUDE_MD]);
		assert.ok(calls.some((call) => call.script === "session-context.sh"));
		assert.ok(calls.some((call) => call.script === "inject-primer-index.sh"));
		assert.ok(calls.some((call) => call.script === "skill-size-preflight.sh"));
	});

	it("does not duplicate policy when the system prompt already carries it (main session)", async () => {
		const { spawn } = makeSpawn({
			"session-context.sh": { stdout: sessionContextOut, status: 0 },
		});
		const { adapter } = makeAdapter({ spawn });
		const ctx = makeCtx({
			getSystemPrompt: () => ["header", PROJECT_CLAUDE_MD, "tail"], // native .omp/AGENTS.md content
		});

		const result = await adapter.onBeforeAgentStart(agentStartEvent(), ctx);
		assert.ok(result, "session context still injected");
		assert.equal(result.systemPrompt, undefined, "no policy duplication");
		assert.match(result.message?.content ?? "", /Branch: main/);
	});

	it("injects canonical Trellis presets that OMP does not discover natively", async () => {
		const hooksDir = makeHooksDir(ALL_CANONICAL_SCRIPTS);
		const trellisRoot = path.dirname(path.dirname(hooksDir));
		const presetsDir = path.join(trellisRoot, "core-rules", "presets");
		const projectDir = makeProjectDir(PROJECT_CLAUDE_MD);
		const rulesDir = path.join(projectDir, ".claude", "rules");
		fs.mkdirSync(presetsDir, { recursive: true });
		fs.mkdirSync(rulesDir, { recursive: true });
		const preset = "# Compliance strict preset\nAdditional canonical constraints.";
		const presetPath = path.join(presetsDir, "compliance-strict.md");
		fs.writeFileSync(presetPath, preset);
		fs.symlinkSync(presetPath, path.join(rulesDir, "preset-compliance-strict.md"));

		const { spawn } = makeSpawn({ "session-context.sh": { stdout: sessionContextOut, status: 0 } });
		const { adapter } = makeAdapter({ spawn, hooksDir, trellisRoot });
		const result = await adapter.onBeforeAgentStart(
			agentStartEvent(),
			makeCtx({ cwd: projectDir, getSystemPrompt: () => [PROJECT_CLAUDE_MD] }),
		);

		assert.deepEqual(result?.systemPrompt, [PROJECT_CLAUDE_MD, preset]);
	});

	it("injects only once per session", async () => {
		const { spawn, calls } = makeSpawn({
			"session-context.sh": { stdout: sessionContextOut, status: 0 },
		});
		const { adapter } = makeAdapter({ spawn });
		const ctx = makeCtx();

		const first = await adapter.onBeforeAgentStart(agentStartEvent(), ctx);
		const second = await adapter.onBeforeAgentStart(agentStartEvent(), ctx);
		assert.ok(first, "first agent start injects");
		assert.equal(second, undefined, "later agent starts are untouched");
		assert.equal(calls.filter((call) => call.script === "session-context.sh").length, 1);
	});

	it("injects the canonical policy in the private control-plane checkout", async () => {
		const hooksDir = makeHooksDir(ALL_CANONICAL_SCRIPTS);
		const trellisRoot = path.dirname(path.dirname(hooksDir));
		const canonicalPolicy = "# Canonical Trellis control plane\nLoad-bearing policy.";
		fs.writeFileSync(path.join(trellisRoot, "core-rules", "CLAUDE.md"), canonicalPolicy);
		const { spawn } = makeSpawn({ "session-context.sh": { stdout: sessionContextOut, status: 0 } });
		const { adapter } = makeAdapter({ spawn, hooksDir, trellisRoot });
		const result = await adapter.onBeforeAgentStart(
			agentStartEvent(),
			makeCtx({ cwd: trellisRoot, getSystemPrompt: () => ["base"] }),
		);
		assert.deepEqual(result?.systemPrompt, ["base", canonicalPolicy]);
	});

	it("skips policy injection when the project has no CLAUDE.md", async () => {
		const { spawn } = makeSpawn({
			"session-context.sh": { stdout: sessionContextOut, status: 0 },
		});
		const { adapter } = makeAdapter({ spawn });
		const ctx = makeCtx({ cwd: fs.mkdtempSync(path.join(os.tmpdir(), "trellis-omp-nopolicy-")) });
		const result = await adapter.onBeforeAgentStart(agentStartEvent(), ctx);
		assert.ok(result);
		assert.equal(result.systemPrompt, undefined);
	});
});

// ---------------------------------------------------------------------------
// session_before_compact / session_shutdown: context-log preservation
// ---------------------------------------------------------------------------

describe("context-log preservation", () => {
	it("runs save-context-log.sh on session_before_compact", async () => {
		const { spawn, calls } = makeSpawn({ "save-context-log.sh": { stdout: "", status: 0 } });
		const { adapter } = makeAdapter({ spawn });
		const ctx = makeCtx();
		const result = await adapter.onBeforeCompact({ type: "session_before_compact" }, ctx);
		assert.equal(result, undefined, "compaction is never cancelled");
		assert.equal(calls.length, 1);
		assert.equal(calls[0]?.script, "save-context-log.sh");
		assert.equal(calls[0]?.options.env.CLAUDE_PROJECT_DIR, ctx.cwd);
	});

	it("passes the compaction conversation to save-context-log.sh", async () => {
		const { spawn, calls } = makeSpawn({ "save-context-log.sh": { stdout: "", status: 0 } });
		const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "trellis-omp-compact-"));
		const { adapter } = makeAdapter({ spawn, tmpDir });
		const messages = [
			{ role: "user", content: "preserve this ask" },
			{ role: "assistant", content: [{ type: "text", text: "preserve this decision" }] },
		];
		await adapter.onBeforeCompact(
			{
				type: "session_before_compact",
				preparation: { messagesToSummarize: messages, turnPrefixMessages: [], recentMessages: [] },
			},
			makeCtx(),
		);
		const call = calls[0];
		assert.equal(call?.transcript, buildTranscriptJsonl(messages));
		const transcriptPath = call?.options.env.CLAUDE_TRANSCRIPT_PATH;
		assert.ok(transcriptPath);
		assert.ok(!fs.existsSync(transcriptPath), "compaction transcript is removed after the hook");
	});

	it("returns canonical post-compact context for hidden injection", async () => {
		const contextOut = JSON.stringify({
			hookSpecificOutput: { hookEventName: "SessionStart", additionalContext: "restored context" },
		});
		const { spawn, calls } = makeSpawn({ "post-compact-context.sh": { stdout: contextOut, status: 0 } });
		const { adapter } = makeAdapter({ spawn });
		assert.equal(await adapter.onCompact({ type: "session_compact" }, makeCtx()), "restored context");
		assert.equal(calls[0]?.script, "post-compact-context.sh");
	});

	it("runs save-context-log.sh on session_shutdown", async () => {
		const { spawn, calls } = makeSpawn({ "save-context-log.sh": { stdout: "", status: 0 } });
		const { adapter } = makeAdapter({ spawn });
		await adapter.onShutdown({ type: "session_shutdown" }, makeCtx());
		assert.equal(calls.length, 1);
		assert.equal(calls[0]?.script, "save-context-log.sh");
	});
});

// ---------------------------------------------------------------------------
// session_stop: receipt gates and continuation
// ---------------------------------------------------------------------------

describe("session_stop", () => {
	const messages = [
		{ role: "user", content: "fix the build" },
		{
			role: "assistant",
			content: [
				{ type: "text", text: 'done <!-- dod-receipt cmd="npm test" exit=0 diff="+2/-1 (1 files)" -->' },
			],
		},
	];

	function stopEvent(overrides: Partial<OmpSessionStopEvent> = {}): OmpSessionStopEvent {
		return {
			type: "session_stop",
			messages,
			turn_id: 7,
			session_id: "sess-abc",
			session_file: "/tmp/sess-abc.jsonl",
			stop_hook_active: false,
			...overrides,
		};
	}

	it("requests a continuation with the canonical reason when a receipt gate blocks", async () => {
		const { spawn, calls } = makeSpawn({
			"stop-verify.sh": {
				stdout: JSON.stringify({ decision: "block", reason: "receipts: no Definition-of-Done receipt found" }),
				status: 2,
			},
		});
		const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "trellis-omp-stop-"));
		const { adapter } = makeAdapter({ spawn, tmpDir });

		const result = await adapter.onStop(stopEvent(), makeCtx());
		assert.deepEqual(result, { decision: "block", reason: "receipts: no Definition-of-Done receipt found" });

		// Earlier hooks ran in canonical order before the blocker.
		const scripts = calls.map((call) => call.script);
		assert.equal(scripts[0], "spec-gate.sh");
		assert.ok(scripts.indexOf("stop-verify.sh") > scripts.indexOf("spec-gate.sh"));
		assert.ok(!scripts.includes("stamp-turn.sh"), "stops at the first block");

		// Transcript: adapter-produced Claude JSONL, exported via env, cleaned up.
		const stopCall = calls.find((call) => call.script === "stop-verify.sh");
		const transcriptPath = stopCall?.options.env.CLAUDE_TRANSCRIPT_PATH;
		assert.ok(transcriptPath, "CLAUDE_TRANSCRIPT_PATH must be set");
		assert.equal(stopCall?.transcript, buildTranscriptJsonl(messages));
		const envelope = JSON.parse(stopCall?.options.input ?? "{}") as Record<string, unknown>;
		assert.equal(envelope.transcript_path, transcriptPath);
		assert.equal(envelope.session_id, "sess-abc");
		assert.equal(envelope.session_file, "/tmp/sess-abc.jsonl");
		assert.equal(envelope.stop_hook_active, false);
		assert.ok(!fs.existsSync(transcriptPath), "temp transcript is removed after the stop pass");
	});

	it("continues quietly when every receipt gate passes", async () => {
		const { spawn, calls } = makeSpawn({});
		const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "trellis-omp-stop-"));
		const { adapter } = makeAdapter({ spawn, tmpDir });

		const result = await adapter.onStop(stopEvent(), makeCtx());
		assert.equal(result, undefined);
		assert.equal(calls.length, STOP_SCRIPTS_EXPECTED.length);
	});

	it("skips the whole pass on a continuation (stop_hook_active)", async () => {
		const { spawn, calls } = makeSpawn({});
		const { adapter } = makeAdapter({ spawn });
		const result = await adapter.onStop(stopEvent({ stop_hook_active: true }), makeCtx());
		assert.equal(result, undefined);
		assert.equal(calls.length, 0);
	});

	it("skips the whole pass when the settle is aborted", async () => {
		const { spawn, calls } = makeSpawn({});
		const { adapter } = makeAdapter({ spawn });
		const controller = new AbortController();
		controller.abort();
		const result = await adapter.onStop(stopEvent({ signal: controller.signal }), makeCtx());
		assert.equal(result, undefined);
		assert.equal(calls.length, 0);
	});
});

const STOP_SCRIPTS_EXPECTED = [
	"spec-gate.sh",
	"stop-verify.sh",
	"code-review-subagent.sh",
	"propose-rules.sh",
	"ui-verify.sh",
	"stamp-turn.sh",
];

// ---------------------------------------------------------------------------
// Unsupported setup: refuse to run without canonical hooks
// ---------------------------------------------------------------------------

describe("adapter setup refusal", () => {
	it("throws when the canonical hooks directory is missing", () => {
		const missing = path.join(os.tmpdir(), "trellis-omp-no-hooks");
		assert.throws(() => createTrellisAdapter({ trellisRoot: "/tmp", hooksDir: missing }), /canonical hooks directory missing/);
	});

	it("runs a real script through runCanonicalHook with the envelope on stdin", () => {
		const hooksDir = makeHooksDir(["echo-hook.sh"]);
		const scriptPath = path.join(hooksDir, "echo-hook.sh");
		fs.writeFileSync(
			scriptPath,
			'#!/usr/bin/env bash\ncat\n',
			{ mode: 0o755 },
		);
		const result = runCanonicalHook(
			{
				hooksDir,
				trellisRoot: path.dirname(path.dirname(hooksDir)),
				script: "echo-hook.sh",
				projectDir: "/tmp/project",
				envelope: { tool_name: "Bash", tool_input: { command: "ls" } },
				timeoutMs: 5_000,
			},
			undefined, // real spawnSync — exercises the live execution path
		);
		assert.equal(result.status, 0);
		assert.deepEqual(JSON.parse(result.stdout), { tool_name: "Bash", tool_input: { command: "ls" } });
	});
});
