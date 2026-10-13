#!/bin/bash
# Installs the Release build into /Applications (quits a running copy first).
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Build/Products/Release/Lightwell.app"
DEST="/Applications/Lightwell.app"
BUNDLE_ID="com.alexluncan.lightwell"

[ -d "$APP" ] || { echo "install: $APP not found, run make build first" >&2; exit 1; }
codesign --verify --deep --strict "$APP"

if pgrep -x Lightwell >/dev/null; then
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" || true
  # No timeout(1) on macOS: wait up to 15 s with a watchdog loop.
  for _ in $(seq 1 30); do
    pgrep -x Lightwell >/dev/null || break
    sleep 0.5
  done
  if pgrep -x Lightwell >/dev/null; then
    echo "install: Lightwell is still running, quit it and retry" >&2
    exit 1
  fi
fi

rm -rf "$DEST"
ditto "$APP" "$DEST"
codesign --verify --deep --strict --verbose=2 "$DEST"
echo "install: installed $DEST"
