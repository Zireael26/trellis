# Unity profile — project-local validators

The canonical Unity profile in `rulesets/unity-game/` ships starter Semgrep rules for the most common attack classes (plaintext PlayerPrefs credentials, unsigned save files, BinaryFormatter deserialization, TLS bypass, hardcoded API keys, in-client IAP validation). These rules cover **patterns**. The Unity baseline also needs **artifact-level integrity checks** that aren't pattern-matchable from source.

This doc lists the validators every Unity-profile project should ship in its `security-gate-local/` directory beside the canonical symlink. The skill loads them at scan time. The list mirrors `process-gate`'s stack-validator convention.

## Required validators (per `security-gate-plan.md` §5)

### 1. Asset hash integrity (`check-asset-hashes.sh`)

Verify that shipped asset bundles have stable SHA-256 manifests and that no orphan or tampered bundles exist on disk.

- Read `<project>/LumeApp/Assets/StreamingAssets/manifest.json` (or wherever the build pipeline writes it).
- For every asset bundle path under `Library/com.unity.addressables/aa/` (or your equivalent), recompute SHA-256 and compare against the manifest entry.
- Mismatch → high-severity finding: `Asset bundle <path> hash mismatch — manifest says X, on-disk says Y. Possible asset substitution.`
- Bundle on disk but missing from manifest → medium-severity: `Orphan bundle <path> not declared in manifest. Either build artefact or planted asset.`

### 2. Save-file signature verification (`check-save-signature.sh`)

If the project writes typed save data via JsonUtility/MessagePack/Protobuf, verify each save record carries an HMAC and that the HMAC was computed with a per-install key (Keychain/Keystore-backed). The Semgrep rule `unity-game.json-save-no-signature` flags the *write* path; this validator confirms the *load* path enforces verification before deserialization.

- Static-grep the codebase for save-load entry points (e.g. `LoadSaveAsync`, `DeserializeSave`).
- Confirm each entry point calls a verification helper (e.g. `HMAC.Verify`, `ComputeMac`) before passing the buffer to the deserializer.
- Missing verification → high-severity: `Save load path <method> deserializes without HMAC check.`

### 3. IL2CPP integrity check (`check-il2cpp-tamper.sh`)

When the project builds with IL2CPP for player platforms (iOS, Android, console), the resulting native binary is the actual attack surface. Compute a SHA-256 of the player binary at build time and stash it; the runtime can then optionally compare against the bundled hash to detect post-shipping tampering (re-signing for piracy or save-injection mods).

- At build, hash `<build-output>/Build/<Platform>/<player-binary>` (e.g. `il2cpp.so` on Android; `<App>.app/<App>` on iOS) and write to `<project>/security-gate-local/il2cpp-hashes.json`.
- The validator only audits the build pipeline records the hash. The runtime check itself is application code.
- Missing recorded hash for the latest build → medium-severity: `IL2CPP hash not recorded for build <version>. Tamper detection inactive.`

### 4. IAP receipt validator wiring (`check-iap-server-validation.sh`)

The Semgrep rule `unity-game.iap-receipt-not-server-validated` catches in-client `Complete` calls without a verification step. This validator goes one level further and confirms that:

- A backend endpoint exists that accepts the receipt payload (e.g. a Firebase Cloud Function under `<project>/functions/src/iap/verify.ts`).
- The endpoint calls Apple `verifyReceipt` (or App Store Server API) for iOS receipts and Google `androidpublisher.purchases.subscriptions.get` for Android receipts.
- The endpoint writes an entitlement record only after the platform API returns a `success` status.

- Missing endpoint → high-severity: `No IAP server-validation endpoint found under functions/. Receipts trust the client.`
- Endpoint exists but bypasses platform API call → high-severity: `IAP endpoint <path> writes entitlement without calling Apple/Google verification.`

### 5. Firebase / cloud rules (`check-firestore-rules.sh`) — when applicable

For projects using Firebase, statically analyze `firestore.rules` and `storage.rules` for permissive write paths. Specifically flag:

- `allow read, write: if true;` — any path with this pattern.
- Paths under `/users/{uid}/` that don't gate on `request.auth.uid == uid`.
- Storage paths under user-controlled subtrees with no size limit.

- Each violation → severity per pattern (write-true → critical; missing auth-uid match → high; missing size limit → medium).

## Wiring

Each validator script is referenced from the project's `security-gate-local/local.config.sh`:

```bash
SECURITY_GATE_STACK_PROFILE="unity-game"
SECURITY_GATE_STACK_VALIDATORS=(
  "scripts/check-asset-hashes.sh"
  "scripts/check-save-signature.sh"
  "scripts/check-il2cpp-tamper.sh"
  "scripts/check-iap-server-validation.sh"
  "scripts/check-firestore-rules.sh"   # optional, only when Firebase rules exist
)
```

The canonical baseline runner (`scripts/run-baseline.sh`) does NOT yet auto-load `SECURITY_GATE_STACK_VALIDATORS` — that's deferred to a follow-up phase to keep the canonical engine OSS-only. Until then, the project runs its validators as a wrapping shell script:

```bash
bash <project>/security-gate-local/scripts/check-asset-hashes.sh
bash <project>/security-gate-local/scripts/check-save-signature.sh
# … etc
bash <skill>/scripts/run-baseline.sh <project> --profile=unity-game
```

The validator output is appended to the per-project audit narrative manually until the auto-load wiring lands.

## Status (Phase 5)

Phase 5 ships the **rulesets** and this **specification** for project-local validators. The actual `check-*.sh` scripts are project-specific (bundle layout, save-file format, IAP plugin choice all vary per project) and live under `<project>/security-gate-local/scripts/`. Lume's validators land separately when the project author writes them — the spec in this doc is the contract.
