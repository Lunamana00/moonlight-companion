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
MOONLIGHT_DISPLAY_INDEX="${MOONLIGHT_DISPLAY_INDEX:-default}"
MOONLIGHT_DISPLAY_PLACEMENT_TIMEOUT_SECONDS="${MOONLIGHT_DISPLAY_PLACEMENT_TIMEOUT_SECONDS:-180}"
MOONLIGHT_VIDEO_CODEC="${MOONLIGHT_VIDEO_CODEC:-HEVC}"
MOONLIGHT_CAPTURE_SYSTEM_KEYS="${MOONLIGHT_CAPTURE_SYSTEM_KEYS:-always}"
MOONLIGHT_ABSOLUTE_MOUSE="${MOONLIGHT_ABSOLUTE_MOUSE:-yes}"
MOONLIGHT_QUIT_EXISTING="${MOONLIGHT_QUIT_EXISTING:-yes}"
MOONLIGHT_CAPSLOCK_HANGUL="${MOONLIGHT_CAPSLOCK_HANGUL:-yes}"
MOONLIGHT_SHORTCUT_REMAP="${MOONLIGHT_SHORTCUT_REMAP:-yes}"
MOONLIGHT_CAPSLOCK_HANGUL_TCP_PORT="${MOONLIGHT_CAPSLOCK_HANGUL_TCP_PORT:-47321}"
MOONLIGHT_CAPSLOCK_HANGUL_TCP_LOCAL_PORT="${MOONLIGHT_CAPSLOCK_HANGUL_TCP_LOCAL_PORT:-$MOONLIGHT_CAPSLOCK_HANGUL_TCP_PORT}"
MOONLIGHT_CLIPBOARD_TCP="${MOONLIGHT_CLIPBOARD_TCP:-yes}"
MOONLIGHT_CLIPBOARD_MAC_TO_WINDOWS_TCP_PORT="${MOONLIGHT_CLIPBOARD_MAC_TO_WINDOWS_TCP_PORT:-47331}"
MOONLIGHT_CLIPBOARD_MAC_TO_WINDOWS_TCP_LOCAL_PORT="${MOONLIGHT_CLIPBOARD_MAC_TO_WINDOWS_TCP_LOCAL_PORT:-$MOONLIGHT_CLIPBOARD_MAC_TO_WINDOWS_TCP_PORT}"
MOONLIGHT_CLIPBOARD_WINDOWS_TO_MAC_TCP_PORT="${MOONLIGHT_CLIPBOARD_WINDOWS_TO_MAC_TCP_PORT:-47332}"
MOONLIGHT_CLIPBOARD_WINDOWS_TO_MAC_TCP_LOCAL_PORT="${MOONLIGHT_CLIPBOARD_WINDOWS_TO_MAC_TCP_LOCAL_PORT:-$MOONLIGHT_CLIPBOARD_WINDOWS_TO_MAC_TCP_PORT}"
MOONLIGHT_CLIPBOARD_MAX_BYTES="${MOONLIGHT_CLIPBOARD_MAX_BYTES:-52428800}"
MOONLIGHT_TRANSFER_MAC_DIR="${MOONLIGHT_TRANSFER_MAC_DIR:-${HOME}/Downloads/Moonlight Companion}"
MOONLIGHT_TRANSFER_WINDOWS_DIR="${MOONLIGHT_TRANSFER_WINDOWS_DIR:-%USERPROFILE%\\Downloads\\Moonlight Companion}"
MOONLIGHT_TRANSFER_NOTIFY="${MOONLIGHT_TRANSFER_NOTIFY:-yes}"
MOONLIGHT_TRANSFER_REVEAL_MAC_DIR="${MOONLIGHT_TRANSFER_REVEAL_MAC_DIR:-no}"

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

normalize_yes_no() {
  case "${1:-}" in
    1|[Yy]|[Yy][Ee][Ss]|[Tt][Rr][Uu][Ee]|[Oo][Nn])
      printf 'yes\n'
      ;;
    *)
      printf 'no\n'
      ;;
  esac
}

write_windows_agent_settings() {
  local capslock_hangul clipboard_tcp settings_tmp
  capslock_hangul="$(normalize_yes_no "$MOONLIGHT_CAPSLOCK_HANGUL")"
  clipboard_tcp="$(normalize_yes_no "$MOONLIGHT_CLIPBOARD_TCP")"
  settings_tmp="$(mktemp "${TMPDIR:-/tmp}/moonlight-companion-windows-settings.XXXXXX")"

  {
    printf '$MoonlightCapsLockHangul = "%s"\n' "$capslock_hangul"
    printf '$MoonlightCapsLockHangulTcpPort = "%s"\n' "$MOONLIGHT_CAPSLOCK_HANGUL_TCP_PORT"
    printf '$MoonlightClipboardTcp = "%s"\n' "$clipboard_tcp"
    printf '$MoonlightClipboardMacToWindowsTcpPort = "%s"\n' "$MOONLIGHT_CLIPBOARD_MAC_TO_WINDOWS_TCP_PORT"
    printf '$MoonlightClipboardWindowsToMacTcpPort = "%s"\n' "$MOONLIGHT_CLIPBOARD_WINDOWS_TO_MAC_TCP_PORT"
    printf '$MoonlightTransferWindowsDir = "%s"\n' "$MOONLIGHT_TRANSFER_WINDOWS_DIR"
  } > "$settings_tmp"
  if ! scp "${scp_opts[@]}" "$settings_tmp" "${WINDOWS_SSH}:.moonlight-clipboard-sync/windows-agent-settings.ps1"; then
    rm -f "$settings_tmp"
    return 1
  fi

  rm -f "$settings_tmp"
}

deploy_windows_agent() {
  log "deploying Windows clipboard agent to ${WINDOWS_SSH}"

  ssh "${ssh_opts[@]}" "$WINDOWS_SSH" "cmd.exe /c if not exist .moonlight-clipboard-sync mkdir .moonlight-clipboard-sync"
  write_windows_agent_settings
  scp "${scp_opts[@]}" "${repo_dir}/windows/windows-clipboard-agent.ps1" "${WINDOWS_SSH}:.moonlight-clipboard-sync/windows-clipboard-agent.ps1"
  scp "${scp_opts[@]}" "${repo_dir}/windows/start-windows-clipboard-agent.cmd" "${WINDOWS_SSH}:.moonlight-clipboard-sync/start-windows-clipboard-agent.cmd"
  scp "${scp_opts[@]}" "${repo_dir}/windows/start-windows-clipboard-agent.vbs" "${WINDOWS_SSH}:.moonlight-clipboard-sync/start-windows-clipboard-agent.vbs"

  local ps_script encoded
  read -r -d '' ps_script <<'POWERSHELL' || true
$ErrorActionPreference = "Stop"
$dir = Join-Path $env:USERPROFILE ".moonlight-clipboard-sync"
$vbs = Join-Path $dir "start-windows-clipboard-agent.vbs"
$startup = [Environment]::GetFolderPath("Startup")
if ($startup) {
  Remove-Item -Force -ErrorAction SilentlyContinue -Path (Join-Path $startup "Moonlight Clipboard Sync.vbs")
  Copy-Item -Force -Path $vbs -Destination (Join-Path $startup "Moonlight Clipboard Companion.vbs")
}

$taskName = "MoonlightCompanionRestartAgent"
$restartScript = Join-Path $dir "_restart-windows-agent.ps1"
$outPath = Join-Path $dir "_restart-windows-agent.out"
$restartBody = @'
$ErrorActionPreference = "SilentlyContinue"
$ProgressPreference = "SilentlyContinue"
$dir = Join-Path $env:USERPROFILE ".moonlight-clipboard-sync"
$outPath = Join-Path $dir "_restart-windows-agent.out"
Set-Content -LiteralPath $outPath -Value "restart_started" -Encoding UTF8
Get-CimInstance Win32_Process |
  Where-Object { $_.CommandLine -like "*windows-clipboard-agent.ps1*" -and $_.CommandLine -notlike "*_restart-windows-agent.ps1*" } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
Start-Sleep -Milliseconds 800
$vbs = Join-Path $dir "start-windows-clipboard-agent.vbs"
Start-Process -FilePath "wscript.exe" -ArgumentList ('"{0}"' -f $vbs) -WindowStyle Hidden
Start-Sleep -Seconds 3
$agents = @(Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like "*windows-clipboard-agent.ps1*" })
Add-Content -LiteralPath $outPath -Value ("agent_count={0}" -f $agents.Count) -Encoding UTF8
'@
Set-Content -LiteralPath $restartScript -Value $restartBody -Encoding UTF8
Remove-Item -LiteralPath $outPath -Force -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument ("-NoProfile -ExecutionPolicy Bypass -File `"{0}`"" -f $restartScript)
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Force | Out-Null
Start-ScheduledTask -TaskName $taskName
for ($i = 0; $i -lt 30; $i++) {
  if (Test-Path -LiteralPath $outPath) {
    $restartOutput = Get-Content -LiteralPath $outPath -Raw
    if ($restartOutput -match "agent_count=") {
      break
    }
  }
  Start-Sleep -Milliseconds 500
}
if (Test-Path -LiteralPath $outPath) {
  $restartOutput = Get-Content -LiteralPath $outPath -Raw
  if ($restartOutput -notmatch "agent_count=1") {
    throw "Windows agent restart failed: $restartOutput"
  }
} else {
  throw "Windows agent restart did not produce output"
}
Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
Remove-Item -LiteralPath $restartScript, $outPath -Force -ErrorAction SilentlyContinue

Write-Output "windows-agent-ready"
$global:LASTEXITCODE = 0
exit 0
POWERSHELL
  encoded="$(printf '%s' "$ps_script" | iconv -f UTF-8 -t UTF-16LE | base64 | tr -d '\n')"
  ssh "${ssh_opts[@]}" "$WINDOWS_SSH" "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encoded" >/dev/null 2>&1
}

start_mac_clipboard_sync() {
  log "starting Mac clipboard sync"
  MOONLIGHT_CLIPBOARD_MAX_BYTES="$MOONLIGHT_CLIPBOARD_MAX_BYTES" \
    MOONLIGHT_CLIPBOARD_TCP="$MOONLIGHT_CLIPBOARD_TCP" \
    MOONLIGHT_CLIPBOARD_MAC_TO_WINDOWS_TCP_PORT="$MOONLIGHT_CLIPBOARD_MAC_TO_WINDOWS_TCP_PORT" \
    MOONLIGHT_CLIPBOARD_MAC_TO_WINDOWS_TCP_LOCAL_PORT="$MOONLIGHT_CLIPBOARD_MAC_TO_WINDOWS_TCP_LOCAL_PORT" \
    MOONLIGHT_CLIPBOARD_WINDOWS_TO_MAC_TCP_PORT="$MOONLIGHT_CLIPBOARD_WINDOWS_TO_MAC_TCP_PORT" \
    MOONLIGHT_CLIPBOARD_WINDOWS_TO_MAC_TCP_LOCAL_PORT="$MOONLIGHT_CLIPBOARD_WINDOWS_TO_MAC_TCP_LOCAL_PORT" \
    MOONLIGHT_TRANSFER_MAC_DIR="$MOONLIGHT_TRANSFER_MAC_DIR" \
    MOONLIGHT_TRANSFER_NOTIFY="$MOONLIGHT_TRANSFER_NOTIFY" \
    MOONLIGHT_TRANSFER_REVEAL_MAC_DIR="$MOONLIGHT_TRANSFER_REVEAL_MAC_DIR" \
    MOONLIGHT_SHORTCUT_REMAP="$MOONLIGHT_SHORTCUT_REMAP" \
    MOONLIGHT_CAPSLOCK_HANGUL_TCP_PORT="$MOONLIGHT_CAPSLOCK_HANGUL_TCP_PORT" \
    MOONLIGHT_CAPSLOCK_HANGUL_TCP_LOCAL_PORT="$MOONLIGHT_CAPSLOCK_HANGUL_TCP_LOCAL_PORT" \
    WINDOWS_SSH="$WINDOWS_SSH" \
    "${script_dir}/start-moonlight-clipboard-sync.sh" >> "$log_path" 2>&1
}

stop_moonlight() {
  log "stopping Moonlight"
  osascript -e 'tell application "Moonlight" to quit' >/dev/null 2>&1 || true
  sleep 0.8
  pkill -f "/Moonlight.app/Contents/MacOS/Moonlight .* stream " >/dev/null 2>&1 || true
}

position_moonlight_window() {
  if [[ "$MOONLIGHT_DISPLAY_INDEX" == "default" ]]; then
    log "display placement skipped: default display"
    return 0
  fi

  local timeout placement_status
  timeout="$MOONLIGHT_DISPLAY_PLACEMENT_TIMEOUT_SECONDS"
  if ! [[ "$timeout" =~ ^[0-9]+$ ]] || (( timeout < 1 )); then
    timeout="180"
  fi

  log "display placement requested: index=${MOONLIGHT_DISPLAY_INDEX}, mode=${MOONLIGHT_DISPLAY_MODE}, timeout=${timeout}s"
  set +e
  MOONLIGHT_DISPLAY_INDEX="$MOONLIGHT_DISPLAY_INDEX" \
    MOONLIGHT_DISPLAY_MODE="$MOONLIGHT_DISPLAY_MODE" \
    MOONLIGHT_DISPLAY_PLACEMENT_TIMEOUT_SECONDS="$timeout" \
    osascript -l JavaScript <<'JXA' 2>&1 | while IFS= read -r line; do
ObjC.import('AppKit')

const environment = $.NSProcessInfo.processInfo.environment

function envString(name, fallback) {
  const value = environment.objectForKey(name)
  return value ? ObjC.unwrap(value) : fallback
}

function output(message) {
  console.log(message)
}

function integer(value, fallback) {
  const parsed = Number.parseInt(value, 10)
  return Number.isFinite(parsed) ? parsed : fallback
}

function arrayString(value) {
  try {
    return value().join(',')
  } catch (error) {
    return `unavailable:${error.message}`
  }
}

const selected = envString('MOONLIGHT_DISPLAY_INDEX', 'default')
const mode = envString('MOONLIGHT_DISPLAY_MODE', 'unknown')
const timeoutSeconds = Math.max(1, integer(envString('MOONLIGHT_DISPLAY_PLACEMENT_TIMEOUT_SECONDS', '180'), 180))
const screenIndex = Number.parseInt(selected, 10)
if (!Number.isFinite(screenIndex) || screenIndex < 0) {
  throw new Error('invalid display index')
}

const screens = $.NSScreen.screens
output(`screen-count=${screens.count}`)
if (screenIndex >= screens.count) {
  throw new Error('display index not available')
}

const screen = screens.objectAtIndex(screenIndex)
const frame = screen.frame
const visible = screen.visibleFrame
const mainHeight = $.NSScreen.screens.objectAtIndex(0).frame.size.height
const useWholeScreen = mode === 'borderless' || mode === 'fullscreen'
const bounds = useWholeScreen ? frame : visible
const inset = useWholeScreen ? 0 : 24
const x = Math.round(bounds.origin.x + inset)
const y = Math.round(mainHeight - bounds.origin.y - bounds.size.height + inset)
const width = Math.max(960, Math.round(bounds.size.width - (inset * 2)))
const height = Math.max(540, Math.round(bounds.size.height - (inset * 2)))
const frameTarget = {
  x: Math.round(frame.origin.x),
  y: Math.round(mainHeight - frame.origin.y - frame.size.height),
  width: Math.round(frame.size.width),
  height: Math.round(frame.size.height)
}
const visibleTarget = {
  x: Math.round(visible.origin.x),
  y: Math.round(mainHeight - visible.origin.y - visible.size.height),
  width: Math.round(visible.size.width),
  height: Math.round(visible.size.height)
}
const systemEvents = Application('System Events')
const deadline = Date.now() + (timeoutSeconds * 1000)
let lastState = 'not-started'
let attempts = 0
let placed = false

output(`target index=${screenIndex} mode=${mode} position=${x},${y} size=${width},${height}`)

function closeTo(position, targetX, targetY) {
  return Math.abs(position[0] - targetX) <= 12 && Math.abs(position[1] - targetY) <= 12
}

function onTargetScreen(position) {
  return position[0] >= frameTarget.x - 12 &&
    position[0] <= frameTarget.x + frameTarget.width + 12 &&
    position[1] >= frameTarget.y - 12 &&
    position[1] <= frameTarget.y + frameTarget.height + 12
}

while (Date.now() < deadline) {
  attempts += 1
  const matches = systemEvents.processes.whose({ name: 'Moonlight' })()
  if (matches.length === 0) {
    if (lastState !== 'waiting-for-process') {
      output('waiting-for-process')
      lastState = 'waiting-for-process'
    }
    delay(0.5)
    continue
  }

  const process = matches[0]
  const windows = process.windows()
  if (windows.length === 0) {
    if (lastState !== 'waiting-for-window') {
      output(`process-found attempt=${attempts}`)
      output('waiting-for-window')
      lastState = 'waiting-for-window'
    }
    delay(0.5)
    continue
  }

  const window = windows[0]
  output(`window-found attempt=${attempts} count=${windows.length}`)
  output(`before position=${arrayString(() => window.position())} size=${arrayString(() => window.size())}`)
  try {
    Application('Moonlight').activate()
  } catch (error) {
    output(`activate-skipped=${error.message}`)
  }
  window.position = [x, y]
  delay(0.2)
  window.size = [width, height]
  delay(0.2)
  const afterPosition = window.position()
  const afterSize = window.size()
  output(`after position=${afterPosition.join(',')} size=${afterSize.join(',')}`)

  const positionMatched = closeTo(afterPosition, x, y) ||
    (useWholeScreen && closeTo(afterPosition, visibleTarget.x, visibleTarget.y)) ||
    (useWholeScreen && onTargetScreen(afterPosition))
  if (positionMatched) {
    placed = true
    output('success')
    if (useWholeScreen && !closeTo(afterPosition, x, y)) {
      output('position-note=window-was-placed-on-target-display-after-macos-adjustment')
    }
    if (mode === 'borderless' && (Math.abs(afterSize[0] - width) > 12 || Math.abs(afterSize[1] - height) > 12)) {
      output('size-note=borderless-window-size-was-controlled-by-moonlight')
    }
    break
  }

  output('retrying-after-position-mismatch')
  lastState = 'position-mismatch'
  delay(0.5)
}

if (!placed) {
  throw new Error(`window placement timed out after ${timeoutSeconds}s (${lastState})`)
}
JXA
    [[ -n "$line" ]] && log "display placement: $line"
  done
  placement_status="${PIPESTATUS[0]}"
  set -e

  if [[ $placement_status -ne 0 ]]; then
    log "display placement failed: status=${placement_status}"
  fi
}

launch_moonlight() {
  if [[ ! -d "$MOONLIGHT_APP" ]]; then
    echo "Moonlight.app not found at: $MOONLIGHT_APP" >&2
    exit 1
  fi

  if [[ "$MOONLIGHT_QUIT_EXISTING" == "yes" ]]; then
    stop_moonlight
  fi

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
  position_moonlight_window &
}

main() {
  export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

  case "${1:-start}" in
    start)
      ;;
    stop-moonlight)
      stop_moonlight
      exit 0
      ;;
    *)
      echo "usage: $0 [start|stop-moonlight]" >&2
      exit 2
      ;;
  esac

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
