# AGENTS.md

## Project purpose

This repo (`HearthCore/.agents`) is a small, shared "bootstrap" repo for
Claude Code **cloud environments** (claude.ai/code) across HearthCore's
projects. It doesn't ship application code — it ships a setup script that
Cloud Environments run before Claude Code launches, so every environment
that opts in gets the same baseline: the Langfuse Observability plugin
declared and enabled, with `uv` available as its runtime.

Concretely, today that means one file matters: `setup-langfuse-cloud.sh`.
Everything else (`README.md`, `.env.example`, `.gitignore`) exists to
document and support that script.

## Layout

| Path | Purpose |
|---|---|
| `setup-langfuse-cloud.sh` | Idempotent Cloud Environment setup script. Declares/enables the Langfuse Observability plugin in `.claude/settings.json` and ensures `uv` is installed. |
| `README.md` | User-facing usage docs (curl-pipe-bash snippet, required env vars). |
| `.env.example` | Template for local testing of the setup script — copy to `.env`, never commit `.env`. |
| `.gitignore` | Keeps `.env*` (secrets) out of git. `.claude/settings.json` is intentionally tracked — it's secret-free, so committing it is how this repo distributes the Langfuse plugin declaration itself. |

## Secrets model — read this before touching anything Langfuse-related

This is the part most likely to regress if changed carelessly, so the
reasoning is spelled out:

1. **Real cloud sessions never need a secrets file at all.** Cloud
   Environment Variables (configured in the claude.ai environment UI, not
   in this repo) are injected straight into the VM's process environment.
   The Langfuse hook reads `LANGFUSE_PUBLIC_KEY` / `LANGFUSE_SECRET_KEY` /
   `LANGFUSE_BASE_URL` from there at runtime, and env vars take precedence
   over any plugin config. That's the primary, intended path.
2. **`.claude/settings.json` must never contain secrets.** It's tracked in
   git on purpose (see Layout above) — the script only ever writes the
   plugin *declaration* (marketplace + `enabledPlugins`) there, nothing
   that couldn't be public.
3. **The script never writes secrets to disk.** If `LANGFUSE_*` happens to
   be exported when the script runs (local/manual runs), the hook inherits
   them through the process environment anyway — a file round-trip would be
   dead weight and a second copy of the secret. `.env.example` exists only
   as a manual testing template, never as a script output target.
4. If you're tempted to "simplify" by writing keys into `settings.json`,
   `.env`, or any other file the script touches: don't. That's the exact
   regression this design avoids.

## Working conventions

- Bash: `set -euo pipefail`, idempotent (safe to re-run, diffs only what
  actually changed), and every write path should degrate gracefully rather
  than hard-fail when a directory/file isn't there yet.
- Keep `README.md` and this file in sync with the script's actual
  behavior — both describe the same secrets model from different angles
  (README = "how to use it", AGENTS.md = "why it's built this way").
- No test suite exists; validate changes by running the script locally
  (see README "Local testing") and inspecting the resulting
  `.claude/settings.json` / `.env` by hand.
