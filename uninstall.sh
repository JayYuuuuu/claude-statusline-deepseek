#!/usr/bin/env bash
# Uninstall claude-statusline-deepseek.
# - Restores the most recent settings.json backup that install.sh made.
# - Removes the deployed script and per-session caches.

set -euo pipefail

DEST_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
DEST="$DEST_DIR/statusline-deepseek.sh"
SETTINGS="$DEST_DIR/settings.json"

ok()   { printf '\033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '\033[33m!\033[0m %s\n' "$*"; }
err()  { printf '\033[31m✗\033[0m %s\n' "$*" >&2; }

# Find newest backup
LATEST=$(ls -1t "$SETTINGS".bak-* 2>/dev/null | head -1 || true)
if [ -n "$LATEST" ]; then
  cp "$LATEST" "$SETTINGS"
  ok "Restored $SETTINGS from $LATEST"
else
  warn "No backup found at $SETTINGS.bak-*. Edit settings.json manually if needed."
fi

if [ -f "$DEST" ]; then
  rm -f "$DEST"
  ok "Removed $DEST"
fi

# Clear per-session caches
rm -f "${TMPDIR:-/tmp}"/dstx-*.json \
      "${TMPDIR:-/tmp}"/dsbal-*.json \
      "${TMPDIR:-/tmp}"/dsbase-*.txt \
      /tmp/dstx-*.json /tmp/dsbal-*.json /tmp/dsbase-*.txt 2>/dev/null || true
ok "Cleared caches"

ok "Done. Restart any active Claude Code sessions to pick up the change."
