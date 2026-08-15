#!/usr/bin/env bash
# =============================================================================
# setup-langfuse-cloud.sh — Idempotent Langfuse Observability setup for
# Claude Code cloud environments (claude.ai/code).
#
# Runs from the Cloud Environment *setup script*, BEFORE Claude Code launches.
# It ensures .claude/settings.json declares + enables the Langfuse
# Observability plugin.
#
# WHERE IT WRITES
#   Primary:  <repo>/.claude/settings.json — cloud sessions only honour
#             repository + server-managed settings (user-level settings stay
#             on the machine, per Anthropic docs), so a session MUST have a
#             repository attached for the plugin to activate.
#   Fallback: $HOME/.claude/settings.json — written best-effort; may help in
#             self-hosted setups, normally ignored by Anthropic-hosted cloud.
#
# KEYS / SECRETS
#   No keys are embedded. The Langfuse hook reads LANGFUSE_PUBLIC_KEY /
#   LANGFUSE_SECRET_KEY / LANGFUSE_BASE_URL from the process environment at
#   runtime (env vars take precedence over plugin config in the plugin
#   source). Cloud Environment variables are copied into the VM environment,
#   so the hook — running as a subprocess of Claude Code — sees them.
#   If the env vars are visible to this script (local repos, exported
#   shells), they are additionally written into pluginConfigs as a fallback.
#
# Exit codes: 0 = success (config ensured or clearly reported), 1 = hard error.
# =============================================================================
set -euo pipefail

# --- Locate repository (walk up from CWD) ------------------------------------
REPO_ROOT=""
if git rev-parse --show-toplevel >/dev/null 2>&1; then
    REPO_ROOT="$(git rev-parse --show-toplevel)"
fi

TARGETS=()
if [ -n "$REPO_ROOT" ]; then
    echo ">> Repo root: $REPO_ROOT"
    TARGETS+=("$REPO_ROOT/.claude/settings.json")
else
    echo ">> WARNUNG: kein Git-Repository in dieser Session gefunden."
    echo ">> Cloud-Sessions lesen NUR Repo-Settings — starte die Session MIT einem"
    echo ">> Repository (Repo in claude.ai/code auswaehlen), sonst aktiviert sich"
    echo ">> das Plugin nicht."
fi
TARGETS+=("$HOME/.claude/settings.json")   # best-effort fallback

# --- Ensure Langfuse plugin declaration in one settings.json -----------------
ensure_langfuse() {
    local target="$1"
    local dir; dir="$(dirname "$target")"
    mkdir -p "$dir"

    local tmp; tmp="$(mktemp)"
    local next; next="$(mktemp)"
    local tmp2=""

    if [ -f "$target" ] && jq -e . "$target" >/dev/null 2>&1; then
        jq . "$target" > "$tmp"
    else
        if [ -f "$target" ]; then
            echo ">> Creating fresh $target (existing file missing or invalid JSON)"
        else
            echo ">> Creating fresh $target"
        fi
        echo '{}' > "$tmp"
    fi

    jq '
      .plugins.extraKnownMarketplaces["langfuse-observability"] = {
        "source": { "source": "github", "repo": "langfuse/Claude-Observability-Plugin" }
      }
      | .plugins.enabledPlugins |= (if index("langfuse-observability@langfuse-observability") then . else . + ["langfuse-observability@langfuse-observability"] end)
    ' "$tmp" > "$next"

    local embedded=0
    if [ -n "${LANGFUSE_PUBLIC_KEY:-}" ] && [ -n "${LANGFUSE_SECRET_KEY:-}" ]; then
        local tmp2; tmp2="$(mktemp)"
        jq --arg pk "$LANGFUSE_PUBLIC_KEY" \
           --arg sk "$LANGFUSE_SECRET_KEY" \
           --arg b64 "${LANGFUSE_BASE_URL:-https://cloud.langfuse.com}" \
          '.pluginConfigs["langfuse-observability@langfuse-observability"] = {
             "options": {
               "LANGFUSE_PUBLIC_KEY": $pk,
               "LANGFUSE_SECRET_KEY": $sk,
               "LANGFUSE_BASE_URL": $b64
             }
           }' "$next" > "$tmp2"
        mv "$tmp2" "$next"
        embedded=1
    fi

    if [ -f "$target" ] && cmp -s "$target" "$next"; then
        echo "OK: Langfuse config already present and correct in $target (nothing to do)"
    else
        mv "$next" "$target"
        echo ">> Langfuse config written to $target"
    fi

    if [ "$embedded" -eq 0 ]; then
        echo ">> INFO: LANGFUSE_* env vars not visible here (normal in cloud setup) —"
        echo ">>       the hook reads them from the Claude Code process at runtime."
    else
        echo ">> LANGFUSE_* env vars found — embedded into pluginConfigs as fallback."
    fi

    rm -f "$tmp" "$next" "$tmp2" 2>/dev/null || true
}

for t in "${TARGETS[@]}"; do
    ensure_langfuse "$t"
done

# --- Ensure runtime: uv (the hook's preferred runtime) -----------------------
# The hook itself falls back to python3 + langfuse if uv is not on PATH, so
# this script only has to make sure uv exists.
if command -v uv >/dev/null 2>&1; then
    echo "OK: uv already available ($(uv --version 2>/dev/null | head -1))"
else
    echo ">> uv not found — installing via pip..."
    if python3 -m pip install --quiet uv; then
        echo "OK: uv installed"
    else
        echo ">> pip install uv failed — the hook will fall back to python3 + langfuse"
        echo ">> (it installs its own runtime on first run)."
    fi
fi

echo "DONE."
