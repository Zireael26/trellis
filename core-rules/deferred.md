# Deferred rules

Rules that are **candidates** for the parent layer but haven't earned their place yet. Each was seen in only one of the two reference projects (Neev, TGSC), or was seen in both with enough variation that lifting now would force a false abstraction.

Promotion criterion: a **third active project** independently adopts the rule (or a close variant). At that point, move it into `CLAUDE.md` or `hooks.md` as appropriate, note the three sources, and delete it here.

Demotion criterion: if after two more projects none pick it up, drop it entirely.

Ground truth for why this file exists: Rule of Three. `n=2` is the danger zone — enough repetition to feel like a pattern, not enough to confirm it isn't coincidence. Extracting at n=2 locks in the wrong shape and the wrong defaults. Waiting for n=3 is cheap; unwinding a bad abstraction isn't.

---

## Rules (narrative form, lift when a third project confirms)

### Two-perspective review
**Source:** Neev.
**What:** on non-trivial work, present a perfectionist critique alongside a pragmatist acceptance before proposing an action.
**Why defer:** valuable in Neev because features span multiple packages and trade-offs are routinely contested. Smaller projects may not benefit from the overhead.
**Lift when:** two more projects independently find value in the structured two-voice pattern (bringing total sources to 3).

### Fresh-eyes / new-user testing persona
**Source:** Neev.
**What:** when asked to test your own output, adopt a new-user persona and walk through as if you've never seen the project.
**Why defer:** strong testing heuristic but unclear it fits every project class (e.g., an internal CLI tool has no "new user" in the normal sense).
**Lift when:** two more projects — ideally in different classes from Neev's multi-tenant SaaS — adopt the persona.

### Bug autopsy after fix
**Source:** Neev.
**What:** after fixing a bug, explain root cause and whether a category-level prevention is possible (lint rule, test, type, invariant).
**Why defer:** requires meaningful bug volume to be worth the ceremony. Greenfield or small projects may not hit the threshold.
**Lift when:** two more projects reach enough operational maturity to want systematic autopsies.

### PR size soft-target 400 / hard-ceiling 800
**Source:** TGSC; clusterbid-console (registry: "PR size budget 400/800") — n=2.
**What:** PRs should aim for ≤400 changed lines; ceiling at 800. Larger PRs require justification.
**Why defer:** TGSC is a single Next.js app. Neev is a monorepo where cross-package refactors legitimately cross 800 lines (explicitly opts out). The numbers need per-project tuning before being a parent rule.
**Lift when:** one more project validates *some* numeric target works cross-class (n=3 total). At that point, lift the pattern (with project override) rather than specific numbers.

### Tech-spec-check CI job
**Source:** Neev.
**What:** CI blocks merges for changes past a size threshold without a corresponding tech spec doc.
**Why defer:** heavily coupled to Neev's EPM (engineering program management) flow. Worth lifting eventually but not yet.
**Lift when:** two more projects adopt a tech-spec requirement gate.

### PR-size-check CI job
**Source:** Neev.
**What:** CI surfaces PR line count and warns past the soft target. Sibling to the PR size rule above.
**Why defer:** same reasoning as the PR-size rule — numbers need per-project tuning. Lift together with the rule it enforces.
**Lift when:** PR-size rule is lifted.

### axe-core accessibility tests in CI
**Source:** TGSC.
**What:** automated a11y scan on every build; blocks on new violations.
**Why defer:** TGSC is a public marketing site where a11y is a launch-gate. An internal tool or API service may not need this floor. Better as a project-local rule for user-facing projects.
**Lift when:** two more user-facing projects adopt it *and* we can write a criterion for which projects should require it (not blanket).

### API surface gate
**Source:** Cowork audit 2026-05-08, n=0 in registry.
**What:** at PR time, diff the project's declared API surface (OpenAPI / GraphQL SDL / route table / RPC manifest) against `main`. Breaking changes (removed routes, removed fields, narrowed types, tightened required-ness) without an accompanying version bump or deprecation marker block the merge.
**Why defer:** the original "n=0 service-shaped projects" premise is now false — clusterbid-console (Go+Next.js+Python monorepo with `services/*`) and vericite (api-gateway, ai-service, k3s) are both service-shaped. No firsthand API-surface-diff adoption evidence yet, so the rule's exact shape — which manifest format, what counts as breaking, where the version bump lives — is still unsettled. Re-evaluate next cycle.
**Lift when:** three independent service-shaped projects each ship a route-surface diff at PR time. They don't have to use the same tool, but the rule converges only when there's evidence of a common shape across them.

### Migration safety gate
**Source:** Cowork audit 2026-05-08, n=0 in registry.
**What:** any DB migration that drops a column, narrows a type, adds a NOT NULL without a default, or changes a primary key is blocked without (a) a defaults-and-backfill plan documented in the PR body and (b) a tested rollback. Additive migrations pass.
**Why defer:** the "n=0 service-shaped projects" premise is now false — clusterbid-console and vericite are both service-shaped, and vericite/neev have already caught non-additive issues (idempotency, role-before-use, fresh-DB) via a Drizzle migrator (see Addition: Drizzle/Postgres fresh-DB migration). Still missing the specific "tested rollback caught a non-additive change *via the gate*" evidence; closest of the service-shaped entries to graduation. Re-evaluate next cycle.
**Lift when:** three service-shaped projects each have a migration runner (Alembic / Drizzle / Prisma migrate / Atlas / Goose) in CI and have caught at least one non-additive change with the gate.

### Container / Dockerfile health check
**Source:** Cowork audit 2026-05-08, n=0 in registry.
**What:** `Dockerfile` lint at PR time — pinned base image (no `:latest`), non-root runtime user, `HEALTHCHECK` declared, no secrets baked into layers, multi-stage build for any compiled language. Tooling: hadolint or equivalent.
**Why defer:** two service-shaped projects now exist (clusterbid-console, vericite — the latter ships a k3s deployment), so the "no Docker-shipping projects" premise is weakening, but there's no firsthand Dockerfile-lint adoption evidence yet. Promoting a Docker rule now would still lock in defaults from a hypothetical. Move from hypothetical to watch; re-evaluate next cycle.
**Lift when:** three projects in `registry.md` ship production container images and each runs a Dockerfile linter at PR time.

### service-verify hook
**Source:** Cowork audit 2026-05-08, n=0 in registry.
**What:** the service-equivalent of `ui-verify` — at turn end on a service-shaped project, boot the service against a fixture environment, hit a health endpoint, run a fast contract-test smoke, attach the response as a receipt. Parallel to the UI screenshot in §7 of `engineering-process.md`.
**Why defer:** the "no service-shaped project whose 'the service is up' is even definable" premise is now false — clusterbid-console and vericite are both service-shaped. No firsthand smoke-contract adoption evidence yet, so the hook contract (port? endpoint? what counts as a fixture?) still cannot be specified. Move from hypothetical to watch; re-evaluate next cycle.
**Lift when:** three service-shaped projects independently define a "is the service up?" smoke and run it as part of their `stop-verify` chain.

### `.env.example` sync check
**Source:** Cowork audit 2026-05-08, n=0 in registry.
**What:** at PR time, parse the running service's env-var consumption (e.g., `process.env.X` / `os.environ["X"]` / `Deno.env.get("X")`) and compare against the keys declared in `.env.example`. Missing keys in `.env.example` block the merge; orphaned keys (in `.env.example` but unused) warn.
**Why defer:** the "n=0 service-shaped projects" premise is now false — clusterbid-console and vericite are both service-shaped, and vericite's RSC self-call bug (2026-05-02, `NEXT_PUBLIC_SITE_URL` unset → 401 HTML) is an env-drift incident the gate targets (n=1). Still short of the threshold. Re-evaluate next cycle.
**Lift when:** three service-shaped projects each maintain a meaningful `.env.example` and have caught at least one drift incident the gate would have prevented.

### Drizzle / Postgres migration must run from an empty DB and can fail silently
**Source:** neev + vericite (n=2).
**What:** a migration set must be runnable from a fresh/empty database in isolation; each migration self-contained (create roles before use, idempotent DDL), and "Migrations complete!" must be verified against actual schema state.
**Why defer:** both sources are Drizzle/Postgres; a third on a *different* runner is needed to know whether to phrase the rule as Drizzle-specific or runner-agnostic. (Related to the Migration safety gate entry above.)
**Lift when:** a third project running a migration runner reports a fresh-DB bootstrap or silent-no-op migration failure.

### A11y must be verified against fully-rendered, data-seeded DOM — not empty states or by eye
**Source:** akaushik.org + vericite (n=2).
**What:** run axe against the populated, every-state DOM; design intuition under-delivers on contrast and visual reordering breaks source order.
**Why defer:** both sources are user-facing web projects; adjacent to but distinct from the `axe-core in CI` entry (which is about adopting the gate — this is about *what the gate must run against*). Needs a third user-facing project to confirm.
**Lift when:** a third user-facing project independently reports an a11y miss that empty-state/by-eye checking let through.

### Don't ship config that advertises an unbuilt or unrequested capability
**Source:** neev + akaushik.org (n=2).
**What:** a config/manifest declaration must be gated to the commit that actually lands the capability it advertises; speculative wiring creates false operational signals or 404s for anything that follows the declaration.
**Why defer:** both instances are config-manifest mismatches (neev `vercel.json` crons, akaushik `mcp.json` endpoint), but the blast radius differs (background-job implication vs route 404). Needs a third instance to confirm the shape.
**Lift when:** a third project hits a bug or false signal caused by config advertising a capability that isn't built.

### Multi-tenant explicit tenant filter / per-session tenant context
**Source:** neev + vericite (n=2).
**What:** every multi-tenant query path must carry an explicit tenant filter and every request/job must establish per-session tenant context; broad OR permission gates and unset `tenant`/`app.current_tenant_id` leak across tenants or dead-end routes.
**Why defer:** both sources are multi-tenant SaaS with RLS, so this may be architecture-class-specific rather than universal. Queue and watch for a third multi-tenant project before lifting.
**Lift when:** a third multi-tenant project independently adopts an explicit-tenant-filter / per-session-context rule.

---

## Meta

- Adding to this file is not a rejection. It's a parking spot.
- When adding: name the rule, cite the single source, state what would count as a third-project confirmation.
- When lifting: note which three projects confirmed, move the rule to `CLAUDE.md` or `hooks.md`, delete the entry here.
- Review cadence: every new project onboarding triggers a pass over this file. Otherwise quarterly.
