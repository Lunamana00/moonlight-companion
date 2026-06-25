#!/usr/bin/env bash
set -euo pipefail

label="com.lunamana.moonlight-clipboard-sync"
clip_tcp_label="com.lunamana.moonlight-clipboard-tcp-receiver"
clip_tunnel_label="com.lunamana.moonlight-clipboard-tunnel"
caps_label="com.lunamana.moonlight-capslock-hangul"
caps_tunnel_label="com.lunamana.moonlight-capslock-tunnel"
script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_dir="$(cd "${script_dir}/.." && pwd)"
config="${MOONLIGHT_COMPANION_CONFIG:-${repo_dir}/config/moonlight-companion.conf}"
plist="${HOME}/Library/LaunchAgents/${label}.plist"
clip_tcp_plist="${HOME}/Library/LaunchAgents/${clip_tcp_label}.plist"
clip_tunnel_plist="${HOME}/Library/LaunchAgents/${clip_tunnel_label}.plist"
caps_plist="${HOME}/Library/LaunchAgents/${caps_label}.plist"
caps_tunnel_plist="${HOME}/Library/LaunchAgents/${caps_tunnel_label}.plist"
log_path="${HOME}/Library/Logs/moonlight-clipboard-sync.log"
caps_log_path="${HOME}/Library/Logs/moonlight-capslock-hangul.log"

if [[ ! -f "$config" ]]; then
  config="${repo_dir}/config/moonlight-companion.conf.example"
fi

if [[ -f "$config" ]]; then
  # shellcheck source=/dev/null
  source "$config"
fi

WINDOWS_SSH="${WINDOWS_SSH:-moonlight-windows}"

print_windows_agent_status() {
  local ps_script encoded output status

  read -r -d '' ps_script <<'POWERSHELL' || true
$ErrorActionPreference = "SilentlyContinue"
$ProgressPreference = "SilentlyContinue"
$dir = Join-Path $env:USERPROFILE ".moonlight-clipboard-sync"
$agentPath = Join-Path $dir "windows-clipboard-agent.ps1"
$settingsPath = Join-Path $dir "windows-agent-settings.ps1"
$logPath = Join-Path $dir "windows-agent.log"
$agentProcesses = @(Get-CimInstance Win32_Process | Where-Object {
  $_.CommandLine -like "*windows-clipboard-agent.ps1*" -and
  $_.CommandLine -notlike "*_restart-windows-agent.ps1*"
})
if ($agentProcesses.Count -gt 0) {
  Write-Output ("Windows GUI agent: running ({0})" -f $agentProcesses.Count)
} else {
  Write-Output "Windows GUI agent: stopped (0)"
}
if (Test-Path -LiteralPath $agentPath) {
  Write-Output ("Windows agent script: {0}" -f $agentPath)
} else {
  Write-Output "Windows agent script: missing"
}
if (Test-Path -LiteralPath $settingsPath) {
  Write-Output ("Windows agent settings: {0}" -f $settingsPath)
} else {
  Write-Output "Windows agent settings: missing"
}
if (Test-Path -LiteralPath $logPath) {
  Write-Output ""
  Write-Output "recent Windows agent log:"
  Get-Content -LiteralPath $logPath -Tail 12 -Encoding UTF8
}
POWERSHELL

  encoded="$(printf '%s' "$ps_script" | iconv -f UTF-8 -t UTF-16LE | base64 | tr -d '\n')"

  set +e
  output="$(
    ssh \
      -q \
      -o BatchMode=yes \
      -o ConnectTimeout=3 \
      -o ConnectionAttempts=1 \
      -o LogLevel=ERROR \
      -o ServerAliveInterval=5 \
      -o ServerAliveCountMax=1 \
      -o StrictHostKeyChecking=accept-new \
      "$WINDOWS_SSH" \
      "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encoded" \
      2>&1
  )"
  status=$?
  set -e

  echo
  if [[ "$status" -eq 0 ]]; then
    output="${output//$'\r'/}"
    printf '%s\n' "$output"
  else
    output="${output//$'\r'/}"
    echo "Windows GUI agent: unavailable via ${WINDOWS_SSH}"
    if [[ -n "$output" ]]; then
      echo "Windows SSH detail: $(printf '%s\n' "$output" | head -1)"
    fi
  fi
}

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
print_windows_agent_status

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
