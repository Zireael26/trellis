# Pi compaction integrity patches

These bounded patches fix the three native-compaction defects:

- preserve an existing summary when a first retained turn is split;
- reject aborted or empty summaries;
- retain both the beginning and ending of long tool results.

They do not change model selection, context limits, compaction thresholds, remote compaction, or `pi-codex-compact` routing.

## Exact version and bundle boundary

`apply-pi-compaction-patches.sh` reads the package's own identity before selecting an exact patch and bundle:

| Package identity | SDK patch | Bundle chunk |
| --- | --- | --- |
| `@earendil-works/pi-coding-agent@0.85.0` | `pi-coding-agent-0.85.0-compaction-integrity.patch` | `chunk-WZB2R5YO.js` |
| `@earendil-works/pi-coding-agent@0.85.1` | `pi-coding-agent-0.85.1-compaction-integrity.patch` | `chunk-JVUZSMYM.js` |

Unknown identities, missing exact files, ambiguous replacement patterns, and mixed SDK/bundle states are refused before writes. Repeated invocation on a fully patched copy is a no-op. A mutation-time failure reports that the package may be partially patched; it is not silently rolled back.

The original 0.85.0 patch bytes remain unchanged. Copied-fixture qualification modified no installed package, profile, live session, or provider.

## 0.85.1 qualification boundary

A disposable copy of the installed 0.85.1 package was red before repair and green after repair using the actual SDK modules and the exact bundled APIs. The stream was synthetic and made no provider call. Installer apply, idempotence, unknown-version, missing-file, ambiguous-pattern, partial-state, and mutation-time-failure checks also passed.

That qualification is copied-fixture evidence, not native-provider behavior. Subsequent local application was backed up and passed the same synthetic SDK/bundle checks against the installed 0.85.1 files, with only the three patch targets changed. Existing processes were not restarted; their already-loaded code is unchanged. The original 0.85.0 fixture is unavailable under `patches/upstream`; old-version tests were not executed. Historical 0.85.0 evidence does not transfer to 0.85.1.

Receipts and raw commands are retained at:

`specs/045-three-harness-parity/receipts/pi-0851-compaction-qualification/`

## Manual installer qualification

`tests/pi-compaction-installer.mjs` is an explicit version-qualification probe, not an automatically discovered project test. Supply a **pristine, unpatched 0.85.1 package fixture**; it copies the listed inputs into disposable directories and never changes the fixture. No operator-specific installation is searched. A missing fixture is an error, not a skipped or passing test.

```bash
PI_CODING_AGENT_PACKAGE_ROOT="$PRISTINE_PI_0851_FIXTURE" \
  node "$TRELLIS_REPO_ROOT/core-rules/pi/patches/tests/pi-compaction-installer.mjs"
```

Provision and qualify that fixture separately before applying a patch. The semantic probe below also requires an explicit package root. Neither probe is a claim that the ordinary project gate provisions Pi or validates every installed version.

## Applying a supported copy

```bash
bash "$TRELLIS_REPO_ROOT/core-rules/pi/patches/apply-pi-compaction-patches.sh" "$PI_PACKAGE_ROOT"
node "$TRELLIS_REPO_ROOT/core-rules/pi/patches/tests/pi-compaction-integrity.mjs" "$PI_PACKAGE_ROOT"
```

Apply only to a matching package copy, then restart Pi at an attended boundary. Existing processes retain loaded code. Reapply after an upgrade only after requalifying that exact version.
