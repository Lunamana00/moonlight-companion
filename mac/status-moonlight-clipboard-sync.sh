#!/usr/bin/env bash
set -euo pipefail

label="com.lunamana.moonlight-clipboard-sync"
plist="${HOME}/Library/LaunchAgents/${label}.plist"
log_path="${HOME}/Library/Logs/moonlight-clipboard-sync.log"

if launchctl print "gui/$(id -u)/${label}" >/dev/null 2>&1; then
  echo "running"
else
  echo "stopped"
fi

if [[ -f "$plist" ]]; then
  echo "plist: $plist"
fi

if [[ -f "$log_path" ]]; then
  echo
  echo "recent log:"
  tail -20 "$log_path"
fi
