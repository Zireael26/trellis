---
name: one-skill
description: Apply the verified deploy-order recovery procedure captured by the motivating wiki pattern. Use when a managed hook path must be restored and its health check verified.
---

# one-skill

This candidate packages the verified recovery route for a managed hook path.

## When to use

Use when the project has an existing Trellis attachment and the managed hook
dispatcher needs to be restored after a deployment-order failure.

## Procedure

1. Inspect the recorded hook path and confirm the Trellis attachment and Husky preparation are present.
2. Restore the managed dispatcher using the repository's tracked configuration.
3. Rerun the doctor check and confirm that the dispatcher is current.
4. Run the doctor check once more and verify that no hook-authority drift is reported.

The candidate remains non-authoritative until its proposal passes the required
checks and a human merges the proposal PR.
