# .agents

Shared agent setup scripts for Claude Code cloud environments (claude.ai/code).

## setup-langfuse-cloud.sh

Idempotently prepares the Langfuse Observability plugin config in the
repository's `.claude/settings.json` — designed to run from the **Cloud
Environment setup script**, which executes BEFORE Claude Code launches.

### Cloud Environment setup script

```bash
curl -fsSL https://raw.githubusercontent.com/HearthCore/.agents/main/setup-langfuse-cloud.sh | bash
```

### Required environment variables (set in the Cloud Environment)

| Variable | Example |
|---|---|
| `LANGFUSE_PUBLIC_KEY` | `pk-lf-...` |
| `LANGFUSE_SECRET_KEY` | `sk-lf-...` |
| `LANGFUSE_BASE_URL` | `https://fuse.goetzken.dev` |

### Behavior

- Creates `.claude/settings.json` if missing or invalid
- Merges the Langfuse plugin block (marketplace, `enabledPlugins`,
  `pluginConfigs`) without touching existing settings (hooks, env, other plugins)
- Skips if the config is already present and matches the current keys
- Ensures `uv` is available (the plugin's preferred runtime)
