# gotchas-operational — situational hazards, with the observation count

Fleet-observed gotchas that fire only in a specific situation, kept out of the
per-session rules so they cost nothing on the turns they do not apply to. Each
one below was paid for by a real incident; the observation count is part of the
rule. `core-rules/CLAUDE.md` carries the trigger and points here. Read the
matching entry when you are in that situation.

## Working inside a git worktree

A git worktree is a **tracked-content-only checkout, not a clone**: gitignored
files, inheritance symlinks, `node_modules`, and build caches are absent or
root-scoped, and they silently break skills, lint, and typecheck.

- Confirm which checkout you are in (`git rev-parse --show-toplevel`) before any
  path-sensitive operation.
- Never run `git clean -fd`, `git checkout .`, or `git commit --amend` against
  shared or canonical state without attributing every untracked or staged
  entry — files you do not recognize are almost certainly another worktree's
  in-progress work.

*(observed across 4 projects)*

## Cloud provisioning: region, zone, and quota

Before committing to a region, zone, or machine family, verify the **specific**
capability you need is available there: model serving, machine-type and disk
support, and the per-region quota bucket.

Global signals (`effectiveLimit=-1`) and other regions lie about the target
region. `asia-south1` in particular is on limited rollouts.

*(observed across 3 GCP projects)*

## Container runtime

On macOS, use **Colima as the only container runtime**; do not start Docker
Desktop. Install the Docker CLI, buildx, compose, and the credential helper
through Homebrew. Configure `~/.docker/config.json` with
`credsStore: osxkeychain`, `cliPluginsExtraDirs: [/opt/homebrew/lib/docker/cli-plugins]`,
and `currentContext: colima`. An installed but dormant Docker Desktop is not a
runtime problem; starting it can silently flip the global context to
`desktop-linux`.

Export `DOCKER_HOST=unix://$HOME/.colima/default/docker.sock` in the login
shell environment. Trellis forwards it to project hooks but deliberately does
not forward `DOCKER_CONTEXT`. GUI and IDE git clients may not inherit the
login-shell export; configure their environment separately or use the optional
socket bridge. For tools that hardcode `/var/run/docker.sock`, an operator may
install a root LaunchDaemon that recreates a symlink from that path to
`~/.colima/default/docker.sock` at boot. This is optional and is not installed
by Trellis.

*(observed after a Colima migration and a Docker Desktop context flip)*

## Shared credentials

Fires before a deploy, and only then — which is why it lives here rather than in
the always-injected constitution.

- A token shared by several projects (one deploy token for a hosting team account serving several sites) has ONE canonical source: exported from your shell profile (`~/.zshenv` or equivalent), Keychain-backed where the platform supports it. Never duplicate it into per-project `.env.local` — copies go stale independently and the freshest one becomes unfindable.
- Per-project `.env.local` is only for credentials scoped to that one project or account.
- Before any deploy, verify the token works (the provider CLI's `whoami` equivalent, against that token). If it is invalid the canonical source is stale — tell the operator to refresh it (macOS Keychain: `security add-generic-password -U -a "$USER" -s <service> -w <token>`); never silently fall back to a token found in some project's env file.
- Stale copies of a now-centralized token in `.env.local` files are cleanup candidates — flag them, don't use them.

*(one canonical source per shared token; observed after copies in three project `.env.local` files diverged)*
