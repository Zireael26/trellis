# Gotchas

Lessons logged as they happen. Each entry records the failure, its cause, and the verified repair without copying any secret values.

---

## managed-dispatcher-drift

**Recorded occurrence — 2026-08-20.** After the project was attached, the install preparation step rewrote `core.hooksPath` and the next doctor check reported hook-authority drift. The managed dispatcher files were still present.

**Verified repair.** Inspect the recorded hook path, restore the managed dispatcher at the configured path, run doctor, and run doctor once more to verify that the drift does not return.

---

## managed-dispatcher-repair

**Recorded occurrence — 2026-08-26.** A second attachment reproduced the same hook-authority drift after installation. The recovery path was repeated from the project root with the managed dispatcher path as an explicit input.

**Verified repair.** Doctor reported the managed dispatcher as current, and a separate follow-up doctor check reported no hook-authority drift.
