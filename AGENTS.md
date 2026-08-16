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

## Resolved — OpenViking hooks silently wrote nothing (Node ignores HTTPS_PROXY)

Root-caused in a live cloud session (2026-08-16, plugin 0.4.4, server
v0.4.13). The earlier "commit threshold not confirmed firing" symptom was
real, but the threshold was never the problem: **no HTTP request the hooks
made ever reached the OpenViking API.** Capture and recall both looked
healthy and both silently did nothing.

### The chain

1. `viking.goetzken.dev` sits behind a **Pangolin auth proxy**. A request
   that does not go through the cloud environment's egress proxy gets a
   `302` to `pangolin.goetzken.dev/auth/resource/...`.
2. **Node's `fetch` (undici) does not honour `HTTPS_PROXY`/`https_proxy`.**
   `curl` does. So every hook request bypassed the egress proxy, followed
   the 302, and landed on the web UI — `HTTP 200`, `content-type: text/html`.
3. `fetchJSON` (`scripts/lib/ov-session.mjs`) does
   `const body = await res.json().catch(() => ({}))`. The HTML parse failure
   is swallowed into `{}`, and the success test is only
   `if (!res.ok || body.status === "error")`. A 200 + HTML therefore returns
   **`{ ok: true, result: {} }`** — indistinguishable from success.
4. From there everything degrades quietly:
   - `sendSessionMessages` (`scripts/shared/batch-send.mjs`) does
     `result.sent += chunk.length` on `res.ok` without ever checking the
     server's own `result.added`. So `last-capture.json` reported
     `turns_captured: 130` while the server held **zero** messages.
   - `getSession` returns `{}`, so
     `Number(meta?.pending_tokens || 0)` → `0` — the exact silent coalesce
     hypothesis 2 predicted, just triggered by an HTML 200 rather than a
     network error. The threshold never crosses, nothing ever commits.
   - `/health` also returned HTML 200, so `health.ok` was true and the
     retryable/pending-queue path never engaged either.
   - Recall hits `/api/v1/search/recall` the same way and gets `{}` →
     `count: 0, reason: "no_results"` forever, on any query.

Confirmation that the pushes really were lost: `GET /api/v1/sessions/{id}`
returned `404 NOT_FOUND` for a session the hook had just reported
`push_turns ok:49` on.

### The fix

Set **`NODE_USE_ENV_PROXY=1`** in the Cloud Environment Variables (same
place as the other vars — see the secrets model above). It makes undici
honour the proxy env vars via `EnvHttpProxyAgent`. Verified working on the
Node 22.22 image here; it prints an experimental-API warning to stderr,
which is harmless. `NODE_OPTIONS=--use-env-proxy` is the Node 24+
equivalent if the image ever moves up.

End-to-end verification after setting it — same transcript, same hook:

```
captured 130 turns to ov session cc-… (committed)
last-capture.json: total_message_count 130, pending_tokens 28848,
                   commit_threshold 20000, committed true, commit_count 1
server meta:       message_count 10 (keep_recent_count), commit_count 1
```

So the commit threshold fires correctly once requests actually arrive. The
20000-token default is reachable in a single working session (~130 turns).

### Two upstream bugs worth reporting to OpenViking

Both are real regardless of the proxy issue — they are what turned a
connectivity problem into a silent one:

1. `fetchJSON` treats a non-JSON `200` as success. It should verify
   `content-type` is JSON (or that the body actually parsed) before
   returning `ok: true`.
2. `sendSessionMessages` trusts `chunk.length` instead of the server's
   `result.added`, so it over-reports accepted messages.

A third, milder one: `commitSession` reports `ok: true` for a server
response of `{"status":"skipped","archived":false,
"reason":"all_within_keep_window"}` — `commitRes.ok` only reflects the HTTP
envelope, not the inner `result.status`, so `committed: true` can be logged
for a commit that archived nothing.

### Debugging notes for next time

- `~/.openviking/logs/cc-hooks.log` only exists once `OPENVIKING_DEBUG=1`
  has run. Also check `~/.openviking/state/last-capture.json` and
  `last-recall.json` before re-deriving anything.
- The hooks **detach**: `maybeDetach` (`scripts/shared/async-writer.mjs`)
  spawns `node <script>` with `OV_HOOK_WORKER=1` and the parent approves
  immediately. Instrumenting the parent (a `--import` fetch tap, an
  `OPENVIKING_URL` pointed at a local proxy) sees nothing, because the flag
  is not passed to the child. Set `OV_HOOK_WORKER=1` yourself to force the
  whole thing synchronous in a process you control.
- To force a re-capture, reset the cursor in
  `/tmp/openviking-cc-capture-state/<cc-session-id>.json` to
  `{"capturedTurnCount":0}` and pipe a `Stop` hook payload into
  `auto-capture.mjs`.
- Trust the server, not the hook logs: `GET /api/v1/sessions/{id}` via
  `curl` is the only statement about what actually landed.

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
