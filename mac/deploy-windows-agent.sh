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
MOONLIGHT_CAPSLOCK_HANGUL="${MOONLIGHT_CAPSLOCK_HANGUL:-yes}"
MOONLIGHT_CAPSLOCK_HANGUL_TCP_PORT="${MOONLIGHT_CAPSLOCK_HANGUL_TCP_PORT:-47321}"
MOONLIGHT_CLIPBOARD_TCP="${MOONLIGHT_CLIPBOARD_TCP:-yes}"
MOONLIGHT_CLIPBOARD_MAC_TO_WINDOWS_TCP_PORT="${MOONLIGHT_CLIPBOARD_MAC_TO_WINDOWS_TCP_PORT:-47331}"
MOONLIGHT_CLIPBOARD_WINDOWS_TO_MAC_TCP_PORT="${MOONLIGHT_CLIPBOARD_WINDOWS_TO_MAC_TCP_PORT:-47332}"
MOONLIGHT_TRANSFER_WINDOWS_DIR="${MOONLIGHT_TRANSFER_WINDOWS_DIR:-%USERPROFILE%\\Downloads\\Moonlight Companion}"

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

restart_windows_agent() {
  local restart_tmp ps_script encoded
  restart_tmp="$(mktemp "${TMPDIR:-/tmp}/moonlight-companion-restart-agent.XXXXXX.ps1")"
  cat > "$restart_tmp" <<'POWERSHELL'
$ErrorActionPreference = "SilentlyContinue"
$ProgressPreference = "SilentlyContinue"
$dir = Join-Path $env:USERPROFILE ".moonlight-clipboard-sync"
$outPath = Join-Path $dir "_restart-windows-agent.out"
Set-Content -LiteralPath $outPath -Value "restart_started" -Encoding UTF8
$selfPid = $PID
$agentProcesses = @(Get-CimInstance Win32_Process | Where-Object {
  $_.ProcessId -ne $selfPid -and
  $_.CommandLine -like "*windows-clipboard-agent.ps1*" -and
  $_.CommandLine -notlike "*_restart-windows-agent.ps1*"
})
foreach ($agent in $agentProcesses) {
  try { Stop-Process -Id $agent.ProcessId -Force -ErrorAction SilentlyContinue } catch {}
}
Start-Sleep -Milliseconds 800
$vbs = Join-Path $dir "start-windows-clipboard-agent.vbs"
Start-Process -FilePath "wscript.exe" -ArgumentList ('"{0}"' -f $vbs) -WindowStyle Hidden
$agentCount = 0
for ($i = 0; $i -lt 20; $i++) {
  Start-Sleep -Milliseconds 500
  $agents = @(Get-CimInstance Win32_Process | Where-Object {
    $_.ProcessId -ne $selfPid -and
    $_.CommandLine -like "*windows-clipboard-agent.ps1*" -and
    $_.CommandLine -notlike "*_restart-windows-agent.ps1*"
  })
  $agentCount = $agents.Count
  if ($agentCount -ge 1) { break }
}
Add-Content -LiteralPath $outPath -Value ("agent_count={0}" -f $agentCount) -Encoding UTF8
POWERSHELL
  if ! scp "${scp_opts[@]}" "$restart_tmp" "${WINDOWS_SSH}:.moonlight-clipboard-sync/_restart-windows-agent.ps1" >/dev/null; then
    rm -f "$restart_tmp"
    return 1
  fi
  rm -f "$restart_tmp"

  read -r -d '' ps_script <<'POWERSHELL' || true
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
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
Remove-Item -LiteralPath $outPath -Force -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument ("-NoProfile -ExecutionPolicy Bypass -File `"{0}`"" -f $restartScript)
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Force | Out-Null
Start-ScheduledTask -TaskName $taskName
for ($i = 0; $i -lt 80; $i++) {
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
  if ($restartOutput -notmatch "agent_count=[1-9][0-9]*") {
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
  ssh "${ssh_opts[@]}" "$WINDOWS_SSH" "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encoded"
}

ssh "${ssh_opts[@]}" "$WINDOWS_SSH" "cmd.exe /c if not exist .moonlight-clipboard-sync mkdir .moonlight-clipboard-sync" >/dev/null
write_windows_agent_settings
scp "${scp_opts[@]}" "${repo_dir}/windows/windows-clipboard-agent.ps1" "${WINDOWS_SSH}:.moonlight-clipboard-sync/windows-clipboard-agent.ps1" >/dev/null
scp "${scp_opts[@]}" "${repo_dir}/windows/start-windows-clipboard-agent.cmd" "${WINDOWS_SSH}:.moonlight-clipboard-sync/start-windows-clipboard-agent.cmd" >/dev/null
scp "${scp_opts[@]}" "${repo_dir}/windows/start-windows-clipboard-agent.vbs" "${WINDOWS_SSH}:.moonlight-clipboard-sync/start-windows-clipboard-agent.vbs" >/dev/null
restart_windows_agent
