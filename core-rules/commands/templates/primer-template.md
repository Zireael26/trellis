---
slug: <feature-slug>
purpose: <one-line description, under 200 chars — this is what shows in INDEX.md>
pinned_to: <git sha of the commit this primer was last validated against>
created: <YYYY-MM-DD>
last_refreshed: <YYYY-MM-DD>
related_primers: []
---

# <Feature Name>

## Purpose

One or two sentences. What does this feature do, and why does it exist? Skip implementation language — describe outcomes.

## Entry points

The 3–5 files where this feature starts. A debugger setting its first breakpoint would put it in one of these.

- `path/to/file1.py` — `function_name()` — what this handles
- `path/to/file2.py` — `ClassName` — what this owns
- `path/to/file3.py` — module-level wiring — what this configures

If a file is large, name the specific function/class. Avoid line numbers (they drift).

## Data flow

Trace one representative request or event from entry to exit. Be concrete about which files and functions hand off to which.

1. Request arrives at `entry/handler.py:handle_message()`
2. Dispatches to `core/router.py:route()` based on channel
3. Channel adapter (e.g., `channels/telegram.py:adapt()`) normalizes the payload
4. Core logic in `core/processor.py:process()` runs the persona pipeline
5. Response goes back via the same adapter
6. Telemetry written by `observability/log.py:emit()` at exit

Keep this under ~10 steps. If you need more, the feature is too big for one primer.

## Dependencies

Other features, services, or primers this touches.

- `<related-primer-slug>` — what we use it for
- External: `<service-name>` (e.g., "Postgres `messages` table", "Telegram Bot API")
- Internal modules outside this feature's tree

## Test commands

How to exercise the feature locally. Be exact — these should copy-paste.

```bash
# Start dependencies
make dev-up

# Run the focused test suite
pytest tests/marketing_chatbot/ -v

# Smoke test against the live local instance
curl -X POST http://localhost:8000/webhook -H 'Content-Type: application/json' -d '{"message": "test"}'
```

Include test data fixtures or seed commands if they're not obvious.

## Gotchas

Non-obvious things that bit during implementation. This section earns its keep over time — be specific about *why*, not just *what*.

- **Telegram webhook needs a public URL** — local testing requires ngrok or equivalent; the `make tunnel` target wraps this.
- **Persona is loaded once at startup** — changes to `personas/*.yaml` require a service restart, not just a config reload.
- **Message dedup key is `(chat_id, message_id)`** — not `update_id`, which differs across retries.

## Out of scope

What this primer deliberately does *not* cover. Helps future agents avoid scope creep.

- Sibling channels (WhatsApp, web widget) — see their own primers
- Admin dashboard — separate primer `marketing-chatbot-admin`
- Long-term memory persistence — handled by `memory-store` primer

## Notes

Free-form area. Use for caveats, unresolved questions, or breadcrumbs to other context (issue numbers, design doc links, decision records).
