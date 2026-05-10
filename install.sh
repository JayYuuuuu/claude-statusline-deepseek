#!/usr/bin/env bash
# Install claude-statusline-deepseek into the current user's Claude Code config.
# - Copies statusline.sh to ~/.claude/statusline-deepseek.sh
# - Patches ~/.claude/settings.json so statusLine.command points to it
# - Backs up the old settings.json before patching
# Idempotent: safe to re-run.
#
# Two install modes:
#   1. Cloned repo:  ./install.sh             (uses ./statusline.sh)
#   2. Remote pipe:  curl ... | bash          (auto-downloads statusline.sh)

set -euo pipefail

# When piped from curl, BASH_SOURCE may be empty; fall back to "" then probe.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
SRC_LOCAL="${SCRIPT_DIR:-.}/statusline.sh"
REMOTE_RAW="https://raw.githubusercontent.com/JayYuuuuu/claude-statusline-deepseek/main/statusline.sh"
DEST_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
DEST="$DEST_DIR/statusline-deepseek.sh"
SETTINGS="$DEST_DIR/settings.json"

REMOVE_HUD=0
for arg in "$@"; do
  case "$arg" in
    --remove-claude-hud) REMOVE_HUD=1 ;;
    -h|--help)
      cat <<EOF
Usage: ./install.sh [options]

Options:
  --remove-claude-hud   Also disable claude-hud and free its plugin cache
                        (~37MB). Settings.json is backed up first.
  -h, --help            Show this message.
EOF
      exit 0 ;;
    *) printf 'Unknown flag: %s (use --help)\n' "$arg" >&2; exit 2 ;;
  esac
done

ok()    { printf '\033[32m✓\033[0m %s\n' "$*"; }
warn()  { printf '\033[33m!\033[0m %s\n' "$*"; }
err()   { printf '\033[31m✗\033[0m %s\n' "$*" >&2; }
heading(){ printf '\n\033[1m== %s ==\033[0m\n' "$*"; }

# ---- Dependency check ----
heading "Checking dependencies"
MISSING=0
for c in bash jq curl awk stat; do
  if command -v "$c" >/dev/null 2>&1; then
    ok "$c"
  else
    err "$c not found"; MISSING=1
  fi
done
if [ "$MISSING" -ne 0 ]; then
  err "Install the missing tools and re-run. macOS: brew install jq. Debian: apt install jq curl."
  exit 1
fi

# ---- Resolve source (local repo or remote download) ----
heading "Installing script"
mkdir -p "$DEST_DIR"
if [ -f "$SRC_LOCAL" ]; then
  cp "$SRC_LOCAL" "$DEST"
  ok "Copied from $SRC_LOCAL"
else
  TMP_SRC=$(mktemp)
  trap 'rm -f "$TMP_SRC"' EXIT
  if ! curl -fsSL --max-time 30 "$REMOTE_RAW" -o "$TMP_SRC"; then
    err "Failed to download $REMOTE_RAW"
    err "Either git clone the repo or check your network."
    exit 1
  fi
  cp "$TMP_SRC" "$DEST"
  ok "Downloaded from $REMOTE_RAW"
fi
chmod +x "$DEST"
ok "Wrote $DEST"

# ---- Patch settings.json ----
heading "Patching $SETTINGS"
TS=$(date +%Y%m%d-%H%M%S)
if [ -f "$SETTINGS" ]; then
  cp "$SETTINGS" "$SETTINGS.bak-$TS"
  ok "Backed up to $SETTINGS.bak-$TS"
  # Validate the existing file is JSON; if not, abort to avoid clobbering.
  if ! jq -e . "$SETTINGS" >/dev/null 2>&1; then
    err "$SETTINGS is not valid JSON. Fix it and re-run."
    exit 1
  fi
  TMP=$(mktemp)
  jq --arg cmd "~/.claude/statusline-deepseek.sh" \
     '.statusLine = {"type":"command","command":$cmd}' \
     "$SETTINGS" > "$TMP"
  mv "$TMP" "$SETTINGS"
else
  cat > "$SETTINGS" <<'JSON'
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/statusline-deepseek.sh"
  }
}
JSON
  ok "Created fresh $SETTINGS"
fi
ok "statusLine -> ~/.claude/statusline-deepseek.sh"

# ---- Optional: purge claude-hud ----
if [ "$REMOVE_HUD" = "1" ]; then
  heading "Purging claude-hud (--remove-claude-hud)"
  HAD_ENTRIES=$(jq -r '
    [(.enabledPlugins // {} | has("claude-hud@claude-hud") or has("claude-hud")),
     (.extraKnownMarketplaces // {} | has("claude-hud"))]
    | any
  ' "$SETTINGS" 2>/dev/null || echo false)
  TMP=$(mktemp)
  jq 'del(.enabledPlugins."claude-hud@claude-hud")
      | del(.enabledPlugins."claude-hud")
      | del(.extraKnownMarketplaces."claude-hud")' \
     "$SETTINGS" > "$TMP"
  mv "$TMP" "$SETTINGS"
  if [ "$HAD_ENTRIES" = "true" ]; then
    ok "Removed claude-hud entries from settings.json"
  else
    ok "No claude-hud entries in settings.json (already clean)"
  fi
  HUD_CACHE="$DEST_DIR/plugins/cache/claude-hud"
  if [ -d "$HUD_CACHE" ]; then
    SIZE=$(du -sh "$HUD_CACHE" 2>/dev/null | cut -f1)
    rm -rf "$HUD_CACHE"
    ok "Freed plugin cache ($SIZE) at $HUD_CACHE"
  else
    ok "No plugin cache at $HUD_CACHE"
  fi
fi

# ---- Smoke test ----
heading "Smoke test"
SAMPLE='{"session_id":"install-test","model":{"display_name":"test"},"workspace":{"current_dir":"/tmp"},"context_window":{"used_percentage":42,"context_window_size":200000},"cost":{"total_cost_usd":0,"total_duration_ms":0}}'
if printf '%s' "$SAMPLE" | "$DEST" >/dev/null 2>&1; then
  ok "Script runs without errors"
else
  warn "Script produced an error. Run with debug:"
  echo "    printf '%s' '$SAMPLE' | bash -x $DEST"
fi

heading "Done"
cat <<'TIPS'

Next steps:

  1. Send any message in Claude Code to trigger a statusline refresh.
     (Existing sessions won't update until the next interaction.)

  2. Verify DeepSeek mode by running cc-switch to a DeepSeek provider
     and starting a new session. The 💳 line will show real balance.

  3. Pricing is auto-selected based on the DeepSeek model cc-switch
     routes to (v4-flash by default, v4-pro when ANTHROPIC_DEFAULT_OPUS_MODEL
     or similar resolves to it). Force-override at:
       ~/.claude/statusline-deepseek.env
         DS_PRICE_INPUT_MISS=0.435
         DS_PRICE_INPUT_HIT=0.003625
         DS_PRICE_OUTPUT=0.87
         DS_MODEL_LABEL=v4-pro

  4. claude-hud cleanup (opt-in): ./install.sh --remove-claude-hud
     Disables it in settings.json and removes ~/.claude/plugins/cache/claude-hud
     (about 37MB). Idempotent. Re-add later via Claude Code's
     /plugin marketplace add jarrodwatts/claude-hud.

  5. Uninstall: ./uninstall.sh
TIPS
