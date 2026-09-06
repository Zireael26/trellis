#!/usr/bin/env node
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
import { resolve } from "node:path";

const packageRoot = process.argv[2];
if (!packageRoot) {
	console.error(`usage: ${process.argv[1]} <patched-pi-coding-agent-package-root>`);
	process.exit(64);
}

const identity = (() => {
	const packageJson = JSON.parse(readFileSync(resolve(packageRoot, "package.json"), "utf8"));
	return `${packageJson.name ?? ""}@${packageJson.version ?? ""}`;
})();
const bundleChunks = {
	"@earendil-works/pi-coding-agent@0.85.0": "chunk-WZB2R5YO.js",
	"@earendil-works/pi-coding-agent@0.85.1": "chunk-JVUZSMYM.js",
};
const bundleChunk = bundleChunks[identity];
assert.ok(bundleChunk, `unsupported package identity: ${identity}`);
const compaction = await import(
	pathToFileURL(resolve(packageRoot, "dist/core/compaction/compaction.js")).href
);
const utils = await import(
	pathToFileURL(resolve(packageRoot, "dist/core/compaction/utils.js")).href
);
const bundled = await import(
	pathToFileURL(resolve(packageRoot, "dist/bundle/chunks", bundleChunk)).href
);

const usage = {
	input: 1,
	output: 1,
	cacheRead: 0,
	cacheWrite: 0,
	totalTokens: 2,
	cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
};
const model = {
	id: "stub",
	provider: "stub",
	api: "openai-completions",
	contextWindow: 10_000,
	maxTokens: 100,
	reasoning: false,
	input: ["text"],
	cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
};

function streamResult(text, stopReason = "stop", prompts = []) {
	return async (_model, context) => ({
		result: async () => {
			prompts.push(context.messages[0].content[0].text);
			return {
				role: "assistant",
				content: [{ type: "text", text }],
				stopReason,
				usage,
				timestamp: Date.now(),
			};
		},
	});
}

async function summarizeWith(api, text, stopReason = "stop") {
	return api.generateSummaryWithUsage(
		[{ role: "user", content: [{ type: "text", text: "input" }], timestamp: 1 }],
		model,
		100,
		undefined,
		undefined,
		new AbortController().signal,
		undefined,
		undefined,
		"off",
		streamResult(text, stopReason),
	);
}

const prior = {
	id: "old-compaction",
	parentId: null,
	type: "compaction",
	timestamp: 1,
	summary: "PRIOR_SUMMARY_SENTINEL",
	firstKeptEntryId: "kept-user",
	tokensBefore: 10_000,
};
const keptUser = {
	id: "kept-user",
	parentId: prior.id,
	type: "message",
	timestamp: 2,
	message: {
		role: "user",
		content: [{ type: "text", text: "U".repeat(4_000) }],
		timestamp: 2,
	},
};
const recentAssistant = {
	id: "recent-assistant",
	parentId: keptUser.id,
	type: "message",
	timestamp: 3,
	message: {
		role: "assistant",
		content: [{ type: "text", text: "A".repeat(4_000) }],
		stopReason: "stop",
		usage: { ...usage, input: 1_000, output: 1_000, totalTokens: 2_000 },
		timestamp: 3,
	},
};
const preparation = compaction.prepareCompaction(
	[prior, keptUser, recentAssistant],
	{ enabled: true, reserveTokens: 100, keepRecentTokens: 500 },
);
assert.ok(preparation);
assert.equal(preparation.isSplitTurn, true);
assert.equal(preparation.messagesToSummarize.length, 0);
assert.equal(preparation.turnPrefixMessages.length, 1);
const prompts = [];
const splitResult = await compaction.compact(
	preparation,
	model,
	undefined,
	undefined,
	undefined,
	new AbortController().signal,
	"off",
	streamResult("TURN_PREFIX_ONLY", "stop", prompts),
);
assert.match(splitResult.summary, /PRIOR_SUMMARY_SENTINEL/);
assert.match(splitResult.summary, /TURN_PREFIX_ONLY/);
assert.equal(prompts.length, 1);

const shortToolResult = "short complete result";
const longToolResult = `HEAD_SENTINEL${"x".repeat(2_500)}TAIL_SENTINEL`;
for (const [label, api] of [["unbundled", { ...compaction, ...utils }], ["bundle", bundled]]) {
	await assert.rejects(() => summarizeWith(api, "   "), /response was empty/, label);
	await assert.rejects(
		() => summarizeWith(api, "partial", "aborted"),
		/generation was aborted/,
		label,
	);
	assert.equal((await summarizeWith(api, "valid summary")).text, "valid summary", label);
	await assert.rejects(
		() => api.compact(
			preparation,
			model,
			undefined,
			undefined,
			undefined,
			new AbortController().signal,
			"off",
			streamResult("   "),
		),
		/response was empty/,
		`${label} split-turn prefix`,
	);
	assert.equal(
		api.serializeConversation([
			{ role: "toolResult", content: [{ type: "text", text: shortToolResult }], timestamp: 1 },
		]),
		`[Tool result]: ${shortToolResult}`,
		label,
	);
	const serialized = api.serializeConversation([
		{ role: "toolResult", content: [{ type: "text", text: longToolResult }], timestamp: 1 },
	]);
	assert.match(serialized, /HEAD_SENTINEL/, label);
	assert.match(serialized, /TAIL_SENTINEL/, label);
	assert.match(serialized, /middle characters truncated/, label);
	assert.ok(serialized.length <= "[Tool result]: ".length + 2_000, label);
}

const bundledSplitResult = await bundled.compact(
	preparation,
	model,
	undefined,
	undefined,
	undefined,
	new AbortController().signal,
	"off",
	streamResult("BUNDLED_TURN_PREFIX"),
);
assert.match(bundledSplitResult.summary, /PRIOR_SUMMARY_SENTINEL/);
assert.match(bundledSplitResult.summary, /BUNDLED_TURN_PREFIX/);

console.log("pi compaction integrity tests passed");
