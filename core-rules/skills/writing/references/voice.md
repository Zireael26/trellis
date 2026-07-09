# Reference — the voice-file convention

Every `/writing` run speaks in a voice, and the voice is not yours to invent.
It lives in a per-project **voice file** you load at stage 1 (`SKILL.md`) and
self-review against. This doc is the convention that file follows: where it
lives, what it contains, how it is seeded, and what you do when it is missing.

## Location — `docs/voice.md` in the target content repo

The voice file lives at `docs/voice.md` in the **repo whose surface you are
writing for** — akaushik.org for the operator's personal posts, a fleet
project's own repo for its brand voice.

**Never under trellis `core-rules/`.** The public-mirror sync publishes
`core-rules/skills/` wholesale; a voice file anywhere inside it would ship on
the next sync. Keeping voice files in target repos means the mirror
**structurally cannot** leak them — no exclusion list to maintain, nothing to
forget (spec 010 SC4). Public-template users get this convention and bring
their own file.

## Why per-project

A personal site and a product do not speak the same voice: first-person
receipts-and-scars prose is right for the operator's blog and wrong for a
curat- or neev-class changelog, and the reverse holds too. One central voice
file would be wrong for both, so there is none — only the target repo's own.

## Schema — the sections a voice.md must have

1. **Identity + audience** — who is speaking, to whom.
2. **Register** — formality band, humor posture, first/second person.
3. **Sentence rhythm** — length variance, fragment tolerance, paragraph shape.
4. **Vocabulary** — words and phrases the author actually uses, and a
   never-list of words they don't. The never-list is author-specific; it
   complements the universal slop vocab in `references/ai-tells.md`, it does
   not restate it.
5. **Structural habits** — the recurring moves: receipts-over-claims, "What I
   got wrong" sections, dated captures, how sections open and close.
6. **Exemplars** — 2–3 SHORT verbatim excerpts from published pieces, quoted,
   each with its source. Excerpts, not summaries: quoted rhythm is matchable,
   described rhythm is not.

## Seeding

- Derive from **at least 3 published pieces** on the target surface — fewer
  and you are extrapolating a voice from noise.
- **Quote, don't paraphrase**, for the exemplars. A paraphrased exemplar is
  the seeder's voice, not the author's.
- Thin or missing corpus → **interview the operator** (register, audience,
  never-words, writing they admire) instead of inventing a voice. An invented
  voice defeats the file's purpose.

## Degrade path — file absent (mirrors `SKILL.md` stage 1)

Absence never blocks a run. When `docs/voice.md` is missing from the target
repo:

1. Derive a **working voice from the published corpus** for this run only.
2. **Tell the operator** the run used a derived voice.
3. **Propose seeding** the file per the procedure above, so the next run
   loads it instead of re-deriving.

No corpus *and* no interview is the one hard stop: never silently invent a
voice from nothing — surface it and ask.

## Maintenance

- **Re-seed after voice-shifting events** — a new content domain, a rebrand,
  a deliberate register change. The file describes the voice as published and
  goes stale the same way.
- **The file is the author's property.** You may propose edits — a drift you
  noticed, a new exemplar worth adding — but the operator owns every change.
  Never rewrite it as a side effect of a writing run.
