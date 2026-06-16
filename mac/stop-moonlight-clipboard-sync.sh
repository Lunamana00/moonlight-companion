#!/usr/bin/env bash
set -euo pipefail

label="com.lunamana.moonlight-clipboard-sync"
plist="${HOME}/Library/LaunchAgents/${label}.plist"

launchctl bootout "gui/$(id -u)" "$plist" >/dev/null 2>&1 || true
rm -f "$plist"

echo "Moonlight clipboard sync stopped."
