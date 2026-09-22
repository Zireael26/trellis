import { hostname } from "node:os";
import type {
	ExtensionAPI,
	ExtensionContext,
	ReadonlyFooterDataProvider,
	Theme,
	ThemeColor,
	UIPromptKind,
} from "@earendil-works/pi-coding-agent";
import { sliceByColumn, visibleWidth } from "@earendil-works/pi-tui";
import { sanitizeTerminalText } from "@narumitw/pi-tui-kit/terminal-text";
import { formatDirectoryPath } from "./directory.ts";
import {
	type ExtensionStatusRuntime,
	formatExtensionStatuses,
	wrapExtensionStatusline,
} from "./extension-status.ts";
import { formatGitBranchValue, type GitStatusSummary } from "./git-status.ts";
import { renderPowerlineStatusline } from "./powerline.ts";
import {
	LINE_BREAK_SEGMENT_NAME,
	type PowerlineBlockName,
	type RenderItem,
	type RenderSegment,
	type SegmentName,
	type StatuslineConfig,
	type TruncationDirection,
} from "./types.ts";
import { type FooterUsageSummary, summarizeFooterUsage } from "./usage.ts";

type ThinkingLevel = ReturnType<ExtensionAPI["getThinkingLevel"]>;
export interface RuntimeState extends ExtensionStatusRuntime {
	homeDir?: string;
	turnCount: number;
	activeTools: Map<string, number>;
	isStreaming: boolean;
	uiPrompt?: { kind: UIPromptKind; title?: string };
	thinkingLevel: ThinkingLevel;
	gitStatus?: GitStatusSummary;
	requestRender?: () => void;
	/** Completed agent_start→agent_end processing time this session (OMP `time_spent`). */
	activeMs: number;
	/** Start of the currently running agent window, undefined while idle. */
	activeStartedAt?: number;
	/** Output tokens per second of the latest finished assistant message (OMP `token_rate`). */
	tokensPerSecond?: number;
	/** Start timestamp of the assistant message currently streaming. */
	assistantStartedAt?: number;
}
const GITHUB_PR_KEY = "github-pr";
const GITHUB_PR_STATUS_KEYS = new Set([GITHUB_PR_KEY]);
const SUBAGENTS_KEY = "subagents";

export function activeMilliseconds(runtime: Pick<RuntimeState, "activeMs" | "activeStartedAt">): number {
	if (runtime.activeStartedAt === undefined) return runtime.activeMs;
	return runtime.activeMs + Math.max(0, Date.now() - runtime.activeStartedAt);
}

/** Live agent count published by pi-subagents via ctx.ui.setStatus("subagents", "N running, M queued agents"). */
export function subagentCountFromStatuses(statuses: ReadonlyMap<string, string>): number | undefined {
	const value = statuses.get(SUBAGENTS_KEY);
	if (!value) return undefined;
	const running = /(\d+) running/u.exec(value);
	const queued = /(\d+) queued/u.exec(value);
	if (!running && !queued) return undefined;
	return Number(running?.[1] ?? 0) + Number(queued?.[1] ?? 0);
}
export function renderStatusline(
	width: number,
	ctx: ExtensionContext,
	footerData: ReadonlyFooterDataProvider,
	_theme: Theme,
	config: StatuslineConfig,
	runtime: RuntimeState,
	trueColor = true,
): string {
	if (width <= 0) return "";

	const usageSummary = summarizeFooterUsage(ctx.sessionManager.getEntries());
	const rows: Array<{ configuredSegments: number; segments: RenderSegment[] }> = [
		{ configuredSegments: 0, segments: [] },
	];
	for (const name of config.segments) {
		if (name === LINE_BREAK_SEGMENT_NAME) {
			rows.push({ configuredSegments: 0, segments: [] });
			continue;
		}

		const row = rows.at(-1);
		if (!row) continue;
		row.configuredSegments += 1;
		const rendered = buildSegment(name, ctx, footerData, config, runtime, usageSummary);
		if (rendered && rendered.text.length > 0) row.segments.push(rendered);
	}

	const segments: RenderItem[] = [];
	const renderedRows = rows.filter(
		(row) => row.configuredSegments === 0 || row.segments.length > 0,
	);
	for (const [index, row] of renderedRows.entries()) {
		if (index > 0) segments.push({ name: LINE_BREAK_SEGMENT_NAME });
		segments.push(...row.segments);
	}

	return renderPowerlineStatusline(width, segments, config, trueColor);
}

export function renderExtensionStatusline(
	width: number,
	footerData: ReadonlyFooterDataProvider,
	theme: Theme,
	config: StatuslineConfig,
	runtime: RuntimeState,
	mainLine: string,
	trueColor = true,
): string[] {
	const statuses = footerData.getExtensionStatuses();
	const prContext = prContextFromStatuses(statuses);
	const rendersPrInline = prContext !== undefined && mainLine.includes(prContext);
	const hiddenKeys = new Set<string>();
	if (rendersPrInline) for (const key of GITHUB_PR_STATUS_KEYS) hiddenKeys.add(key);
	// The subagents segment renders the count inline, so drop the duplicate status row.
	if (config.segments.includes("subagents") && subagentCountFromStatuses(statuses) !== undefined) {
		hiddenKeys.add(SUBAGENTS_KEY);
	}
	const status = formatExtensionStatuses(
		statuses,
		theme,
		config,
		runtime,
		hiddenKeys.size > 0 ? hiddenKeys : undefined,
		trueColor,
	);
	return wrapExtensionStatusline(status, width);
}

function buildSegment(
	name: SegmentName,
	ctx: ExtensionContext,
	footerData: ReadonlyFooterDataProvider,
	config: StatuslineConfig,
	runtime: RuntimeState,
	usageSummary: FooterUsageSummary,
): RenderSegment | undefined {
	switch (name) {
		case "brand":
			return segment(name, "π", config, "accent", "header", true);
		case "provider":
			return segment(name, ctx.model?.provider ?? "no-provider", config, "accent", "header");
		case "model": {
			const presentation = config.segmentText.model;
			const model = truncateModel(
				shortenModel(ctx.model?.id ?? "no-model"),
				presentation.truncationLength,
				presentation.truncationSymbol,
				presentation.truncationDirection,
			);
			return segment(name, model, config, "accent", "header");
		}
		case "thinking":
			return segment(
				name,
				runtime.thinkingLevel,
				config,
				thinkingColor(runtime.thinkingLevel),
				"header",
			);
		case "branch": {
			const branch = footerData.getGitBranch();
			const pr = branch ? prContextFromStatuses(footerData.getExtensionStatuses()) : undefined;
			return segment(
				name,
				formatGitBranchValue(branch, runtime.gitStatus, pr),
				config,
				"accent",
				"git",
			);
		}
		case "cwd":
			return segment(
				name,
				formatDirectoryPath(ctx.cwd, runtime.homeDir, runtime.gitStatus?.root),
				config,
				"accent",
				"directory",
			);
		case "tools": {
			const activity = formatToolActivity(runtime);
			return activity ? segment(name, activity, config, "accent", "runtime") : undefined;
		}
		case "context": {
			const usage = ctx.getContextUsage();
			const percentage =
				usage?.percent === null || usage?.percent === undefined
					? "?"
					: `${usage.percent.toFixed(1)}%`;
			const contextWindow = usage?.contextWindow ?? ctx.model?.contextWindow ?? 0;
			return segment(
				name,
				`${percentage}/${formatCount(contextWindow)}`,
				config,
				contextColor(usage?.percent),
				"runtime",
			);
		}
		case "tokens": {
			const value =
				usageSummary.input === 0 && usageSummary.output === 0
					? "tok 0"
					: `↑${formatCount(usageSummary.input)} ↓${formatCount(usageSummary.output)}`;
			return segment(name, value, config, "accent", "runtime");
		}
		case "cache": {
			if (usageSummary.cacheRead === 0 && usageSummary.cacheWrite === 0) return undefined;
			const values: string[] = [];
			if (usageSummary.cacheRead > 0) values.push(`R${formatCount(usageSummary.cacheRead)}`);
			if (usageSummary.cacheWrite > 0) values.push(`W${formatCount(usageSummary.cacheWrite)}`);
			if (usageSummary.latestCacheHitRate !== undefined) {
				values.push(`CH${usageSummary.latestCacheHitRate.toFixed(1)}%`);
			}
			return segment(name, values.join(" "), config, "accent", "runtime");
		}
		case "cost": {
			const subscription = isSubscriptionBacked(ctx) ? " (sub)" : "";
			return segment(
				name,
				`${usageSummary.cost.toFixed(usageSummary.cost >= 1 ? 2 : 3)}${subscription}`,
				config,
				"accent",
				"meter",
			);
		}
		case "time":
			return segment(name, formatTime(), config, "accent", "meter");
		case "turn":
			return segment(name, `${runtime.turnCount}`, config, "accent", "meter");
		// --- OMP status-line segments (formatting follows oh-my-pi status-line/segments.ts) ---
		case "hostname":
			return segment(name, hostname().split(".")[0] ?? "", config, "accent", "header");
		case "session": {
			const id = ctx.sessionManager.getSessionId();
			return segment(name, id ? id.slice(0, 8) : "new", config, "accent", "git");
		}
		case "subagents": {
			const count = subagentCountFromStatuses(footerData.getExtensionStatuses());
			if (!count) return undefined;
			return segment(name, `${count}`, config, "accent", "git");
		}
		case "commit": {
			const commit = runtime.gitStatus?.commit;
			return commit ? segment(name, commit, config, "accent", "git") : undefined;
		}
		case "token_in":
			if (!usageSummary.input) return undefined;
			return segment(name, formatOmpNumber(usageSummary.input), config, "accent", "runtime");
		case "token_out":
			if (!usageSummary.output) return undefined;
			return segment(name, formatOmpNumber(usageSummary.output), config, "accent", "runtime");
		case "token_total": {
			// OMP excludes cacheRead: it re-reads the whole cached context every turn.
			const total = usageSummary.input + usageSummary.output + usageSummary.cacheWrite;
			if (!total) return undefined;
			return segment(name, formatOmpNumber(total), config, "accent", "runtime");
		}
		case "token_rate": {
			const rate = runtime.tokensPerSecond;
			if (!rate) return undefined;
			return segment(name, `${rate.toFixed(1)} tok/s`, config, "accent", "runtime");
		}
		case "cache_read":
			if (!usageSummary.cacheRead) return undefined;
			return segment(name, formatOmpNumber(usageSummary.cacheRead), config, "accent", "runtime");
		case "cache_write":
			if (!usageSummary.cacheWrite) return undefined;
			return segment(name, formatOmpNumber(usageSummary.cacheWrite), config, "accent", "runtime");
		case "cache_hit": {
			if (!usageSummary.cacheRead) return undefined;
			const total = usageSummary.cacheRead + usageSummary.cacheWrite + usageSummary.input;
			return segment(
				name,
				`${((usageSummary.cacheRead / total) * 100).toFixed(2)}%`,
				config,
				"accent",
				"runtime",
			);
		}
		case "context_total": {
			const window = ctx.getContextUsage()?.contextWindow ?? ctx.model?.contextWindow ?? 0;
			if (!window) return undefined;
			return segment(name, formatOmpNumber(window), config, "accent", "runtime");
		}
		case "time_spent": {
			const active = activeMilliseconds(runtime);
			if (active < 1000) return undefined;
			return segment(name, formatOmpDuration(active), config, "accent", "meter");
		}
	}
}

/** oh-my-pi `formatNumber`: 999, 1.5K, 25K, 1.5M, 25M, 1.5B. */
export function formatOmpNumber(n: number): string {
	const trim1 = (value: number) => {
		const text = value.toFixed(1);
		return text.endsWith(".0") ? text.slice(0, -2) : text;
	};
	if (n < 1_000) return `${n}`;
	if (n < 10_000) return `${trim1(n / 1_000)}K`;
	if (n < 1_000_000) return `${Math.round(n / 1_000)}K`;
	if (n < 10_000_000) return `${trim1(n / 1_000_000)}M`;
	if (n < 1_000_000_000) return `${Math.round(n / 1_000_000)}M`;
	if (n < 10_000_000_000) return `${trim1(n / 1_000_000_000)}B`;
	return `${Math.round(n / 1_000_000_000)}B`;
}

/** oh-my-pi `formatDuration`: 850ms, 4.2s, 3m12s, 1h05m → "1h5m", 2d3h. */
export function formatOmpDuration(ms: number): string {
	const SEC = 1000;
	const MIN = 60 * SEC;
	const HOUR = 60 * MIN;
	const DAY = 24 * HOUR;
	if (!Number.isFinite(ms) || ms <= 0) return "0ms";
	if (ms < SEC) return `${ms}ms`;
	if (ms < MIN) return `${(ms / SEC).toFixed(1)}s`;
	if (ms < HOUR) {
		const mins = Math.floor(ms / MIN);
		const secs = Math.floor((ms % MIN) / SEC);
		return secs > 0 ? `${mins}m${secs}s` : `${mins}m`;
	}
	if (ms < DAY) {
		const hours = Math.floor(ms / HOUR);
		const mins = Math.floor((ms % HOUR) / MIN);
		return mins > 0 ? `${hours}h${mins}m` : `${hours}h`;
	}
	const days = Math.floor(ms / DAY);
	const hours = Math.floor((ms % DAY) / HOUR);
	return hours > 0 ? `${days}d${hours}h` : `${days}d`;
}

function segment(
	name: SegmentName,
	value: string,
	config: StatuslineConfig,
	color: RenderSegment["color"],
	block: PowerlineBlockName,
	emphasis = false,
): RenderSegment {
	return { name, text: formatConfiguredSegment(name, value, config), color, block, emphasis };
}

export function formatConfiguredSegment(
	name: SegmentName,
	value: string,
	config: Pick<StatuslineConfig, "segmentText">,
): string {
	const presentation = config.segmentText[name];
	return `${presentation.prefix}${value}${presentation.suffix}`;
}

function thinkingColor(level: ThinkingLevel): ThemeColor {
	switch (level as string) {
		case "off":
			return "dim";
		case "minimal":
			return "thinkingMinimal";
		case "low":
			return "thinkingLow";
		case "medium":
			return "thinkingMedium";
		case "high":
			return "thinkingHigh";
		case "xhigh":
			return "thinkingXhigh";
		case "max":
			return "thinkingMax" as ThemeColor;
		default:
			return "dim";
	}
}

export function contextColor(percent: number | null | undefined): ThemeColor {
	if (percent === null || percent === undefined) return "dim";
	if (percent >= 90) return "error";
	if (percent >= 70) return "warning";
	return "success";
}

const MAX_UI_PROMPT_TITLE_CODE_POINTS = 256;
const MAX_UI_PROMPT_TITLE_WIDTH = 40;

function boundUIPromptTitleLength(title: string): string {
	let end = 0;
	let ellipsisEnd = 0;
	let codePoints = 0;
	while (end < title.length && codePoints < MAX_UI_PROMPT_TITLE_CODE_POINTS) {
		const codePoint = title.codePointAt(end) ?? 0;
		end += codePoint > 0xffff ? 2 : 1;
		codePoints += 1;
		if (codePoints < MAX_UI_PROMPT_TITLE_CODE_POINTS) ellipsisEnd = end;
	}
	return end < title.length ? `${title.slice(0, ellipsisEnd)}…` : title;
}

function formatUIPromptTitle(title: string | undefined): string {
	const safeTitle = title ? sanitizeTerminalText(title).trim() : "";
	const boundedTitle = boundUIPromptTitleLength(safeTitle);
	if (visibleWidth(boundedTitle) <= MAX_UI_PROMPT_TITLE_WIDTH) return boundedTitle;
	return `${sliceByColumn(boundedTitle, 0, MAX_UI_PROMPT_TITLE_WIDTH - 1, true)}…`;
}

export function formatToolActivity(runtime: RuntimeState): string | undefined {
	if (runtime.uiPrompt) {
		const title = formatUIPromptTitle(runtime.uiPrompt.title);
		return `⌨ waiting for ${runtime.uiPrompt.kind}${title ? ` · ${title}` : ""}`;
	}

	const active = [...runtime.activeTools.entries()];
	if (active.length > 0) {
		const [name, count] = active[0] ?? ["tool", 1];
		const suffix = count > 1 ? `×${count}` : active.length > 1 ? `+${active.length - 1}` : "";
		return `⚙️ ${name}${suffix}`;
	}

	return runtime.isStreaming ? "💭 thinking" : undefined;
}

export function prLinkFromStatuses(statuses: ReadonlyMap<string, string>): string | undefined {
	const value = statuses.get(GITHUB_PR_KEY);
	if (!value) return undefined;
	// Extract the OSC 8 hyperlink span (the clickable "#123"); skip non-PR states
	// like "PR gh missing" that carry no link. github-pr emits exactly one link, so the
	// first OSC 8 span is the PR number.
	const open = value.indexOf("\x1b]8;;");
	if (open === -1) return undefined;
	const closeMarker = "\x1b]8;;\x07";
	const close = value.indexOf(closeMarker, open + 1);
	return close === -1 ? undefined : value.slice(open, close + closeMarker.length);
}

export function prContextFromStatuses(statuses: ReadonlyMap<string, string>): string | undefined {
	const value = statuses.get(GITHUB_PR_KEY);
	if (!value) return undefined;
	const link = prLinkFromStatuses(statuses);
	const reference = link ?? plainPrReference(value);
	if (!reference) return undefined;

	const state = compactPrState(link ? value.replace(link, "") : value);
	return state ? `${reference} · ${state}` : undefined;
}

function plainPrReference(value: string): string | undefined {
	return /^PR\s+(#\d+):/u.exec(value)?.[1];
}

function compactPrState(value: string): string | undefined {
	if (/:\s*merged\s*$/.test(value)) return "merged";
	if (/:\s*closed\s*$/.test(value)) return "closed";
	if (/\bdraft\b/.test(value)) return "draft";

	const failing = /\bchecks failing \((\d+)\)/.exec(value);
	if (failing) return `${failing[1]} failing`;
	if (/\bchanges requested\b/.test(value)) return "changes requested";

	const pending = /\bchecks pending \((\d+)\)/.exec(value);
	if (pending) return `${pending[1]} pending`;
	if (/\bapproved\b/.test(value)) return "approved";
	if (/\breview required\b/.test(value)) return "review required";
	if (/\bchecks passing\b/.test(value)) return "checks passing";
	if (/\bno checks\b/.test(value)) return "no checks";
	return undefined;
}

function isSubscriptionBacked(ctx: ExtensionContext): boolean {
	const model = ctx.model;
	return (
		model !== undefined &&
		(model.provider === "kimi-coding" || ctx.modelRegistry.isUsingOAuth(model))
	);
}

export function formatCount(value: number): string {
	if (value < 1000) return `${value}`;
	if (value < 1_000_000) return `${(value / 1000).toFixed(value < 10_000 ? 1 : 0)}k`;
	return `${(value / 1_000_000).toFixed(1)}m`;
}

function formatTime(): string {
	const now = new Date();
	const hours = now.getHours().toString().padStart(2, "0");
	const minutes = now.getMinutes().toString().padStart(2, "0");
	return `${hours}:${minutes}`;
}

const graphemeSegmenter = new Intl.Segmenter(undefined, { granularity: "grapheme" });

export function truncateModel(
	model: string,
	length: number,
	symbol: string,
	direction: TruncationDirection,
): string {
	const safeModel = sanitizeTerminalText(model);
	if (length === 0) return safeModel;
	const graphemes = [...graphemeSegmenter.segment(safeModel)].map(({ segment }) => segment);
	if (graphemes.length <= length) return safeModel;
	const safeSymbol = sanitizeTerminalText(symbol);

	switch (direction) {
		case "start":
			return `${safeSymbol}${graphemes.slice(-length).join("")}`;
		case "middle": {
			const headLength = Math.ceil(length / 2);
			const tailLength = Math.floor(length / 2);
			const tail = tailLength > 0 ? graphemes.slice(-tailLength).join("") : "";
			return `${graphemes.slice(0, headLength).join("")}${safeSymbol}${tail}`;
		}
		case "end":
			return `${graphemes.slice(0, length).join("")}${safeSymbol}`;
	}
}

export function shortenModel(model: string): string {
	return model
		.replace(/^claude-/, "")
		.replace(/^gpt-/, "gpt ")
		.replace(/-20\d{6}$/, "")
		.replace(/-latest$/, "");
}
