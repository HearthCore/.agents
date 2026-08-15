# .agents

Shared agent setup scripts for Claude Code cloud environments (claude.ai/code).

## setup-langfuse-cloud.sh

Idempotently prepares the Langfuse Observability plugin declaration in the
repository's `.claude/settings.json` — designed to run from the **Cloud
Environment setup script**, which executes BEFORE Claude Code launches.

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

**How keys reach the plugin:** The Langfuse hook reads these variables from
the environment at runtime (env vars take precedence over plugin config in the
plugin source). Claude Code inherits the Cloud Environment variables, so no
secrets need to be embedded in the repo or in this script.

> Note: The setup script itself runs BEFORE the Cloud Environment variables
> are exported, so it cannot see them — that is expected and fine.

### Behavior

- Creates `.claude/settings.json` if missing or invalid
- Merges the Langfuse plugin declaration (marketplace + `enabledPlugins`)
  without touching existing settings (hooks, env, other plugins)
- If the `LANGFUSE_*` env vars happen to be visible (local repos, exported
  shells), embeds them into `pluginConfigs` as a fallback — otherwise leaves
  them to the runtime
- Skips if the config is already present
- Ensures `uv` is available (the plugin's preferred runtime)
