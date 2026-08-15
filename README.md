# .agents

Shared agent setup scripts for HearthCore's Claude Code cloud environments
(claude.ai/code). Right now this holds a single script that wires up
[Langfuse](https://langfuse.com) LLM observability for every Cloud
Environment that runs it as its setup script — so Claude Code sessions
across HearthCore's repos get consistent tracing without each repo having
to reinvent the plumbing.

## setup-langfuse-cloud.sh

Idempotently prepares the Langfuse Observability plugin declaration in the
target repository's `.claude/settings.json` — designed to run from the
**Cloud Environment setup script**, which executes BEFORE Claude Code
launches.

### Cloud Environment setup script

```bash
curl -fsSL https://raw.githubusercontent.com/HearthCore/.agents/main/setup-langfuse-cloud.sh | bash
```

### Required environment variables (set as Environment Variables in the Cloud Environment)

| Variable | Example |
|---|---|
| `LANGFUSE_PUBLIC_KEY` | `pk-lf-...` |
| `LANGFUSE_SECRET_KEY` | `sk-lf-...` |
| `LANGFUSE_BASE_URL` | `https://fuse.goetzken.dev` |

Set these under the Cloud Environment's own "Environment Variables" — not in
this repo, not in `.env` committed anywhere. That's the only place secrets
should be configured for real cloud sessions.

### How keys reach the plugin

**Primary path (real cloud sessions):** Cloud Environment Variables are
copied straight into the VM's process environment. The Langfuse hook reads
`LANGFUSE_PUBLIC_KEY` / `LANGFUSE_SECRET_KEY` / `LANGFUSE_BASE_URL` from
there at runtime — env vars take precedence over plugin config in the
plugin source — so **no file on disk needs to carry a secret** for this to
work.

> Note: the setup script itself runs BEFORE the Cloud Environment variables
> are exported, so it normally can't see them at the time it runs — that is
> expected and fine; the hook still sees them later, once Claude Code
> itself launches as a subprocess of the fully-configured environment.

**No fallback file needed:** if you run this script somewhere the
`LANGFUSE_*` vars already happen to be exported (local testing), the hook
inherits them through the process environment anyway — a file round-trip
would just create a second copy of the secret. The script therefore never
writes secrets to any file, and `.claude/settings.json` stays 100%
secret-free, so it's safe to commit and track it project-wide — that's
exactly what this repo does. `.env.example` is a manual testing template
only (copy to `.env`, source it, run the script by hand).

### Behavior

- Creates `.claude/settings.json` if missing or invalid
- Merges the Langfuse plugin declaration (marketplace + `enabledPlugins`)
  without touching existing settings (hooks, env, other plugins)
- Never writes secrets into any file — `.claude/settings.json` included;
  secret delivery is entirely the Cloud Environment's process env
- Skips work that's already correct (idempotent, safe to re-run)
- Ensures `uv` is available (the plugin's preferred runtime)

### Local testing

```bash
cp .env.example .env   # fill in real values, .env is gitignored
set -a && source .env && set +a
./setup-langfuse-cloud.sh
```
