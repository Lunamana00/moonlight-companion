#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_dir="$(cd "${script_dir}/.." && pwd)"
config="${MOONLIGHT_COMPANION_CONFIG:-${repo_dir}/config/moonlight-companion.conf}"
if [[ ! -f "$config" ]]; then
  config="${repo_dir}/config/moonlight-companion.conf.example"
fi

if [[ -f "$config" ]]; then
  # shellcheck source=/dev/null
  source "$config"
fi

WINDOWS_SSH="${WINDOWS_SSH:-moonlight-windows}"
MOONLIGHT_HOST="${MOONLIGHT_HOST:-100.x.y.z}"
MOONLIGHT_APP="${MOONLIGHT_APP:-/Applications/Moonlight.app}"
MOONLIGHT_STREAM_APP="${MOONLIGHT_STREAM_APP:-Desktop}"
MOONLIGHT_RESOLUTION="${MOONLIGHT_RESOLUTION:-3456x2234}"
MOONLIGHT_FPS="${MOONLIGHT_FPS:-60}"
MOONLIGHT_BITRATE="${MOONLIGHT_BITRATE:-60000}"
MOONLIGHT_DISPLAY_MODE="${MOONLIGHT_DISPLAY_MODE:-windowed}"
MOONLIGHT_VIDEO_CODEC="${MOONLIGHT_VIDEO_CODEC:-HEVC}"
MOONLIGHT_CAPTURE_SYSTEM_KEYS="${MOONLIGHT_CAPTURE_SYSTEM_KEYS:-always}"
MOONLIGHT_ABSOLUTE_MOUSE="${MOONLIGHT_ABSOLUTE_MOUSE:-yes}"
MOONLIGHT_QUIT_EXISTING="${MOONLIGHT_QUIT_EXISTING:-yes}"
MOONLIGHT_CLIPBOARD_MAX_BYTES="${MOONLIGHT_CLIPBOARD_MAX_BYTES:-52428800}"
MOONLIGHT_TEMP_MAIN_DISPLAY="${MOONLIGHT_TEMP_MAIN_DISPLAY:-no}"
MOONLIGHT_DISPLAYPLACER_BIN="${MOONLIGHT_DISPLAYPLACER_BIN:-displayplacer}"
MOONLIGHT_DISPLAYPLACER_LAUNCH_COMMAND="${MOONLIGHT_DISPLAYPLACER_LAUNCH_COMMAND:-}"
MOONLIGHT_DISPLAY_RESTORE_AFTER_LAUNCH="${MOONLIGHT_DISPLAY_RESTORE_AFTER_LAUNCH:-yes}"
MOONLIGHT_DISPLAY_RESTORE_DELAY_SECONDS="${MOONLIGHT_DISPLAY_RESTORE_DELAY_SECONDS:-7}"
MOONLIGHT_DISPLAY_SWITCH_SETTLE_SECONDS="${MOONLIGHT_DISPLAY_SWITCH_SETTLE_SECONDS:-1.5}"

log_dir="${HOME}/Library/Logs"
mkdir -p "$log_dir"
log_path="${log_dir}/moonlight-companion-launch.log"

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$log_path"
}

ssh_opts=(
  -q
  -o BatchMode=yes
  -o ConnectTimeout=7
  -o LogLevel=ERROR
  -o StrictHostKeyChecking=accept-new
)

scp_opts=("${ssh_opts[@]}")
display_restore_command=""

deploy_windows_agent() {
  log "deploying Windows clipboard agent to ${WINDOWS_SSH}"

  ssh "${ssh_opts[@]}" "$WINDOWS_SSH" "cmd.exe /c if not exist .moonlight-clipboard-sync mkdir .moonlight-clipboard-sync"
  scp "${scp_opts[@]}" "${repo_dir}/windows/windows-clipboard-agent.ps1" "${WINDOWS_SSH}:.moonlight-clipboard-sync/windows-clipboard-agent.ps1"
  scp "${scp_opts[@]}" "${repo_dir}/windows/start-windows-clipboard-agent.cmd" "${WINDOWS_SSH}:.moonlight-clipboard-sync/start-windows-clipboard-agent.cmd"
  scp "${scp_opts[@]}" "${repo_dir}/windows/start-windows-clipboard-agent.vbs" "${WINDOWS_SSH}:.moonlight-clipboard-sync/start-windows-clipboard-agent.vbs"

  local ps_script encoded
  ps_script='
$ErrorActionPreference = "Stop"
$dir = Join-Path $env:USERPROFILE ".moonlight-clipboard-sync"
$vbs = Join-Path $dir "start-windows-clipboard-agent.vbs"
$startup = [Environment]::GetFolderPath("Startup")
if ($startup) {
  Remove-Item -Force -ErrorAction SilentlyContinue -Path (Join-Path $startup "Moonlight Clipboard Sync.vbs")
  Copy-Item -Force -Path $vbs -Destination (Join-Path $startup "Moonlight Clipboard Companion.vbs")
}
Write-Output "windows-agent-ready"
$global:LASTEXITCODE = 0
exit 0
'
  encoded="$(printf '%s' "$ps_script" | iconv -f UTF-8 -t UTF-16LE | base64 | tr -d '\n')"
  ssh "${ssh_opts[@]}" "$WINDOWS_SSH" "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encoded" >/dev/null 2>&1
}

start_mac_clipboard_sync() {
  log "starting Mac clipboard sync"
  MOONLIGHT_CLIPBOARD_MAX_BYTES="$MOONLIGHT_CLIPBOARD_MAX_BYTES" \
    WINDOWS_SSH="$WINDOWS_SSH" \
    "${script_dir}/start-moonlight-clipboard-sync.sh" >> "$log_path" 2>&1
}

current_displayplacer_command() {
  "$MOONLIGHT_DISPLAYPLACER_BIN" list | awk '/^displayplacer / { print; exit }'
}

run_displayplacer_command() {
  local command="$1"

  if [[ -z "$command" ]]; then
    return 0
  fi

  if ! command -v "$MOONLIGHT_DISPLAYPLACER_BIN" >/dev/null 2>&1; then
    log "displayplacer command not found: ${MOONLIGHT_DISPLAYPLACER_BIN}"
    return 1
  fi

  log "running displayplacer command: ${command}"
  PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    bash -c "$command" >> "$log_path" 2>&1
}

prepare_launch_display_layout() {
  if [[ "$MOONLIGHT_TEMP_MAIN_DISPLAY" != "yes" ]]; then
    return 0
  fi

  if [[ -z "$MOONLIGHT_DISPLAYPLACER_LAUNCH_COMMAND" ]]; then
    log "temporary main display requested, but MOONLIGHT_DISPLAYPLACER_LAUNCH_COMMAND is empty"
    return 0
  fi

  if ! command -v "$MOONLIGHT_DISPLAYPLACER_BIN" >/dev/null 2>&1; then
    log "temporary main display skipped because ${MOONLIGHT_DISPLAYPLACER_BIN} is unavailable"
    return 0
  fi

  display_restore_command="$(current_displayplacer_command || true)"
  if [[ -n "$display_restore_command" ]]; then
    log "captured display restore command"
  else
    log "could not capture display restore command"
  fi

  run_displayplacer_command "$MOONLIGHT_DISPLAYPLACER_LAUNCH_COMMAND" || return 0
  sleep "$MOONLIGHT_DISPLAY_SWITCH_SETTLE_SECONDS"
}

restore_launch_display_layout() {
  if [[ "$MOONLIGHT_TEMP_MAIN_DISPLAY" != "yes" ]]; then
    return 0
  fi

  if [[ "$MOONLIGHT_DISPLAY_RESTORE_AFTER_LAUNCH" != "yes" ]]; then
    return 0
  fi

  if [[ -z "$display_restore_command" ]]; then
    log "display restore skipped because no restore command was captured"
    return 0
  fi

  sleep "$MOONLIGHT_DISPLAY_RESTORE_DELAY_SECONDS"
  run_displayplacer_command "$display_restore_command" || true
}

launch_moonlight() {
  if [[ ! -d "$MOONLIGHT_APP" ]]; then
    echo "Moonlight.app not found at: $MOONLIGHT_APP" >&2
    exit 1
  fi

  if [[ "$MOONLIGHT_QUIT_EXISTING" == "yes" ]]; then
    osascript -e 'tell application "Moonlight" to quit' >/dev/null 2>&1 || true
    sleep 0.8
    pkill -f "/Applications/Moonlight.app/Contents/MacOS/Moonlight .* stream " >/dev/null 2>&1 || true
  fi

  prepare_launch_display_layout

  args=(
    --resolution "$MOONLIGHT_RESOLUTION"
    --fps "$MOONLIGHT_FPS"
    --bitrate "$MOONLIGHT_BITRATE"
    --display-mode "$MOONLIGHT_DISPLAY_MODE"
    --capture-system-keys "$MOONLIGHT_CAPTURE_SYSTEM_KEYS"
    --video-codec "$MOONLIGHT_VIDEO_CODEC"
  )

  if [[ "$MOONLIGHT_ABSOLUTE_MOUSE" == "yes" ]]; then
    args+=(--absolute-mouse)
  fi

  args+=(stream "$MOONLIGHT_HOST" "$MOONLIGHT_STREAM_APP")

  log "launching Moonlight: ${args[*]}"
  open -na "$MOONLIGHT_APP" --args "${args[@]}"
  restore_launch_display_layout
}

main() {
  export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

  if ! ssh "${ssh_opts[@]}" "$WINDOWS_SSH" "cmd.exe /c echo ssh-ok" >/dev/null; then
    echo "Passwordless SSH to ${WINDOWS_SSH} failed. Run Setup Moonlight Clipboard SSH first." >&2
    exit 1
  fi

  deploy_windows_agent
  start_mac_clipboard_sync
  launch_moonlight
  log "ready"
}

main "$@"
