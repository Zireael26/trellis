# Project registry

Projects under the Trellis process regime. Opt-in list. A project is "active" for process purposes if and only if it appears here and is **not** listed in `blacklist.md`.

This registry is also the input for any private operator audits you configure; no audit schedule ships in the public template.

> **Template note:** this file ships empty. As you onboard projects (see [`engineering-process.md` §10](engineering-process.md#10-onboarding-a-new-project-full-playbook)), append rows below.

---

## Active projects

| Project | Path | Class | Notes |
|---|---|---|---|
| _(none yet)_ | | | |

<!--
Example rows — uncomment and edit when you onboard projects:

| my-app           | `__PROJECTS_ROOT__/my-app`           | monorepo SaaS       | Onboarded YYYY-MM-DD. |
| my-marketing-site| `__PROJECTS_ROOT__/my-marketing-site`| single Next.js app  | Onboarded YYYY-MM-DD. |
| my-game          | `__PROJECTS_ROOT__/my-game`          | game (Unity, 3D)    | Onboarded YYYY-MM-DD. Native git hooks via `.githooks/` — see `core-rules/inheritance.md`. |
-->

---

## Not in the registry (intentionally)

Everything else under your personal projects root is outside this regime. Reasons vary — archived, experiment, client-owned, or just too small to benefit from the hook stack. If one of them becomes active enough to matter, add a row here.

---

## How to add a project

Full playbook: [`engineering-process.md` §10](engineering-process.md#10-onboarding-a-new-project-full-playbook). That is the single source of truth for onboarding steps — keep them there, not here. Registry-local steps only:

1. Add a row to the "Active projects" table above with `Path` and `Class`.
2. Commit in `trellis-instance/` with `chore: register <name>`.
3. If private operator audits are configured, the project becomes eligible under that operator's own cadence.

## How to remove a project

Move it to `blacklist.md` with a reason. Operator checks should skip it. Don't delete the row — we want the history of "this project was active once."
