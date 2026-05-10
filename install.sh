#!/usr/bin/env bash
# Install claude-statusline-deepseek into the current user's Claude Code config.
# - Copies statusline.sh to ~/.claude/statusline-deepseek.sh
# - Patches ~/.claude/settings.json so statusLine.command points to it
# - Backs up the old settings.json before patching
# Idempotent: safe to re-run.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$SCRIPT_DIR/statusline.sh"
DEST_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
DEST="$DEST_DIR/statusline-deepseek.sh"
SETTINGS="$DEST_DIR/settings.json"

ok()    { printf '\033[32m✓\033[0m %s\n' "$*"; }
warn()  { printf '\033[33m!\033[0m %s\n' "$*"; }
err()   { printf '\033[31m✗\033[0m %s\n' "$*" >&2; }
heading(){ printf '\n\033[1m== %s ==\033[0m\n' "$*"; }

# ---- Dependency check ----
heading "Checking dependencies"
MISSING=0
for c in bash jq curl awk stat git; do
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

# ---- Copy script ----
heading "Installing script"
mkdir -p "$DEST_DIR"
cp "$SRC" "$DEST"
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

  4. Uninstall: ./uninstall.sh
TIPS
