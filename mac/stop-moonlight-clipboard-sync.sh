#!/usr/bin/env bash
set -euo pipefail

label="com.lunamana.moonlight-clipboard-sync"
caps_label="com.lunamana.moonlight-capslock-hangul"
plist="${HOME}/Library/LaunchAgents/${label}.plist"
caps_plist="${HOME}/Library/LaunchAgents/${caps_label}.plist"

launchctl bootout "gui/$(id -u)" "$plist" >/dev/null 2>&1 || true
launchctl bootout "gui/$(id -u)" "$caps_plist" >/dev/null 2>&1 || true
rm -f "$plist"
rm -f "$caps_plist"

echo "Moonlight clipboard sync stopped."
