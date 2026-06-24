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
select_latest_import="no"
expected_id=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --latest-import)
      select_latest_import="yes"
      shift
      ;;
    --expected-id)
      if [[ $# -lt 2 ]]; then
        echo "open-windows-receive-folder.sh: --expected-id requires a value" >&2
        exit 2
      fi
      expected_id="$2"
      shift 2
      ;;
    *)
      echo "usage: open-windows-receive-folder.sh [--latest-import] [--expected-id <id>]" >&2
      exit 2
      ;;
  esac
done

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
select_latest_import_literal="$(ps_single_quoted "$select_latest_import")"
expected_id_literal="$(ps_single_quoted "$expected_id")"
read -r -d '' script <<POWERSHELL || true
\$ErrorActionPreference = "Stop"
\$ProgressPreference = "SilentlyContinue"
\$dir = [Environment]::ExpandEnvironmentVariables(${transfer_dir_literal})
\$selectLatestImport = (${select_latest_import_literal} -eq "yes")
\$expectedId = ${expected_id_literal}
if ([string]::IsNullOrWhiteSpace(\$dir)) {
  \$dir = Join-Path \$env:USERPROFILE "Downloads\\Moonlight Companion"
}
New-Item -ItemType Directory -Force -Path \$dir | Out-Null
\$targetPath = \$dir
\$selectedLatestImport = \$false

if (\$selectLatestImport) {
  \$statePath = Join-Path (Join-Path \$env:USERPROFILE ".moonlight-clipboard-sync") "mac-to-windows-import-state.txt"
  if (Test-Path -LiteralPath \$statePath) {
    \$state = @{}
    Get-Content -LiteralPath \$statePath -Encoding UTF8 | ForEach-Object {
      \$index = \$_.IndexOf("=")
      if (\$index -gt 0) {
        \$key = \$_.Substring(0, \$index)
        \$value = \$_.Substring(\$index + 1).TrimEnd([char]13)
        \$state[\$key] = \$value
      }
    }
    \$importedCount = 0
    [void][int]::TryParse([string]\$state["imported_paths"], [ref]\$importedCount)
    \$stateId = [string]\$state["id"]
    \$candidate = [string]\$state["imported_path_1"]
    \$idMatches = [string]::IsNullOrWhiteSpace(\$expectedId) -or \$stateId -eq \$expectedId
    if (\$idMatches -and \$importedCount -eq 1 -and -not [string]::IsNullOrWhiteSpace(\$candidate) -and (Test-Path -LiteralPath \$candidate)) {
      \$targetPath = \$candidate
      \$selectedLatestImport = \$true
    }
  }
}

\$taskName = "MoonlightCompanionOpenReceiveFolder"
Unregister-ScheduledTask -TaskName \$taskName -Confirm:\$false -ErrorAction SilentlyContinue | Out-Null
\$argument = if (\$selectedLatestImport) { ('/select,"{0}"' -f \$targetPath) } else { ('"{0}"' -f \$targetPath) }
\$action = New-ScheduledTaskAction -Execute "explorer.exe" -Argument \$argument
\$principal = New-ScheduledTaskPrincipal -UserId \$env:USERNAME -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName \$taskName -Action \$action -Principal \$principal -Force | Out-Null
Start-ScheduledTask -TaskName \$taskName
Start-Sleep -Milliseconds 800
Unregister-ScheduledTask -TaskName \$taskName -Confirm:\$false -ErrorAction SilentlyContinue | Out-Null
if (\$selectedLatestImport) {
  Write-Output "asked Windows to select the latest received item"
} else {
  Write-Output "asked Windows to open the receive folder"
}
POWERSHELL

encoded="$(printf '%s' "$script" | encode_powershell)"
ssh "${ssh_opts[@]}" "$WINDOWS_SSH" \
  "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand ${encoded}" >/dev/null

if [[ "$select_latest_import" == "yes" ]]; then
  printf 'asked Windows to open the latest receive result\n'
else
  printf 'asked Windows to open the receive folder\n'
fi
