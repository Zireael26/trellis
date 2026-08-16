# AEO citability review

Review only the supplied rendered page content. Return JSON with a top-level `findings` list. Every finding must contain:

- `aspect`: one of `answer-first`, `statistics`, `quotations`, `external-authority-citations`;
- `state`: a short observed state;
- `rationale`: a concise explanation grounded in the supplied content.

Do not score the page. Do not produce a blended SEO/AEO result. Do not claim a deterministic evidence grade, fingerprint, or raw-evidence identity. Do not suggest source edits. Do not use outside facts or call tools. An empty findings list is valid.
