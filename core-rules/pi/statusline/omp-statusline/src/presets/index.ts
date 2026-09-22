import {
	type PaletteName,
	type PalettePreset,
	type PowerlineBlockName,
	SEGMENT_NAMES,
	type SegmentName,
	type SegmentPalette,
} from "../types.ts";
import { CANDY_PRESET } from "./candy.ts";
import { CUSTOM_PRESET } from "./custom.ts";
import { FOREST_PRESET } from "./forest.ts";
import { MONO_PRESET } from "./mono.ts";
import { NEON_PRESET } from "./neon.ts";
import { OCEAN_PRESET } from "./ocean.ts";
import { SUNSET_PRESET } from "./sunset.ts";
import { TOKYO_NIGHT_PRESET } from "./tokyo-night.ts";
import type { PowerlinePreset } from "./types.ts";

const PRESETS = {
	"tokyo-night": TOKYO_NIGHT_PRESET,
	ocean: OCEAN_PRESET,
	sunset: SUNSET_PRESET,
	forest: FOREST_PRESET,
	candy: CANDY_PRESET,
	neon: NEON_PRESET,
	mono: MONO_PRESET,
	custom: CUSTOM_PRESET,
} satisfies Record<PalettePreset, PowerlinePreset>;

const SEGMENT_BLOCKS: Record<SegmentName, PowerlineBlockName> = {
	brand: "header",
	provider: "header",
	model: "header",
	thinking: "header",
	cwd: "directory",
	branch: "git",
	tools: "runtime",
	context: "runtime",
	tokens: "runtime",
	cache: "runtime",
	cost: "meter",
	time: "meter",
	turn: "meter",
	hostname: "header",
	session: "git",
	subagents: "git",
	commit: "git",
	token_in: "runtime",
	token_out: "runtime",
	token_total: "runtime",
	token_rate: "runtime",
	cache_read: "runtime",
	cache_write: "runtime",
	cache_hit: "runtime",
	context_total: "runtime",
	time_spent: "meter",
};

export function resolvePreset(preset: PalettePreset): PowerlinePreset {
	return PRESETS[preset];
}

export function segmentPaletteForPreset(preset: PaletteName): SegmentPalette {
	const blocks = PRESETS[preset].blocks;
	return Object.fromEntries(
		SEGMENT_NAMES.map((name) => [name, { ...blocks[SEGMENT_BLOCKS[name]] }]),
	) as SegmentPalette;
}
