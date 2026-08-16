# AGENTS.md

## Project purpose

This repo (`HearthCore/.agents`) is a small, shared "bootstrap" repo for
Claude Code **cloud environments** (claude.ai/code) across HearthCore's
projects. It doesn't ship application code — it ships a setup script that
Cloud Environments run before Claude Code launches, so every environment
that opts in gets the same baseline: the Langfuse Observability plugin and
the OpenViking Memory plugin declared and enabled, with `uv` available as
Langfuse's runtime.

Concretely, today that means one file matters: `setup-langfuse-cloud.sh`
(name kept for backwards compat with existing Cloud Environment setup-script
URLs — it now provisions both plugins, not just Langfuse). Everything else
(`README.md`, `.env.example`, `.gitignore`, `CLAUDE.md`) exists to document
and support that script.

## Layout

| Path | Purpose |
|---|---|
| `setup-langfuse-cloud.sh` | Idempotent Cloud Environment setup script. Declares/enables both the Langfuse Observability and OpenViking Memory plugins in `.claude/settings.json`, ensures `uv` is installed, and best-effort installs both plugins. |
| `README.md` | User-facing usage docs (curl-pipe-bash snippet, required env vars). |
| `CLAUDE.md` | Just `@AGENTS.md` — Claude Code reads `CLAUDE.md` by convention; this repo's real instructions live in `AGENTS.md`, so `CLAUDE.md` is a one-line pointer to avoid maintaining two copies. |
| `.env.example` | Template for local testing of the setup script — copy to `.env`, never commit `.env`. |
| `.gitignore` | Keeps `.env*` (secrets) out of git. `.claude/settings.json` is intentionally tracked — it's secret-free, so committing it is how this repo distributes both plugin declarations. |

## Secrets model — read this before touching anything Langfuse/OpenViking-related

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

### OpenViking Memory: same rules, one extra trap

OpenViking's hook (`auto-capture.mjs` / `auto-recall.mjs`) reads config in
this priority order: **env vars > `ovcli.conf` > `ov.conf` > local
defaults**. That means the exact same env-var-only pattern as Langfuse
applies, with three vars:

- `OPENVIKING_URL` — e.g. `https://viking.goetzken.dev`
- `OPENVIKING_API_KEY`
- `OPENVIKING_MEMORY_ENABLED=1` — without this, the plugin has been observed
  staying inert even when installed+enabled and the other two vars are set
  correctly (auto-detection is conservative). Set it explicitly, don't rely
  on "auto".

**The trap:** OpenViking's own docs describe `ovcli.conf` (containing
`url` + `api_key` in plaintext JSON) as the config file, conventionally
placed at `~/.openviking/ovcli.conf`. It is tempting to "just commit a
working config" into this repo the same way `.claude/settings.json` is
committed — **do not**. `ovcli.conf` is a credential file (holds the API
key itself, not a reference to one), OpenViking's own docs say it "should
be gitignored and never committed to version control", and unlike
`settings.json` there is no secret-free subset of it worth tracking. If you
need a local copy for manual testing, write it to `~/.openviking/ovcli.conf`
directly — never under this repo's working tree, gitignored or not (git add
-A / a misconfigured hook is one command away from committing it anyway).

## Known issue — OpenViking commit threshold not confirmed firing (open)

Observed in a live cloud session (2026-08-16, plugin installed + enabled,
`OPENVIKING_MEMORY_ENABLED=1` set, auth confirmed working):

- **Recall** works: fires on every user prompt, reaches the server
  (~2.2s latency), returns `count: 0, reason: "no_results"` on an empty
  profile — expected for a fresh session.
- **Capture** works at the push level: `~/.openviking/state/last-capture.json`
  showed `turns_captured: 8, turns_queued: 0, turns_failed: 0` — pushes to
  the server succeed.
- **Not yet confirmed:** whether a commit ever actually fires. `auto-capture.mjs`
  polls the server's session meta after each push and only calls
  `commitSession` once `pending_tokens >= 20000` (default
  `OPENVIKING_COMMIT_THRESHOLD` — check the actual env var name in the
  plugin source before changing it). The server was reporting
  `pending_tokens: 0` and `total_message_count: 0` back despite 8 accepted
  turns. Two readings, not yet distinguished:
  1. Expected — a fresh session hasn't hit 20k tokens yet, meta just
     hasn't caught up. Resolves itself.
  2. A real bug — `getSession` returns null/errors and
     `Number(meta?.pending_tokens || 0)` silently coalesces that to 0, so
     the threshold never crosses and nothing ever commits/extracts, and
     recall stays `no_results` forever even after real usage.
- `~/.openviking/last_inject.md` was never written this session (consistent
  with an empty profile, not itself evidence of a bug).
- **Next diagnostic step (not yet run at time of writing):** set
  `OPENVIKING_DEBUG=1` and watch a few turns — `auto-capture.mjs:722`
  (line number as of the version installed then; re-check on a fresh
  install) logs the raw `pending_tokens` it reads each turn, which tells
  you directly whether the server value is genuinely 0 or the fetch is
  failing and being swallowed.

If you pick this up: check `~/.openviking/logs/` (only exists once
`OPENVIKING_DEBUG=1` has run), `~/.openviking/state/last-capture.json`, and
`~/.openviking/state/last-recall.json` for current state before
re-deriving from scratch.

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
