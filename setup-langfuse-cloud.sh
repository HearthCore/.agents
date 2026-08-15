#!/usr/bin/env bash
# setup-langfuse-cloud.sh
#
# Idempotently ensures the Langfuse Observability plugin is declared AND
# configured in the repository's .claude/settings.json BEFORE Claude Code
# starts. Designed to run from the Claude Code on the web "Cloud Environment"
# setup script (which runs before Claude Code launches).
#
# Required env vars (set in the Cloud Environment):
#   LANGFUSE_PUBLIC_KEY   pk-lf-...
#   LANGFUSE_SECRET_KEY   sk-lf-...
#   LANGFUSE_BASE_URL     e.g. https://fuse.goetzken.dev
#
# Behavior:
#   - Creates .claude/settings.json if missing (or if invalid JSON)
#   - Merges the Langfuse plugin block WITHOUT touching other settings
#     (other plugins, hooks, env blocks are preserved)
#   - Skips if the config is already present and matches the current keys
#   - Also ensures `uv` is available (the plugin's preferred runtime)
#
# Usage (from the Cloud Environment setup script):
#   curl -fsSL https://raw.githubusercontent.com/<ORG>/<REPO>/main/setup-langfuse-cloud.sh | bash

set -euo pipefail

# --- locate repo root ---------------------------------------------------------
# Setup scripts run with the freshly cloned repo; $CLAUDE_PROJECT_DIR may or
# may not be set, so fall back to git root / CWD.
REPO_ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
SETTINGS_DIR="$REPO_ROOT/.claude"
SETTINGS="$SETTINGS_DIR/settings.json"
PLUGIN_ID="langfuse-observability@langfuse-observability"

echo ">> Repo root: $REPO_ROOT"

# --- required env -------------------------------------------------------------
for var in LANGFUSE_PUBLIC_KEY LANGFUSE_SECRET_KEY LANGFUSE_BASE_URL; do
  if [ -z "${!var:-}" ]; then
    echo "ERROR: $var is not set in the cloud environment" >&2
    exit 1
  fi
done

mkdir -p "$SETTINGS_DIR"

# --- already correctly configured? --------------------------------------------
if [ -f "$SETTINGS" ] && jq -e \
    --arg pk "$LANGFUSE_PUBLIC_KEY" \
    --arg sk "$LANGFUSE_SECRET_KEY" \
    --arg base "$LANGFUSE_BASE_URL" \
    '.pluginConfigs["langfuse-observability@langfuse-observability"].options |
      (.LANGFUSE_PUBLIC_KEY == $pk) and
      (.LANGFUSE_SECRET_KEY == $sk) and
      (.LANGFUSE_BASE_URL == $base)' \
    "$SETTINGS" >/dev/null 2>&1; then
  echo "OK: Langfuse config already present and correct in $SETTINGS (nothing to do)"
  exit 0
fi

# --- create / repair base file if missing or invalid ---------------------------
if [ ! -s "$SETTINGS" ] || ! jq -e . "$SETTINGS" >/dev/null 2>&1; then
  echo ">> Creating fresh $SETTINGS (missing or invalid JSON)"
  echo "{}" > "$SETTINGS"
fi

# --- merge Langfuse block field by field (preserves everything else) -----------
jq --arg pk "$LANGFUSE_PUBLIC_KEY" \
   --arg sk "$LANGFUSE_SECRET_KEY" \
   --arg base "$LANGFUSE_BASE_URL" \
   --arg plugin "$PLUGIN_ID" \
   '
     .plugins.extraKnownMarketplaces["langfuse-observability"] = {
       "source": { "source": "github", "repo": "langfuse/Claude-Observability-Plugin" }
     }
     | .plugins.enabledPlugins |= (if index($plugin) then . else . + [$plugin] end)
     | .pluginConfigs["langfuse-observability@langfuse-observability"].options = {
         "LANGFUSE_PUBLIC_KEY": $pk,
         "LANGFUSE_SECRET_KEY": $sk,
         "LANGFUSE_BASE_URL": $base
       }
   ' "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"

echo ">> Langfuse config written to $SETTINGS"

# --- ensure uv (plugin's preferred runtime; hook falls back to python3+langfuse) -
if command -v uv >/dev/null 2>&1; then
  echo "OK: uv already available ($(uv --version))"
else
  echo ">> Installing uv via pip ..."
  pip install -q uv || echo "WARN: uv install failed; hook will fall back to python3 + langfuse SDK"
fi

echo "DONE."
