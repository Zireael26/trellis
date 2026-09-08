# Web search in Pi (opt-in, backed by antigravity)

This opt-in tool gives a Pi session one Google Search grounding call per
invocation through the antigravity credential that Pi already owns. It is not
loaded by default, changes no Pi settings, adds no credential store, and runs no
browser. The parent model can be any model Pi is running; the search itself
always goes to antigravity.

**Status: qualified for exactly one parent route; opt-in only.** On 2026-09-08 the
seventh registered canary (`spec047-canary-v7-20260908`) met the Spec 047 SC6
minimum runtime proof under the frozen oracle: the Pi parent
`meta/muse-spark-1.3-contributor` made three real `trellis_web_search` calls
(counters 1/2/3, frozen query forwarded byte-exactly), passed all three factual
cells under independent delegated-root assessment (xai/grok-4.6, review ages
101.5 / 71.2 / 104.8 s against a 120 s bar), the canary project was rolled back to
release 1.0.0 (39/39 prior hashes, search directory and config absent), and the
same-run ordinary-inference check after rollback returned exactly
`ordinary-inference-ok` with no tool events. Supported: Pi 0.85.1 with
pi-antigravity 0.7.0, parent `meta/muse-spark-1.3-contributor`, backend
`antigravity/gemini-3.8-flash` (runtime `gemini-3.8-flash-low`), `max_calls` 3.

**Not verified.** No other parent family has live proof. The native Codex
baseline and the OpenAI (`gpt-5.6-luna`) Pi parent were registered *unrun* in the
last three registrations to conserve the operator's OpenAI quota (their earlier
identical-oracle baseline results are historical evidence only); Gemini parents
were exhausted on the shared antigravity bucket from the fourth registration
onward. Claude parents were excluded by routing policy. Treat any other parent as
unsupported until it has its own receipt.

**History, stated plainly.** Seven registrations started 27 cells in total
(8+1+4+4+3+3+4); the first six each failed or halted under their frozen rules
(wrong Git timestamp and an overbroad negative rule in v1, pane loss in v2, a
late root review in v3, Gemini exhaustion in v4, one extra-assertion fail in v5,
one uncaptured-citation fail in v6). Every earlier grade stands unchanged; two
later corrections exist only as labelled sidecars. The adapter source never
changed across the seven runs; every change was to the controller, oracle wording
or protocol. Full record:
the canary validation record, the receipt index and the release report. Those live in
the private instance repository and are not part of this mirror, so they are named here
rather than linked.
Treat every result from this tool as unverified until you inspect its sources.

## Prerequisites

- An attached Trellis project on a release containing `core-rules/pi/web-search/`.
- Pi 0.85.1 with `pi-antigravity` 0.7.0 installed and logged in the ordinary way
  (`/login antigravity`). The tool asks Pi's model registry for that credential
  at call time; it never reads auth files, environment keys, or any other store.
- macOS on Apple silicon. Other host profiles return `unavailable/unsupported_profile`.

## Configuration

Create a **task-private regular file** (not a symlink, at most 8 KiB) **outside
the checkout**, for example under an absolute temporary directory such as
`"$TMPDIR/trellis-search-<task>/web-search.json"`, containing exactly these
five keys and nothing else. A path inside the repository is not guaranteed to
be Git-excluded.

```json
{"provider":"antigravity","model":"gemini-3.8-flash","runtime_model":"gemini-3.8-flash-low","endpoint":"daily","max_calls":3}
```

- `model` is the logical Pi model id registered by the antigravity plugin;
  `runtime_model` is the exact provider runtime id sent on the wire. Neither is
  substituted or "upgraded" at runtime; a rejected model is a failed call.
- `endpoint` must be `daily` (`https://daily-cloudcode-pa.googleapis.com`). If an
  `ANTIGRAVITY_BASE_URL`/`NOAGY_BASE_URL` override points elsewhere, calls return
  `unavailable/endpoint_mismatch` rather than following it.
- `max_calls` (1–9) is the number of admitted attempts for the **lifetime of the
  loaded extension instance**. It does not reset on a new conversation and cannot
  be raised without restarting Pi. Failed attempts count; `busy` and
  budget-exhausted refusals do not.
- The file holds no credential values. The config is read once, on the first
  call, and frozen. Any unknown key, wrong type, or out-of-range value makes the
  tool report `unavailable/config_invalid` with an unknown budget.

## Starting a session

```sh
TRELLIS_WEB_SEARCH_CONFIG="$TMPDIR/trellis-search-<task>/web-search.json" \
  pi -e "$PWD/.trellis/runtime/core-rules/pi/web-search/index.ts"
```

`-e` on the adopted runtime copy is the documented, supported opt-in; the tool is
not auto-discovered and is not part of any default tool set.
The tool registers as `trellis_web_search` and is intended for **serial** use.
A second call while one is in flight returns `error/busy` and consumes nothing.

## What a call does

`trellis_web_search({query, max_results?})` — query 1–4,000 characters,
`max_results` 1–10 (default 5). The tool makes **one** HTTPS POST to the daily
endpoint with a fixed request profile and a single 90-second deadline covering
credential resolution, the request, and stream parsing. There is no retry, no
alternate endpoint, and no model fallback inside the tool; the deadline is also
checked during synchronous parsing, so a late success is refused rather than
returned. The request profile (headers and body shape) is part of the
implementation, not a user setting.

A call succeeds only when the provider reports that a search actually ran, at
least one valid `http(s)` source came back, and the answer is nonempty. Text
that merely contains links is `error/no_search_evidence`. The result shows the
answer, then a numbered source list; URLs are shown as received (grounding
redirect links are labelled unresolved) and are never fetched by the tool.
Citations map answer spans to sources only when the provider's offsets validate;
otherwise sources are listed without links to spans. Output is bounded at 32 KiB
including the source list; truncation is labelled, and an answer cut by the
provider's own output limit carries a separate label.

## Usage, cost, and account notes

- Token counters are reported only when the provider sends them; absent or
  malformed counters stay `unknown`, never zero. Nothing is summed or priced.
  Search fees, if any, are not visible to the tool.
- The call is real inference on the antigravity account, counted **separately**
  from the parent model's usage. Report the nested search separately; the
  parent's counters alone do not establish complete search usage.
- Account binding is **unknown** and capacity protection is **advisory**: the
  tool cannot pin an account or reserve headroom. Workflows that require
  confirmed headroom must not select this path; there is no argument or setting
  that makes it protected.
- Failures are content-free diagnostics (`http_auth`, `http_rate_limited`,
  `provider_error`, `deadline`, …). The **cost-only receipt projection** carries
  identity, status, timing and counters only, never the query, answer, sources,
  bearer token, project id, or provider error bodies. Ordinary tool results and
  task canary receipts do include the public query, answer and sources.

## Alternative: native Codex search

For a unit that needs search on the Codex harness, use Codex CLI's own search
instead: `codex --search exec "<prompt>"` with an explicit model and effort as
appropriate. This is a natively available alternative, not a verified quality
alternative. It was exercised only as the historical baseline of the earlier
registrations (v1, v3 and v4, 2026-09-07): there it answered the two positive
questions correctly but failed the frozen negative-case rule in every run (v1's
overbroad "any concrete date" rule, later corrected; v3 and v4 on extra
assertions). It was registered unrun in the fifth to seventh registrations to
conserve the operator's OpenAI quota, so the qualifying v7 canary ran no Codex
cell at all and makes no claim about it.
The two paths are not equivalent and neither falls back to the other
automatically.

## Opting out and restoring a release

To stop using the tool, end the session, delete the task-private config file,
and start `pi` without the `-e` entrypoint. That is an opt-out, not a release
rollback. If the tool arrived through a candidate release adoption, restore the
prior release for that project with the supported path — `trellis release
verify <prior>` then `trellis release adopt <prior> --project <id>` — and record
the verify/adopt receipts; do not assume nothing else changed.
