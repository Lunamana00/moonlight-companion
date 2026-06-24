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
MOONLIGHT_TRANSFER_WINDOWS_DIR="${MOONLIGHT_TRANSFER_WINDOWS_DIR:-%USERPROFILE%\\Downloads\\Moonlight Companion}"

ssh_opts=(
  -q
  -o BatchMode=yes
  -o ConnectTimeout=7
  -o LogLevel=ERROR
  -o StrictHostKeyChecking=accept-new
)

ps_single_quoted() {
  local value="$1"
  value=${value//\'/\'\'}
  printf "'%s'" "$value"
}

encode_powershell() {
  iconv -f UTF-8 -t UTF-16LE | base64 | tr -d '\n'
}

transfer_dir_literal="$(ps_single_quoted "$MOONLIGHT_TRANSFER_WINDOWS_DIR")"
read -r -d '' script <<POWERSHELL || true
\$ErrorActionPreference = "Stop"
\$ProgressPreference = "SilentlyContinue"
\$dir = [Environment]::ExpandEnvironmentVariables(${transfer_dir_literal})
if ([string]::IsNullOrWhiteSpace(\$dir)) {
  \$dir = Join-Path \$env:USERPROFILE "Downloads\\Moonlight Companion"
}
New-Item -ItemType Directory -Force -Path \$dir | Out-Null

\$taskName = "MoonlightCompanionOpenReceiveFolder"
Unregister-ScheduledTask -TaskName \$taskName -Confirm:\$false -ErrorAction SilentlyContinue | Out-Null
\$argument = ('"{0}"' -f \$dir)
\$action = New-ScheduledTaskAction -Execute "explorer.exe" -Argument \$argument
\$principal = New-ScheduledTaskPrincipal -UserId \$env:USERNAME -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName \$taskName -Action \$action -Principal \$principal -Force | Out-Null
Start-ScheduledTask -TaskName \$taskName
Start-Sleep -Milliseconds 800
Unregister-ScheduledTask -TaskName \$taskName -Confirm:\$false -ErrorAction SilentlyContinue | Out-Null
Write-Output "windows-receive-folder-opened"
POWERSHELL

encoded="$(printf '%s' "$script" | encode_powershell)"
ssh "${ssh_opts[@]}" "$WINDOWS_SSH" \
  "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand ${encoded}" >/dev/null

printf 'asked Windows to open the receive folder\n'
