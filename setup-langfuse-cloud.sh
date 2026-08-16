#!/usr/bin/env bash
# =============================================================================
# setup-langfuse-cloud.sh — Idempotent plugin setup for Claude Code cloud
# environments (claude.ai/code).
#
# Despite the filename (kept for backwards compat with existing Cloud
# Environment setup-script URLs), this now provisions TWO plugins the same
# way: Langfuse Observability and OpenViking Memory.
#
# Runs from the Cloud Environment *setup script*, BEFORE Claude Code launches.
# It ensures .claude/settings.json declares + enables both plugins.
#
# WHERE IT WRITES
#   Config (no secrets):
#     Primary:  <repo>/.claude/settings.json — cloud sessions only honour
#               repository + server-managed settings (user-level settings
#               stay on the machine, per Anthropic docs), so a session MUST
#               have a repository attached for the plugins to activate.
#     Fallback: $HOME/.claude/settings.json — written best-effort; may help
#               in self-hosted setups, normally ignored by Anthropic-hosted
#               cloud.
#
# KEYS / SECRETS
#   This script NEVER writes keys into any file.
#   - The Langfuse hook reads LANGFUSE_PUBLIC_KEY / LANGFUSE_SECRET_KEY /
#     LANGFUSE_BASE_URL from the process environment at runtime — env vars
#     take precedence over plugin config in the plugin source.
#   - The OpenViking plugin reads OPENVIKING_URL / OPENVIKING_API_KEY /
#     OPENVIKING_MEMORY_ENABLED the same way — env vars override ovcli.conf,
#     which is itself a LOCAL/HOME-ONLY credential file (~/.openviking/ovcli.conf)
#     that must never be written into this repo or any tracked file. See
#     AGENTS.md "Secrets model" before touching either plugin's setup.
#   Cloud Environment Variables set via claude.ai are copied straight into
#   the VM's process environment, so both hooks — running as subprocesses of
#   Claude Code — see them without any file round-trip. Set them as
#   Environment Variables in the Cloud Environment; do not store them in
#   this repo.
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
    echo ">> Repository (Repo in claude.ai/code auswaehlen), sonst aktivieren sich"
    echo ">> die Plugins nicht."
fi
TARGETS+=("$HOME/.claude/settings.json")   # best-effort fallback

# --- Ensure a plugin's marketplace + enabledPlugins entry (no secrets) -------
# Generic helper: ensure_plugin <target-file> <marketplace-key> <marketplace-source-json> <plugin@marketplace>
ensure_plugin() {
    local target="$1" mp_key="$2" mp_source_json="$3" plugin_id="$4"
    local dir; dir="$(dirname "$target")"
    mkdir -p "$dir"

    local tmp; tmp="$(mktemp)"
    local next; next="$(mktemp)"

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

    jq --argjson src "$mp_source_json" --arg key "$mp_key" --arg plugin "$plugin_id" '
      .plugins.extraKnownMarketplaces[$key] = { "source": $src }
      | .plugins.enabledPlugins |= (if index($plugin) then . else . + [$plugin] end)
    ' "$tmp" > "$next"

    if [ -f "$target" ] && cmp -s "$target" "$next"; then
        echo "OK: $plugin_id config already present and correct in $target (nothing to do)"
    else
        mv "$next" "$target"
        echo ">> $plugin_id config written to $target"
    fi

    rm -f "$tmp" "$next" 2>/dev/null || true
}

LANGFUSE_SOURCE_JSON='{"source":"github","repo":"langfuse/Claude-Observability-Plugin"}'
OPENVIKING_SOURCE_JSON='{"source":"url","url":"https://raw.githubusercontent.com/volcengine/OpenViking/main/.claude-plugin/marketplace.json"}'

for t in "${TARGETS[@]}"; do
    ensure_plugin "$t" "langfuse-observability" "$LANGFUSE_SOURCE_JSON" "langfuse-observability@langfuse-observability"
    ensure_plugin "$t" "openviking" "$OPENVIKING_SOURCE_JSON" "openviking-memory@openviking"
done

# --- Ensure runtime: uv (Langfuse hook's preferred runtime) ------------------
# The Langfuse hook falls back to python3 + langfuse if uv is not on PATH, so
# this script only has to make sure uv exists. OpenViking's hook is Node-based
# (auto-capture.mjs) and relies on the Node runtime already present in the
# cloud environment image — nothing extra to provision here for it.
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

# --- Ensure plugins actually installed (not just declared) -------------------
# settings.json only declares the plugin; the hooks that do the actual work
# are registered only once the marketplace repo is cloned and the plugin is
# installed. Declaring alone left cloud sessions with 0 Langfuse traces
# (verified via `claude plugin list` = empty, ~/.claude/plugins missing).
# Install best-effort here so fresh sessions start with working hooks.
install_plugin_if_missing() {
    local plugin_id="$1" marketplace_ref="$2" label="$3"
    if claude plugin list 2>/dev/null | grep -q "$plugin_id"; then
        echo "OK: $label plugin already installed"
    else
        echo ">> Installing $label plugin..."
        claude plugin marketplace add "$marketplace_ref" >/dev/null 2>&1 || true
        if claude plugin install "$plugin_id" >/dev/null 2>&1; then
            echo "OK: $label plugin installed (scope: user)"
        else
            echo ">> WARN: $label plugin install failed — install manually via '/plugin install'"
            echo ">>       $plugin_id in Claude Code."
        fi
    fi
}

if command -v claude >/dev/null 2>&1; then
    install_plugin_if_missing "langfuse-observability@langfuse-observability" \
        "langfuse/Claude-Observability-Plugin" "langfuse-observability"
    install_plugin_if_missing "openviking-memory@openviking" \
        "https://raw.githubusercontent.com/volcengine/OpenViking/main/.claude-plugin/marketplace.json" \
        "openviking-memory"
else
    echo ">> INFO: claude CLI not on PATH — plugin install skipped (declaration only)."
fi

echo "DONE."
echo ">> HINWEIS: Keys/Flags kommen zur Laufzeit aus den Cloud-Environment-Env-Vars"
echo ">>   Langfuse:   LANGFUSE_PUBLIC_KEY, LANGFUSE_SECRET_KEY, LANGFUSE_BASE_URL"
echo ">>   OpenViking: OPENVIKING_URL, OPENVIKING_API_KEY, OPENVIKING_MEMORY_ENABLED=1"
echo ">> Dieses Script schreibt bewusst KEINE Secrets in Dateien."
