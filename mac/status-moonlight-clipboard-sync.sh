#!/usr/bin/env bash
set -euo pipefail

label="com.lunamana.moonlight-clipboard-sync"
clip_tcp_label="com.lunamana.moonlight-clipboard-tcp-receiver"
clip_tunnel_label="com.lunamana.moonlight-clipboard-tunnel"
caps_label="com.lunamana.moonlight-capslock-hangul"
caps_tunnel_label="com.lunamana.moonlight-capslock-tunnel"
plist="${HOME}/Library/LaunchAgents/${label}.plist"
clip_tcp_plist="${HOME}/Library/LaunchAgents/${clip_tcp_label}.plist"
clip_tunnel_plist="${HOME}/Library/LaunchAgents/${clip_tunnel_label}.plist"
caps_plist="${HOME}/Library/LaunchAgents/${caps_label}.plist"
caps_tunnel_plist="${HOME}/Library/LaunchAgents/${caps_tunnel_label}.plist"
log_path="${HOME}/Library/Logs/moonlight-clipboard-sync.log"
caps_log_path="${HOME}/Library/Logs/moonlight-capslock-hangul.log"

print_service_status() {
  local name="$1"
  local service_label="$2"
  local state

  if ! state="$(launchctl print "gui/$(id -u)/${service_label}" 2>/dev/null | awk -F= '/state =/{gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit}')"; then
    echo "${name}: stopped"
    return
  fi

  if [[ -z "$state" ]]; then
    echo "${name}: loaded"
  else
    echo "${name}: ${state}"
  fi
}

print_service_status "clipboard sync" "$label"
print_service_status "clipboard TCP receiver" "$clip_tcp_label"
print_service_status "clipboard TCP tunnel" "$clip_tunnel_label"
print_service_status "Caps Lock tunnel" "$caps_tunnel_label"
print_service_status "Moonlight keyboard helper" "$caps_label"

if [[ -f "$plist" ]]; then
  echo "plist: $plist"
fi
if [[ -f "$clip_tcp_plist" ]]; then
  echo "clipboard TCP plist: $clip_tcp_plist"
fi
if [[ -f "$clip_tunnel_plist" ]]; then
  echo "clipboard tunnel plist: $clip_tunnel_plist"
fi
if [[ -f "$caps_plist" ]]; then
  echo "keyboard helper plist: $caps_plist"
fi
if [[ -f "$caps_tunnel_plist" ]]; then
  echo "caps tunnel plist: $caps_tunnel_plist"
fi

if [[ -f "$log_path" ]]; then
  echo
  echo "recent clipboard log:"
  tail -20 "$log_path"
fi

if [[ -f "$caps_log_path" ]]; then
  echo
  echo "recent keyboard log:"
  tail -20 "$caps_log_path"
fi
