#!/usr/bin/env bash
# =============================================================================
# setup-langfuse-cloud.sh — Idempotent Langfuse Observability setup for
# Claude Code cloud environments (claude.ai/code).
#
# Runs from the Cloud Environment *setup script*, BEFORE Claude Code launches.
# It ensures the repository's .claude/settings.json declares + enables the
# Langfuse Observability plugin. Keys are NOT embedded: the Langfuse hook
# reads LANGFUSE_PUBLIC_KEY / LANGFUSE_SECRET_KEY / LANGFUSE_BASE_URL from the
# environment at runtime (the hook prefers env vars over plugin config — see
# _core_opt in the plugin source), and Claude Code's process inherits the
# Cloud Environment variables.
#
# If the env vars happen to be present when this script runs (local repos,
# shells where they are exported), it additionally writes them into
# pluginConfigs as a fallback for setups that don't pass env vars through.
#
# Exit codes: 0 = success (config ensured or already correct), 1 = hard error.
# =============================================================================
set -euo pipefail

# --- Required env vars (for the runtime, NOT for this script) ---------------
# LANGFUSE_PUBLIC_KEY
# LANGFUSE_SECRET_KEY
# LANGFUSE_BASE_URL  (e.g. https://fuse.goetzken.dev)
#
# These must be set as Environment Variables in the claude.ai/code Cloud
# Environment. They are consumed by the Langfuse hook at runtime; this script
# does not fail when they are missing here.

# --- Locate repo root --------------------------------------------------------
if REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null); then
    echo ">> Repo root: $REPO_ROOT"
else
    echo "ERROR: not inside a git repository — cannot create .claude/settings.json" >&2
    exit 1
fi

CLAUDE_DIR="$REPO_ROOT/.claude"
SETTINGS="$CLAUDE_DIR/settings.json"
mkdir -p "$CLAUDE_DIR"

# --- Load existing settings (or start fresh) ---------------------------------
if [ -f "$SETTINGS" ] && jq -e . "$SETTINGS" >/dev/null 2>&1; then
    # shellcheck disable=SC2016
    jq . "$SETTINGS" > /tmp/lf_settings_$$.json
    SETTINGS_TMP=/tmp/lf_settings_$$.json
else
    if [ -f "$SETTINGS" ]; then
        echo ">> Creating fresh $SETTINGS (existing file missing or invalid JSON)"
    else
        echo ">> Creating fresh $SETTINGS"
    fi
    echo '{}' > /tmp/lf_settings_$$.json
    SETTINGS_TMP=/tmp/lf_settings_$$.json
fi

# --- Merge plugin declaration (marketplace + enabledPlugins) -----------------
jq '
  .plugins.extraKnownMarketplaces["langfuse-observability"] = {
    "source": { "source": "github", "repo": "langfuse/Claude-Observability-Plugin" }
  }
  | .plugins.enabledPlugins |= (if index("langfuse-observability@langfuse-observability") then . else . + ["langfuse-observability@langfuse-observability"] end)
' "$SETTINGS_TMP" > /tmp/lf_settings_next_$$.json

# --- Optional: embed keys into pluginConfigs if env vars are present ---------
EMBEDDED=0
if [ -n "${LANGFUSE_PUBLIC_KEY:-}" ] && [ -n "${LANGFUSE_SECRET_KEY:-}" ]; then
    jq --arg pk "$LANGFUSE_PUBLIC_KEY" \
       --arg sk "$LANGFUSE_SECRET_KEY" \
       --arg b64 "${LANGFUSE_BASE_URL:-https://cloud.langfuse.com}" \
      '.pluginConfigs["langfuse-observability@langfuse-observability"] = {
         "options": {
           "LANGFUSE_PUBLIC_KEY": $pk,
           "LANGFUSE_SECRET_KEY": $sk,
           "LANGFUSE_BASE_URL": $b64
         }
       }' /tmp/lf_settings_next_$$.json > /tmp/lf_settings_next2_$$.json
    mv /tmp/lf_settings_next2_$$.json /tmp/lf_settings_next_$$.json
    EMBEDDED=1
fi

# --- Detect change / skip -----------------------------------------------------
if [ -f "$SETTINGS" ] && cmp -s "$SETTINGS" /tmp/lf_settings_next_$$.json; then
    echo "OK: Langfuse config already present and correct in $SETTINGS (nothing to do)"
    rm -f /tmp/lf_settings_$$.json /tmp/lf_settings_next_$$.json /tmp/lf_settings_next2_$$.json
else
    mv /tmp/lf_settings_next_$$.json "$SETTINGS"
    echo ">> Langfuse config written to $SETTINGS"
    rm -f /tmp/lf_settings_$$.json /tmp/lf_settings_next2_$$.json
fi

if [ "$EMBEDDED" -eq 0 ]; then
    echo ">> INFO: LANGFUSE_* env vars not visible to this script (normal in cloud setup)."
    echo ">> The hook reads them from the Claude Code process environment at runtime."
else
    echo ">> LANGFUSE_* env vars found — embedded into pluginConfigs as fallback."
fi

# --- Ensure runtime (uv preferred, python3+langfuse as fallback) -------------
if command -v uv >/dev/null 2>&1; then
    echo "OK: uv already available ($(uv --version 2>/dev/null | head -1))"
else
    echo ">> uv not found — installing via pip..."
    if python3 -m pip install --quiet uv; then
        echo "OK: uv installed"
    else
        echo ">> pip install uv failed — will rely on python3 + langfuse (hook falls back automatically)."
        python3 -m pip install --quiet "langfuse>=4,<5" || true
    fi
fi

echo "DONE."
