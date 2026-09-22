import type { PowerlineBlockName } from "../types.ts";

export interface BlockColors {
	fg?: string;
	bg?: string;
}

export interface PowerlinePreset {
	lead?: string;
	blocks: Record<PowerlineBlockName, BlockColors>;
	extensionSeparator?: string;
}
