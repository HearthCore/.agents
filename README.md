# .agents

Shared agent setup scripts for HearthCore's Claude Code cloud environments
(claude.ai/code). Right now this holds a single script that wires up two
plugins for every Cloud Environment that runs it as its setup script — so
Claude Code sessions across HearthCore's repos get consistent tracing and
memory without each repo having to reinvent the plumbing:

- **[Langfuse](https://langfuse.com)** — LLM observability/tracing.
- **[OpenViking](https://docs.openviking.ai)** — cross-session agent memory.

## setup-langfuse-cloud.sh

Idempotently prepares both plugin declarations in the target repository's
`.claude/settings.json` — designed to run from the **Cloud Environment
setup script**, which executes BEFORE Claude Code launches. (Name kept for
backwards compat with existing Cloud Environment setup-script URLs; it
provisions both plugins, not just Langfuse.)

### Cloud Environment setup script

```bash
curl -fsSL https://raw.githubusercontent.com/HearthCore/.agents/main/setup-langfuse-cloud.sh | bash
```

If you're still installing plugins via explicit `claude plugin marketplace
add` / `claude plugin install` commands in your own pre-start block: that's
redundant with what this script does, and less reliable on its own — see
"Why not just `claude plugin install` in the pre-start block?" below.

### Required environment variables (set as Environment Variables in the Cloud Environment)

| Variable | Example | Plugin |
|---|---|---|
| `LANGFUSE_PUBLIC_KEY` | `pk-lf-...` | Langfuse |
| `LANGFUSE_SECRET_KEY` | `sk-lf-...` | Langfuse |
| `LANGFUSE_BASE_URL` | `https://fuse.goetzken.dev` | Langfuse |
| `OPENVIKING_URL` | `https://viking.goetzken.dev` | OpenViking |
| `OPENVIKING_API_KEY` | `ZGVmYXVsdA...` | OpenViking |
| `OPENVIKING_MEMORY_ENABLED` | `1` | OpenViking |

Set these under the Cloud Environment's own "Environment Variables" — not in
this repo, not in `.env` committed anywhere, and (for OpenViking) not in
`ovcli.conf` either. That's the only place secrets should be configured for
real cloud sessions.

> `OPENVIKING_MEMORY_ENABLED=1` matters even though it's not a secret: the
> plugin has been observed staying inert without it, even with a correct
> URL/key and the plugin installed+enabled. Set it explicitly.

### How keys reach the plugins

**Primary path (real cloud sessions):** Cloud Environment Variables are
copied straight into the VM's process environment. Both hooks read their
respective env vars at runtime — env vars take precedence over any file-based
config in both plugins — so **no file on disk needs to carry a secret** for
this to work.

> Note: the setup script itself runs BEFORE the Cloud Environment variables
> are exported, so it normally can't see them at the time it runs — that is
> expected and fine; the hooks still see them later, once Claude Code
> itself launches as a subprocess of the fully-configured environment.

**No fallback file needed:** if you run this script somewhere the relevant
vars already happen to be exported (local testing), the hooks inherit them
through the process environment anyway — a file round-trip would just
create a second copy of the secret. The script therefore never writes
secrets to any file, and `.claude/settings.json` stays 100% secret-free, so
it's safe to commit and track it project-wide — that's exactly what this
repo does. `.env.example` is a manual testing template only (copy to `.env`,
source it, run the script by hand).

### Why not just `claude plugin install` in the pre-start block?

We tried exactly that for OpenViking. It's not reliable on its own: `claude
plugin install` (and `claude plugin marketplace add`) run in a pre-start
command block write to **user-level** settings
(`$HOME/.claude/settings.json`), but cloud sessions only honour **repository
+ server-managed** settings (user-level settings stay on the machine, per
Anthropic docs). We hit this exact failure mode with Langfuse first
(declaring/installing without also writing the repo-tracked
`.claude/settings.json` left cloud sessions with 0 traces — verified via
`claude plugin list` = empty, `~/.claude/plugins` missing). This script's
whole reason to exist is closing that gap by writing the declaration into
the **repo's tracked** `.claude/settings.json`, which cloud sessions do
read reliably.

If you already run `claude plugin marketplace add` / `claude plugin
install` in your own pre-start commands: harmless to keep (best-effort,
idempotent), but don't rely on it alone — run this script too, or drop your
manual commands in favor of it.

### Behavior

- Creates `.claude/settings.json` if missing or invalid
- Merges both plugin declarations (marketplace + `enabledPlugins`) without
  touching existing settings (hooks, env, other plugins)
- Never writes secrets into any file — `.claude/settings.json` included;
  secret delivery is entirely the Cloud Environment's process env
- Skips work that's already correct (idempotent, safe to re-run)
- Ensures `uv` is available (Langfuse's preferred runtime)
- Best-effort installs both plugins (not just declares them) if the `claude`
  CLI is on `PATH`

### Local testing

```bash
cp .env.example .env   # fill in real values, .env is gitignored
set -a && source .env && set +a
./setup-langfuse-cloud.sh
```

### OpenViking troubleshooting

If recall keeps returning `no_results` well past a fresh session, or memory
never seems to persist across sessions, see the "Known issue — OpenViking
commit threshold not confirmed firing" section in `AGENTS.md` for the
current state of investigation and the next diagnostic step
(`OPENVIKING_DEBUG=1`).
