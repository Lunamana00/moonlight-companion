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
remote_dir=".moonlight-clipboard-sync"
expected_id=""
select_paths=()
timeout_ms="${MOONLIGHT_WINDOWS_CLIPBOARD_RESTORE_TIMEOUT_MS:-5000}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --expected-id)
      if [[ $# -lt 2 ]]; then
        echo "copy-windows-receive-to-clipboard.sh: --expected-id requires a value" >&2
        exit 2
      fi
      expected_id="$2"
      shift 2
      ;;
    --select-path|--path)
      if [[ $# -lt 2 ]]; then
        echo "copy-windows-receive-to-clipboard.sh: $1 requires a value" >&2
        exit 2
      fi
      select_paths+=("$2")
      shift 2
      ;;
    *)
      echo "usage: copy-windows-receive-to-clipboard.sh [--expected-id <id>] --select-path <path> [--select-path <path> ...]" >&2
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
scp_opts=("${ssh_opts[@]}")

ps_single_quoted() {
  local value="$1"
  value=${value//\'/\'\'}
  printf "'%s'" "$value"
}

ps_array_literal() {
  local value
  if [[ $# -eq 0 ]]; then
    printf '@()'
    return 0
  fi

  printf '@('
  local first="yes"
  for value in "$@"; do
    if [[ "$first" == "yes" ]]; then
      first="no"
    else
      printf ', '
    fi
    ps_single_quoted "$value"
  done
  printf ')'
}

encode_powershell() {
  iconv -f UTF-8 -t UTF-16LE | base64 | tr -d '\n'
}

request_id="gui-copy:${expected_id:-latest}:$(date +%s):$$:${RANDOM}"
request_id_literal="$(ps_single_quoted "$request_id")"
expected_id_literal="$(ps_single_quoted "$expected_id")"
paths_literal="$(ps_array_literal "${select_paths[@]}")"
timeout_literal="$(ps_single_quoted "$timeout_ms")"
selected_count="${#select_paths[@]}"

received_item_text() {
  if (( selected_count == 1 )); then
    printf 'received item'
  else
    printf 'received items'
  fi
}

received_item_unavailable_verb() {
  if (( selected_count == 1 )); then
    printf 'was'
  else
    printf 'were'
  fi
}

latest_received_text() {
  if (( selected_count == 1 )); then
    printf 'latest received item'
  else
    printf 'latest received items'
  fi
}

read -r -d '' script <<POWERSHELL || true
\$ErrorActionPreference = "Stop"
\$ProgressPreference = "SilentlyContinue"
\$remoteDir = Join-Path \$env:USERPROFILE ".moonlight-clipboard-sync"
\$requestPath = Join-Path \$remoteDir "direct-clipboard-request.txt"
\$responsePath = Join-Path \$remoteDir "direct-clipboard-response.txt"
\$requestId = ${request_id_literal}
\$expectedId = ${expected_id_literal}
\$paths = ${paths_literal}
\$timeoutMs = 5000
[void][int]::TryParse(${timeout_literal}, [ref]\$timeoutMs)
if (\$timeoutMs -lt 500) { \$timeoutMs = 500 }
if (\$timeoutMs -gt 30000) { \$timeoutMs = 30000 }

function Write-KeyValueState(\$path, [string[]]\$lines) {
  \$tmpPath = "\$path.tmp"
  Set-Content -LiteralPath \$tmpPath -Value \$lines -Encoding UTF8
  Move-Item -LiteralPath \$tmpPath -Destination \$path -Force
}

function Read-KeyValueState(\$path) {
  \$state = @{}
  if (-not (Test-Path -LiteralPath \$path)) { return \$state }
  Get-Content -LiteralPath \$path -Encoding UTF8 | ForEach-Object {
    \$index = \$_.IndexOf("=")
    if (\$index -gt 0) {
      \$key = \$_.Substring(0, \$index)
      \$value = \$_.Substring(\$index + 1).TrimEnd([char]13)
      \$state[\$key] = \$value
    }
  }
  return \$state
}

function ConvertTo-StateBase64([string]\$value) {
  if (\$null -eq \$value) { return "" }
  return [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes(\$value))
}

New-Item -ItemType Directory -Force -Path \$remoteDir | Out-Null
if (\$paths.Count -le 0) {
  Write-Output "MOONLIGHT_COPY_RESULT=no-paths"
  exit 0
}

\$validPaths = @()
foreach (\$path in \$paths) {
  if (-not [string]::IsNullOrWhiteSpace(\$path) -and (Test-Path -LiteralPath \$path)) {
    \$validPaths += \$path
  }
}

if (\$validPaths.Count -ne \$paths.Count) {
  if (\$validPaths.Count -gt 0) {
    Write-Output "MOONLIGHT_COPY_RESULT=partial-missing"
  } else {
    Write-Output "MOONLIGHT_COPY_RESULT=missing"
  }
  exit 0
}

Remove-Item -LiteralPath \$responsePath -Force -ErrorAction SilentlyContinue
\$lines = @(
  "id=\$requestId",
  "source_id=\$expectedId",
  "imported_paths=\$(\$validPaths.Count)"
)
for (\$i = 0; \$i -lt \$validPaths.Count; \$i++) {
  \$lines += "imported_path_\$(\$i + 1)=\$(\$validPaths[\$i])"
  \$lines += "imported_path_\$(\$i + 1)_b64=\$(ConvertTo-StateBase64 \$validPaths[\$i])"
}
Write-KeyValueState \$requestPath \$lines

\$deadline = (Get-Date).AddMilliseconds(\$timeoutMs)
while ((Get-Date) -lt \$deadline) {
  if (Test-Path -LiteralPath \$responsePath) {
    \$response = Read-KeyValueState \$responsePath
    if ([string]\$response["id"] -eq \$requestId) {
      if ([string]\$response["clipboard_ready"] -eq "yes") {
        Write-Output "MOONLIGHT_COPY_RESULT=ready"
        Write-Output ("MOONLIGHT_COPY_PATHS={0}" -f [string]\$response["imported_paths"])
        exit 0
      }
      Write-Output "MOONLIGHT_COPY_RESULT=unavailable"
      Write-Output ("MOONLIGHT_COPY_REASON={0}" -f [string]\$response["reason"])
      exit 1
    }
  }
  Start-Sleep -Milliseconds 50
}

Remove-Item -LiteralPath \$requestPath -Force -ErrorAction SilentlyContinue
Write-Output "MOONLIGHT_COPY_RESULT=timeout"
exit 1
POWERSHELL

script_tmp="$(mktemp "${TMPDIR:-/tmp}/moonlight-copy-windows-receive.XXXXXX.ps1")"
remote_script="${remote_dir}/moonlight-copy-windows-receive-$$-$RANDOM.ps1"
remote_script_cmd="${remote_script//\//\\}"
cleanup_remote_script() {
  rm -f "$script_tmp"
  ssh "${ssh_opts[@]}" "$WINDOWS_SSH" \
    "cmd.exe /c del /Q \"${remote_script_cmd}\" 2>nul" >/dev/null 2>&1 || true
}
trap cleanup_remote_script EXIT

printf '\xef\xbb\xbf%s' "$script" > "$script_tmp"
ssh "${ssh_opts[@]}" "$WINDOWS_SSH" \
  "cmd.exe /c if not exist ${remote_dir} mkdir ${remote_dir}" >/dev/null
scp "${scp_opts[@]}" "$script_tmp" "${WINDOWS_SSH}:${remote_script}" >/dev/null
remote_status=0
remote_output="$(
  ssh "${ssh_opts[@]}" "$WINDOWS_SSH" \
    "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"${remote_script_cmd}\""
)" || remote_status=$?
copy_result="$(printf '%s\n' "$remote_output" | awk -F= '$1 == "MOONLIGHT_COPY_RESULT" {sub(/\r$/, "", $2); print $2; exit}')"

case "$copy_result" in
  ready)
    printf 'asked Windows to put the %s on the clipboard\n' "$(latest_received_text)"
    ;;
  missing)
    printf 'asked Windows to copy the %s; %s %s unavailable\n' "$(latest_received_text)" "$(received_item_text)" "$(received_item_unavailable_verb)"
    ;;
  partial-missing)
    printf 'asked Windows to copy the %s; some received items were unavailable\n' "$(latest_received_text)"
    ;;
  no-paths)
    printf 'asked Windows to copy the latest received item; latest receive state was unavailable\n'
    ;;
  timeout)
    printf 'Windows clipboard handoff timed out\n'
    exit 1
    ;;
  unavailable)
    reason="$(printf '%s\n' "$remote_output" | awk -F= '$1 == "MOONLIGHT_COPY_REASON" {sub(/\r$/, "", $2); print $2; exit}')"
    if [[ -n "$reason" ]]; then
      printf 'Windows clipboard handoff was unavailable: %s\n' "$reason"
    else
      printf 'Windows clipboard handoff was unavailable\n'
    fi
    exit 1
    ;;
  *)
    if [[ "$remote_status" != "0" && -n "$remote_output" ]]; then
      printf '%s\n' "$remote_output"
    else
      printf 'Windows clipboard handoff did not return a usable response\n'
    fi
    exit 1
    ;;
esac
