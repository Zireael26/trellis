---
name: writing
description: Draft and publish blogs and X threads in the author's or project's voice, gated by a scriptable anti-AI-tell check. Explicit invocation only — covers voice loading, drafting, self-review, validation, publishing, and receipts.
argument-hint: "[blog|thread|both] [target repo / X account] [topic / source refs] [--draft]"
disable-model-invocation: true
---

# writing

The canonical publishing skill (12th). The fleet's SEO plumbing is already
gated — process-gate Gate 6 (`web-seo.md`, `web-agent-readiness.md`) owns meta,
sitemaps, canonicals, and agent surfaces — but nothing owned the content
itself. This skill owns the content half: authoring in the operator's or
project's voice, screening out AI tells with a scriptable check, and publishing
with receipts. Born from the 2026-07-08 live run (loop-era blog + 6-tweet
thread) that proved the full pipeline and then left it stranded in one
session's context; this document makes it durable.

Ships under `core-rules/skills/writing/`, so it reaches every onboarded project
via symlink inheritance and the public mirror via the existing wholesale sync —
no per-project wiring, no sync-path edits.

## Invocation contract

The operator's explicit invocation IS the authorization. Its named targets —
which repo, which account, blog and/or thread — bound the scope for THIS RUN
ONLY. Nothing beyond the named surfaces is in bounds.

- **No named target, no publish.** Auto-post requires the publish targets to be
  explicit or unambiguous from the invocation: the target content repo for a
  blog, the X account for a thread. Never infer a publish surface from cwd or
  from whichever account happens to be logged in — if any target is missing or
  ambiguous, stop and ask, or complete the run as `--draft`. Authoring may
  proceed; publishing may not.
- **Full auto-post.** Once targets are named: on a fully-capable host, run
  draft → validate → publish → receipts with no mid-run approval stop. The
  invocation was the approval.
- **`--draft`** stops before the publish stage and hands over paste-ready
  output (blog file + numbered thread text) instead.
- **Model-initiated invocation is forbidden.** `disable-model-invocation: true`
  is the enforcement; on harnesses without that switch, the narrow description
  is the soft guard and you never propose-and-run this skill on your own
  initiative. Flipping this is a bright-line change requiring its own ADR.
- **Never delete or edit already-published content.** Publishing is
  append-only; corrections are new content, and the operator's call.

## The six stages

1. **VOICE.** Load `docs/voice.md` from the TARGET content repo — the repo
   being published to, never this one. Voice files are instance-local by
   design; living outside `core-rules/` means the mirror sync structurally
   cannot ship them. Schema, seeding procedure, and degrade path:
   `references/voice.md`. Missing file → derive voice from the published
   corpus and propose seeding it; never block on absence.
2. **DRAFT.** Per content type: blog follows the target repo's own content
   conventions (frontmatter, directory layout, changelog rules); thread
   follows the mechanics in `references/x-thread.md` (tweet count, hook first,
   link-in-reply).
3. **SELF-REVIEW.** Read the draft against the voice file and
   `references/ai-tells.md`. Clustering is the signal — single tells are
   noise. Fixes preserve the loaded voice; never flatten content to pass.
4. **VALIDATE.** The validator ships with THIS skill, not the target repo —
   resolve it from the skill's own directory (the project's
   `.claude/skills/writing/` or `.agents/skills/writing/` symlink), never as a
   bare relative path, which in the target repo would hit that repo's own
   `scripts/` or nothing:
   `bash "$SKILL_DIR/scripts/check-writing.sh" --blog <file>` and/or
   `--thread <file>`. Red output BLOCKS publish: fix the named offenders and
   re-run until green. Never publish on red — a red is a defect in the draft,
   not a formality.
5. **PUBLISH.** The blog leg rides the target repo's own pipeline — branch,
   PR, its process-gate and repo rules. Conform to the destination's process;
   never bypass it. The X leg follows the posting mechanics in
   `references/x-thread.md` and is capability-gated (table below).
6. **RECEIPTS.** Report what was published where: live URLs (post + thread
   permalink), the green scan output, and the PR/merge trail. Receipts are
   part of done, not an optional summary.

## Capability gates + degrades

Capability-gated, not identity-gated (orchestrate precedent): check the actual
capability, then take the row's degrade. One row is a hard stop, not a degrade.

| Capability | Have it | Missing → degrade |
|---|---|---|
| Logged-in Chrome + Claude-in-Chrome | post the thread | paste-ready thread handoff (numbered tweets + trailing-reply link) |
| Target content repo present + writable | blog PR through its pipeline | draft-file handoff (blog body + placement instructions) |
| Claude Code harness | both publish legs available | Codex harness: author + validate only; both publish legs hand off |
| `check-writing.sh` runnable at the skill's own `scripts/` (via the skill-dir symlink) | the validation gate | **HARD STOP** — validation is not optional; report the missing script, publish nothing |

## Anomaly posture

Any unexpected publish-surface state — X login gone, composer state not what
the mechanics doc predicts, a half-posted thread, the blog PR gate red — means
ABORT and surface the exact state: what published, what didn't, what the
surface looked like. Never blind-retry a publish action — a retried click can
double-post; a surfaced abort costs one operator look.

## Boundaries

- No content strategy — the operator decides what to write about.
- No engagement automation, no scheduled posting, no analytics, no
  cross-posting to other networks.
- No deletion or editing of published content (contract above).
- Volatile references (`references/ai-tells.md`, `references/x-thread.md`)
  carry captured-on dates and re-verify triggers in their headers. If stale,
  re-verify per those headers before leaning on them.
