# Fleet hosting substrate policy

- **Date:** 2026-08-07
- **Status:** **ACCEPTED 2026-08-08.** Supersedes nothing. The Neev app-tier migration is tracked
  as separate scoped work — see §5; accepting this ADR does not foreclose it.
- **Scope:** All Trellis-registered projects with public hostnames, plus unregistered zones found in the operator's Cloudflare account.
- **Trigger:** Operator asked whether to consolidate every site onto Vercel, or onto Cloudflare, given that Cloudflare is currently used only for DNS on several zones.

---

## 1. Context

The working assumption behind the question was that the fleet runs on Vercel with Cloudflare
serving DNS only, and that a stray k3s cluster is an accident to be cleaned up. Measurement on
2026-08-07 shows the fleet actually runs on **three** substrates, and the third one exists for a
reason that neither Vercel nor Cloudflare Workers can currently absorb.

### 1.1 Measured hosting map

Built from the Cloudflare API across all 8 zones the operator's user-owned token can reach,
then confirmed by following redirects and reading response headers on each hostname.

| Zone | Hostname | Origin | Notes |
|---|---|---|---|
| akaushik.dev | apex, www | Vercel | 301 to akaushik.org |
| akaushik.org | apex, www | Vercel | canonical |
| bwdev.site | apex + 8 subdomains + wildcard | OVH VPS `139.99.130.129` (Sydney) | **HTTP 522, origin unreachable.** Retired UAT environment for curat.money — **decision to retire taken 2026-08-08, see §4.1.** |
| gwtf.in | apex | Vercel | `media.gwtf.in` to `public.r2.dev` |
| onneev.com | apex, app | k3s via Cloudflare Tunnel `eb2332d7` | the real application |
| onneev.com | www | Vercel | 301 to apex — correct |
| onneev.com | console, demo, docs | Vercel | `demo` is the `msme-neev` project |
| onneev.in | apex, app, console, www | Vercel | 301 to onneev.com — correct |
| vericite.ai | apex, www | Vercel | www 301 to apex — correct |
| vericite.ai | api, auth, demo, widget | k3s via Cloudflare Tunnel `3979b1aa` | Python services |
| vericite.site | all | mixed, canonical 301 to vericite.ai | legacy alias, behaving correctly |

Two distinct Cloudflare Tunnels, one per product. Postgres and Redis for Neev run
**inside** the k3s cluster (`neev-postgres-0`, `neev-redis-0`), not on Neon or Upstash,
despite the deployment runbook still describing a Vercel-plus-Neon topology.

### 1.2 Two hypotheses tested and rejected

Both were plausible failure modes worth ruling out before recommending anything.

**Rejected: apex/www split-brain serving different builds.** Following redirects shows
`www.onneev.com`, `onneev.in`, `www.vericite.ai`, `vericite.site`, and `akaushik.dev` all
canonicalize with a 301 to their apex. Canonicalization is correct fleet-wide.

**Rejected: a second live production database behind the stale Vercel deployment.**
`vercel env ls` on `msme-neev` returns 15 variable names in Production and **none of them is a
Postgres, Neon, or `DATABASE_URL` value**. The project carries Upstash Redis, `VERICITE_MODE`,
`MARKETING_CHAT_ENABLED`, and site URLs. It is a marketing/demo shell, not a second copy of the
application, and there is no parallel dataset accumulating real signups.

### 1.3 The binding constraint

`docs/rfcs/k3s-worker-deploy-2026-06-14.md` in the Neev repo states the case directly:

> `@neev/worker` hosts **all** async behaviour: ~170 event-bus consumers, the intake LLM
> pipeline, WhatsApp inbound/timeout/catalog queues, outbound API dispatch (e-invoice,
> payments, notifications), the webhook inbox, and every scheduled sweep. It has **never** run
> in production — Vercel hosts only the Next.js app and `vercel.json` carries no crons.

The final sentence is now superseded: the worker **is** running in production on k3s, since
roughly 2026-08-04, and was rolled to `2642a1d` on 2026-08-08 with every consumer initializing
cleanly. What the RFC still establishes, and what this ADR relies on, is the *shape* of the
workload — the reason it needed a container host rather than Vercel in the first place.

The worker is a **singleton by design**: `replicas: 1` with `strategy.type: Recreate`, because
RollingUpdate rounds `maxSurge` up to 1 and would briefly run two pods, double-consuming BullMQ
jobs. VeriCite adds its own container-shaped workload — Python `ai-service`,
`document-service`, and `api-gateway` behind the second tunnel.

Neither consolidation target can host that as-is:

- **Vercel** has no long-lived process. Functions are request-scoped; Cron Jobs fire HTTP
  invocations on a schedule and cannot hold ~170 persistent event-bus subscriptions or a BullMQ
  worker loop. Moving the worker to Vercel means rewriting it as scheduled HTTP handlers plus a
  hosted queue, and moving Postgres out of the cluster to a managed provider.
- **Cloudflare Workers** are request-scoped V8 isolates. Replacing BullMQ with Queues, Durable
  Objects, and Cron Triggers is a rewrite of the same ~170 consumers, plus the Python services
  have no Workers runtime at all. Next.js on Workers also requires the OpenNext adapter, which
  is friction Vercel does not have.

**Full consolidation onto either platform is not a configuration change. It is a rewrite of the
async tier.** That is the single most important correction to the premise.

---

## 2. Decision

Route by **workload shape**, not by vendor preference. Three tiers:

| Workload | Substrate | Rationale |
|---|---|---|
| Static / SSG marketing, docs, redirect-only aliases | Either Vercel or Cloudflare Workers+R2 | Both are adequate. **Do not churn a working live site to move it.** New static sites default to Cloudflare Workers + R2 (duta already sets this precedent). |
| Next.js with dynamic routes against a **managed** database | Vercel | Best-in-class adapter, preview deploys, zero OpenNext friction. |
| Long-running, singleton, Python, or self-hosted Postgres/Redis | Container host (k3s stays) | No serverless platform hosts this today. |

Two invariants, both currently satisfied and worth keeping enforced:

1. **Apex and www must resolve to the same served content.** Aliases 301 to canonical.
2. **One canonical domain per product.** Alias domains redirect; they never serve.

### 2.1 Per-zone application

- **onneev.com** — keep as is **for now**; migration to Vercel/Cloudflare is intended, see §5.
  Apex and `app` on k3s remains correct *while* Postgres lives in-cluster and the worker is a
  singleton — those are the conditions to change, not the hosting. `www`, `console`, `demo`,
  `docs` stay on Vercel and are unaffected either way.
- **vericite.ai** — keep as is. Marketing on Vercel, Python services on k3s is a coherent split,
  not an accident.
- **gwtf.in, akaushik.org, akaushik.dev, onneev.in, vericite.site** — already correct. No change.
- **bwdev.site** — **retire.** Dead UAT environment for curat.money. No substrate tier applies;
  it leaves the fleet rather than moving within it. Teardown sequence in §4.1.

### 2.2 What would have to change for "everything on Vercel"

Recording the actual cost so the option stays open rather than being hand-waved away:

1. Move `neev-postgres-0` to a managed Postgres (Neon or similar), with a migration and cutover.
2. Move `neev-redis-0` to Upstash. The `msme-neev` project already carries Upstash credentials.
3. Rewrite `@neev/worker` from a persistent BullMQ consumer into scheduled HTTP handlers plus a
   hosted queue, preserving singleton semantics that `replicas: 1` currently guarantees for free.
4. Rehome VeriCite's Python services, which have no Vercel runtime, to a container host anyway —
   so the cluster does not actually go away.

Step 4 alone means the migration does not achieve the stated goal of retiring the cluster.

---

## 3. Consequences

- The cluster stays. Its cost is justified by workloads that have no serverless equivalent, not
  by inertia.
- Cloudflare sits in front of proxied zones as CDN plus DNS. Two consequences already observed
  today: proxying strips `x-vercel-id`, which briefly misled origin identification; and the
  AI-bot policy layer lives here, which is where gwtf.in's total answer-engine blackout came
  from — a default nobody chose.
- After **2026-09-15**, Cloudflare's new-domain defaults block Agent and Training crawlers on
  pages carrying ads. "Check AI bot policy" therefore becomes a mandatory onboarding step for
  any Cloudflare-proxied zone, and belongs in the proposed `aeo-gate` as a check rather than in
  tribal memory.
- Deliberately **not** decided here: whether the k3s cluster should move to a managed Kubernetes
  or stay self-hosted. That is a separate cost-and-reliability question.

---

## 4. Open items

1. ~~**`bwdev.site` is down and unmanaged.**~~ **RESOLVED 2026-08-08 — dead project, retire.**
   Operator confirms `bwdev.site` was the **UAT environment for curat.money**, which no longer has
   one. That provenance is corroborated by the registry: curat.money was renamed from `swipe` on
   2026-04-24 (`registry.md`), the zone's orphaned Vercel project is `swipe-web`, and the
   subdomain set matches curat.money's declared infra dependencies — `minio` against
   `PostgreSQL, Redis, MinIO, Mailpit`, and `auth` against `Kratos, Hydra`.

   So this was never unregistered infrastructure in the sense §4 originally implied. It was a
   *environment* of a registered project, and `registry.md` has no column for environments. The
   gap the audit found is real but it is not a missing registry row — it is that **non-production
   environments are untracked fleet-wide**. Recorded against curat.money's registry row rather
   than added to `blacklist.md`, whose two sections cover registered projects and git repos under
   `/personal/` and would mis-file a bare domain.

   **DNS snapshot, captured 2026-08-08 before any teardown** — 11 records, all A records to the
   same origin. This is the only durable record of the topology once the zone is gone:

   | Type | Name | Content | Proxied |
   |---|---|---|---|
   | A | `*.bwdev.site` | `139.99.130.129` | true |
   | A | `admin.bwdev.site` | `139.99.130.129` | true |
   | A | `api.bwdev.site` | `139.99.130.129` | true |
   | A | `assets.bwdev.site` | `139.99.130.129` | true |
   | A | `auth.bwdev.site` | `139.99.130.129` | true |
   | A | `bwdev.site` | `139.99.130.129` | true |
   | A | `content.bwdev.site` | `139.99.130.129` | true |
   | A | `grafana.bwdev.site` | `139.99.130.129` | true |
   | A | `minio.bwdev.site` | `139.99.130.129` | true |
   | A | `prometheus.bwdev.site` | `139.99.130.129` | true |
   | CNAME | `www.bwdev.site` | `bwdev.site` | true |

   Zone `6e6b24d08969050bda04d6555697087b`. Two subdomains the original audit never named:
   `minio` and `prometheus`. There is also a **wildcard `*.bwdev.site`**, so the eight named
   subdomains understate the surface — any hostname resolved to that VPS.

   Note that `www` is a CNAME to the apex, which resolves to OVH. The Vercel `swipe-web` project
   (`prj_ube8pTmJLuVKTek5XsbjnafjypWg`, SvelteKit, `live: false`) claims **both `bwdev.site` and
   `www.bwdev.site`** as production domains — the original write-up recorded only `www` — but
   **is not serving either**; DNS never pointed there. Its last production deployment is
   2026-03-27, 134 days stale.

   **Both domains detached 2026-08-08.** The project retains only
   `swipe-five-theta.vercel.app` and is otherwise untouched. No traffic change, as DNS never
   resolved to Vercel. Worth noting for anyone verifying this: the Vercel MCP `get_project` call
   kept returning both domains after the deletions succeeded — `GET /v9/projects/swipe-web/domains`
   is the authoritative read.

   **VPS status corrected 2026-08-08: the OVH box is already terminated** (operator). The audit's
   "ICMP responds, so the host is up" inference was wrong — re-probed on 2026-08-08, `139.99.130.129`
   still answers ICMP at ~290 ms (consistent with Sydney) while both `https://bwdev.site` and the
   origin IP directly time out. ICMP reachability of a provider-held or reassigned address is not
   evidence that our host is up. Same failure signature the audit named elsewhere: an inference
   drawn without the probe that would have distinguished the cases.

   **This leaves dangling DNS, which is the one live issue on the zone.** All 11 records still point
   at an IP that is no longer ours, `proxied: true`, and one of them is a **wildcard**. If OVH
   reassigns `139.99.130.129`, Cloudflare will proxy `bwdev.site` and *any* subdomain to a stranger's
   origin, serving it under our domain with a valid Cloudflare certificate. Nothing about that is
   hypothetical or exotic — it is ordinary dangling-DNS exposure, and the wildcard is what makes the
   blast radius the whole namespace rather than eight names.

   **Zone retained by operator decision 2026-08-08**, so the exposure is accepted for now rather than
   closed. Deleting the zone is the fix and it is cheap: the DNS snapshot above makes it recoverable,
   and no traffic depends on it. Note that zone deletion is *not* domain cancellation — the
   registration renews independently, wherever it is registered.
2. **`msme-neev` Vercel production is 42 days stale** and serves `demo.onneev.com`. Either
   redeploy it or detach the domain.
3. ~~Neev port coupling (finding F10)~~ **retracted 2026-08-08** - both Dockerfiles set the ports explicitly; no fix needed and no release blocker.

---

## 5. Tracked follow-on: Neev app-tier migration

Recorded 2026-08-08, when this ADR was accepted. The operator intends to move all Neev surfaces to
Vercel or Cloudflare, "depending on what suits it better." That decision rule **is** §2, so this is
a continuation of this ADR rather than a departure from it, and every static surface already
complies. Scoping the one tier that does not:

| Surface | Today | Migration work |
|---|---|---|
| marketing, `www`, `console`, `docs` | Vercel | none — already there |
| `demo` | Vercel (`msme-neev`) | none hosting-wise; see §4.2 staleness |
| **apex + `app`** | k3s | **the whole of §2.2** |

The app tier is not a substrate flip. Three coupled facts make it a rewrite:

1. `@neev/worker` holds ~170 persistent event-bus subscriptions plus a BullMQ loop. Neither Vercel
   Functions nor Workers isolates can hold a long-lived consumer.
2. It is a **singleton by construction** — `replicas: 1` with `strategy: Recreate`, because
   RollingUpdate rounds `maxSurge` up and would double-consume jobs. Any queue replacement must
   reproduce that guarantee explicitly; today the deployment topology provides it for free.
3. Postgres and Redis are **in-cluster** (`neev-postgres-0`, `neev-redis-0`), and the frontend is
   schema-coupled — so the frontend cannot move ahead of the database.

**The cluster does not retire regardless.** VeriCite's `ai-service`, `document-service`, and
`api-gateway` are Python and have no Vercel or Workers runtime (§2.2 step 4). If retiring k3s is the
motivation for the migration, that motivation is unavailable while VeriCite stands, and the
migration should be justified on other grounds — or sequenced behind a VeriCite plan.

Suggested gate before committing engineering time: decide whether the target is Vercel + managed
Postgres + a hosted queue, or Workers + Queues + Durable Objects + Hyperdrive. They are different
rewrites of the same ~170 consumers, and §2.2 prices only the first.
