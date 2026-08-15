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
#   Config (no secrets):
#     Primary:  <repo>/.claude/settings.json — cloud sessions only honour
#               repository + server-managed settings (user-level settings
#               stay on the machine, per Anthropic docs), so a session MUST
#               have a repository attached for the plugin to activate.
#     Fallback: $HOME/.claude/settings.json — written best-effort; may help
#               in self-hosted setups, normally ignored by Anthropic-hosted
#               cloud.
#
# KEYS / SECRETS
#   This script NEVER writes keys into any file. The Langfuse hook reads
#   LANGFUSE_PUBLIC_KEY / LANGFUSE_SECRET_KEY / LANGFUSE_BASE_URL from the
#   process environment at runtime — env vars take precedence over plugin
#   config in the plugin source, see _core_opt. Cloud Environment Variables
#   set via claude.ai are copied straight into the VM's process environment,
#   so the hook — running as a subprocess of Claude Code — sees them without
#   any file round-trip. Set them as Environment Variables in the Cloud
#   Environment; do not store them in this repo.
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

# --- Ensure Langfuse plugin declaration in one settings.json (no secrets) ----
ensure_langfuse() {
    local target="$1"
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

    jq '
      .plugins.extraKnownMarketplaces["langfuse-observability"] = {
        "source": { "source": "github", "repo": "langfuse/Claude-Observability-Plugin" }
      }
      | .plugins.enabledPlugins |= (if index("langfuse-observability@langfuse-observability") then . else . + ["langfuse-observability@langfuse-observability"] end)
    ' "$tmp" > "$next"

    if [ -f "$target" ] && cmp -s "$target" "$next"; then
        echo "OK: Langfuse config already present and correct in $target (nothing to do)"
    else
        mv "$next" "$target"
        echo ">> Langfuse config written to $target"
    fi

    rm -f "$tmp" "$next" 2>/dev/null || true
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

# --- Ensure plugin actually installed (not just declared) --------------------
# settings.json only declares the plugin; the hook that sends traces is
# registered only once the marketplace repo is cloned and the plugin is
# installed. Declaring alone left cloud sessions with 0 traces (verified via
# `claude plugin list` = empty, ~/.claude/plugins missing). Install
# best-effort here so fresh sessions start with a working hook.
if command -v claude >/dev/null 2>&1; then
    if claude plugin list 2>/dev/null | grep -q "langfuse-observability@langfuse-observability"; then
        echo "OK: langfuse-observability plugin already installed"
    else
        echo ">> Installing langfuse-observability plugin..."
        claude plugin marketplace add langfuse/Claude-Observability-Plugin >/dev/null 2>&1 || true
        if claude plugin install langfuse-observability@langfuse-observability >/dev/null 2>&1; then
            echo "OK: plugin installed (scope: user)"
        else
            echo ">> WARN: plugin install failed — install manually via '/plugin install'"
            echo ">>       langfuse-observability@langfuse-observability in Claude Code."
        fi
    fi
else
    echo ">> INFO: claude CLI not on PATH — plugin install skipped (declaration only)."
fi

echo "DONE."
echo ">> HINWEIS: Keys kommen zur Laufzeit aus den Cloud-Environment-Env-Vars"
echo ">> (LANGFUSE_PUBLIC_KEY, LANGFUSE_SECRET_KEY, LANGFUSE_BASE_URL) — dieses"
echo ">> Script schreibt bewusst KEINE Secrets in Dateien."
