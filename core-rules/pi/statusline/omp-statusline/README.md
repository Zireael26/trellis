# omp-statusline

Local fork of [`@narumitw/pi-statusline`](https://www.npmjs.com/package/@narumitw/pi-statusline)
(v0.50.0, MIT, by narumiruna, source at
[narumiruna/pi-extensions](https://github.com/narumiruna/pi-extensions/tree/main/packages/pi-statusline))
that adds the segments Oh My Pi's status line shows and pi-statusline lacks, so a pi footer can
mirror the OMP `nerd` preset. All upstream segments, palettes, the `/statusline` command, and the
`~/.pi/agent/pi-statusline.json` settings file keep working unchanged.

Credit: everything except the segments listed below is narumiruna's work. See `LICENSE`.

## Added segments

Formatting follows `oh-my-pi/packages/coding-agent/src/modes/components/status-line/segments.ts`;
number and duration formatting follows `@oh-my-pi/pi-utils` `formatNumber` / `formatDuration`
(`25K`, `1.5M`, `3m12s`). Default prefixes are OMP's Nerd Font glyphs (`symbolPreset: nerd`);
override them under `segmentText` like any upstream segment.

| Segment | Value | Source (public pi extension API) |
| --- | --- | --- |
| `hostname` | short host name | `os.hostname()` |
| `session` | first 8 chars of the session id, `new` if none | `ctx.sessionManager.getSessionId()` |
| `subagents` | live running + queued count, hidden at 0 | parsed from the `subagents` status that `@tintinweb/pi-subagents` publishes through `ctx.ui.setStatus` (read via `footerData.getExtensionStatuses()`); the duplicate status row is hidden while the segment is configured |
| `commit` | short `HEAD` hash (not an OMP segment, added on request) | `git rev-parse --short HEAD` via `pi.exec`, refreshed with the git status poll |
| `token_in` / `token_out` | session input / output tokens, hidden at 0 | `ctx.sessionManager.getEntries()` usage |
| `token_total` | input + output + cache writes (OMP formula; cache reads excluded) | same |
| `token_rate` | output tok/s of the latest finished assistant message, sticky until the next one | `message_start` / `message_end` events + `usage.output` |
| `cache_read` / `cache_write` | session cache read / write tokens, hidden at 0 | session usage |
| `cache_hit` | `cacheRead / (cacheRead + cacheWrite + input)` as `NN.NN%` | session usage |
| `context_total` | context window size | `ctx.getContextUsage()` / `ctx.model.contextWindow` |
| `time_spent` | active agent time: union of `agent_start` to `agent_end` windows, ticking while running (OMP semantics, not wall-clock) | agent events + 1 s ticker |

Existing upstream `context`, `cost`, `time`, `tokens`, and `cache` cover OMP's `context_pct`,
`cost`, `time`, and the combined token/cache readouts.

## Layout used here

`~/.pi/agent/pi-statusline.json` lists the segments in OMP `nerd` preset order, with a
`line_break` between OMP's right group (row 1) and left group (row 2):

```text
row 1: token_in token_out cache_read cache_write token_rate cost context context_total time_spent time
row 2: hostname model thinking cwd branch session subagents tools
```

## Install

The directory is auto-discovered by pi (`~/.pi/agent/extensions/*/package.json` with a `pi.extensions`
entry). Its one runtime dependency, `@narumitw/pi-tui-kit`, lives in the local `node_modules/`
(`npm install --omit=dev --legacy-peer-deps`). The original npm package stays installed but its
extension is disabled in `~/.pi/agent/settings.json` with the package-filter object form
(`{"source": "npm:@narumitw/pi-statusline", "extensions": []}`) so the two footers do not fight.

## Not implemented

- OMP's `pi`, `mode`, `pr`, `session_name`, `usage`, and `collab` segments: `pr` is already folded
  into upstream's `branch` segment; the rest depend on OMP-only runtime state.
- OMP's editor top-rule placement and context gauge line: pi's `setFooter` only renders below the
  editor, so both rows render there.
