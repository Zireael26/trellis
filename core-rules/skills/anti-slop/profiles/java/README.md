# Java profile

Evidence-doctrine pattern set for Java projects: casts that assert a type without
proving it, annotations that claim safety without supplying it, boundaries that widen
to `Object` and narrow again. Doctrine lives in `core-rules/references/anti-slop.md`.

**Live, pattern-layer only.** Unlike Go and Rust — whose profiles ship dormant — this
one is live and counted: `SLOP_LANGS` includes `java`, and `audit-slop.sh` /
`check-slop.sh` route `.java` files through `slop_scan_text`. There is no native lane.

| File | Owns | Lane |
|---|---|---|
| rows in `core-rules/hooks/lib/slop-patterns.sh` (`java)` case) | every pattern | `slop-tripwire` (turn-time), `audit-slop.sh` (repo), `check-slop.sh` (diff) |
| `fixtures/{red,green}.java` | the profile's self-test | § Self-test |

## Why no native engine

The other live profiles delegate to a linter the project already runs (oxlint, ruff,
mypy) — a config file, no build change. Java has no equivalent:

- **Error Prone / NullAway** are javac plugins. Installing one edits the project's
  `pom.xml`/Gradle build and runs on **every compile**, for every contributor and every
  CI job. That is a categorically larger blast radius than a lint config, and it can
  fail a build for reasons the anti-slop tier never intended to own.
- **SpotBugs / PMD / Checkstyle** are separate plugin executions with their own
  lifecycle binding, and their rule vocabularies do not line up with this doctrine
  without heavy suppression — precisely the warning-fatigue failure the spec forbids.

So the pattern layer IS the Java lane, and the audit says so (`java: pattern layer (no
native lane)`) rather than the misleading "profile dormant". If a native lane is added
later, the honest first step is a project-local **test** (this doctrine's own repos
already enforce contract invariants that way) rather than a compiler plugin.

## Calibration

Every row was measured against a real 171-file Spring Boot 3 / Java 21 service (test
sources excluded by the carve-outs) BEFORE being included. A row that fires on
defensible code teaches readers to skim, which is worse than no row.

| Row | Hits | Kept | Note |
|---|---|---|---|
| `java-unchecked-cast` | **7** | yes | all 7 were the same latent defect: a request attribute cast to `Set<String>`, where only 4 of the 7 sites carried any annotation at all |
| `java-suppress-warnings` | **4** | yes | all 4 `("unchecked")`, all on the casts above |
| `java-object-param` | **7** | yes | widen-then-narrow helpers at JSON/CSV boundaries; the `SAFETY:` hatch is the intended resolution for the genuinely generic ones |
| `java-empty-catch` | 0 | yes | zero-noise guard |
| `java-print-stack-trace` | 0 | yes | zero-noise guard |
| `java-raw-collection` | 0 | yes | zero-noise guard |
| `java-reflection` | 0 | yes | zero-noise guard |
| `java-optional-get` | 0 | yes | zero-noise guard; see Known gaps |
| `java-mock-static` | 0 | yes | zero-noise guard; mocks in non-test code are the smell |

**Rejected candidates**, measured and left out:

| Candidate | Hits | Why rejected |
|---|---|---|
| `throws Exception` | 5 | a Spring `configure()` override, an HMAC helper, two worker internals — all defensible |
| generic cast `([A-Z]\w*)` (no type args) | **176** | matches every ordinary cast and most parenthesised expressions |
| `Object` anywhere in a signature line | **3247** | the ERE also matched every `) {` line; unusable |
| `instanceof` | 10 | Java 21 pattern matching (`instanceof X x`) makes it the idiomatic *fix*, not the smell |

## Known gaps

Line-oriented ERE, deliberately grep-approximate (doctrine §8). These are the shapes it
cannot see, recorded so a clean result is never over-read:

- **A `var`-held `Optional`.** `java-optional-get` needs the literal `Optional` on the
  line, so `var w = find(); w.get();` is invisible. Only `Optional…get()` on one line
  reports. This is why the red fixture uses `Optional.ofNullable(raw).get()`.
- **A nested generic cast.** `(Map<String, List<String>>) x` does not match: the row's
  `[^>()]*` cannot cross the inner `>`. Single-level casts — the common case, and all 7
  found in calibration — do match.
- **A multi-line empty catch.** `catch (E e) {\n}` spans two lines; only the one-line
  form reports.
- **`@Disabled` / `@Ignore` tests.** Test sources are carved out uniformly (grep cannot
  see `@Nested` scoping or a conditional-disable), so a skipped test is out of scope for
  this tier by construction, not by oversight.
- **A cast justified by an annotation several lines up.** The `SAFETY:` hatch must sit on
  the construct it justifies — same line, the line above, or the contiguous comment run
  directly above. A `@SuppressWarnings` on the enclosing *method* does not suppress a
  cast deeper in the body, and that is intentional: the annotation is the claim, the
  comment is the proof.

## Carve-outs

Java-specific additions to the shared glob list:

- `**/target/**` — Maven build output, including `target/generated-sources`. Gradle's
  `**/build/**` was already covered.
- `**/test/**` already covers Maven's `src/test/java/…` because a `case` glob's `*`
  crosses `/`. The self-test asserts this explicitly rather than leaving it to inference.

## Self-test

The pattern lib's own check covers Java — red sample hits every row, green sample stays
silent, plus four shape probes for ERE alternatives a whole-sample scan cannot
distinguish:

```sh
bash core-rules/hooks/lib/slop-patterns.sh --self-test
```

The fixtures are the same assertion at file scope:

```sh
. core-rules/hooks/lib/slop-patterns.sh
slop_scan_text java < profiles/java/fixtures/red.java   | cut -f2 | sort -u   # expect 9 ids
slop_scan_text java < profiles/java/fixtures/green.java                       # expect silence
```

**Do not write a row using `\b`.** awk's ERE is POSIX and has no word-boundary escape;
use `[^A-Za-z0-9_]` as every other language here does. Do not write an **empty
alternative** (`(|x)`) either: macOS awk rejects it with `illegal primary in regular
expression` and aborts the whole scan at that row, so every pattern after it silently
stops firing. Both failures are silent-no-match, which is exactly what the self-test
exists to catch — it caught the second one during this profile's authoring.
