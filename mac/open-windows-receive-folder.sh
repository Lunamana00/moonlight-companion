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
remote_dir=".moonlight-clipboard-sync"
select_latest_import="no"
expected_id=""
select_paths=()
dry_run="$(printf '%s' "${MOONLIGHT_OPEN_WINDOWS_RECEIVE_DRY_RUN:-no}" | tr '[:upper:]' '[:lower:]')"
machine_output="$(printf '%s' "${MOONLIGHT_OPEN_MACHINE_OUTPUT:-no}" | tr '[:upper:]' '[:lower:]')"

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
    --select-path)
      if [[ $# -lt 2 ]]; then
        echo "open-windows-receive-folder.sh: --select-path requires a value" >&2
        exit 2
      fi
      select_paths+=("$2")
      shift 2
      ;;
    *)
      echo "usage: open-windows-receive-folder.sh [--latest-import] [--expected-id <id>] [--select-path <path> ...]" >&2
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

cleanup_stale_remote_scripts() {
  local cleanup_script encoded
  cleanup_script='$ErrorActionPreference = "SilentlyContinue"; $dir = Join-Path $env:USERPROFILE ".moonlight-clipboard-sync"; if (Test-Path -LiteralPath $dir) { $cutoff = (Get-Date).AddHours(-6); Get-ChildItem -LiteralPath $dir -File -Filter "moonlight-open-windows-receive-*.ps1" | Where-Object { $_.LastWriteTime -lt $cutoff } | Remove-Item -Force }'
  encoded="$(printf '%s' "$cleanup_script" | encode_powershell)"
  ssh "${ssh_opts[@]}" "$WINDOWS_SSH" \
    "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand ${encoded}" >/dev/null 2>&1 || true
}

transfer_dir_literal="$(ps_single_quoted "$MOONLIGHT_TRANSFER_WINDOWS_DIR")"
select_latest_import_literal="$(ps_single_quoted "$select_latest_import")"
expected_id_literal="$(ps_single_quoted "$expected_id")"
if ((${#select_paths[@]} > 0)); then
  select_paths_literal="$(ps_array_literal "${select_paths[@]}")"
else
  select_paths_literal="$(ps_array_literal)"
fi
dry_run_literal="$(ps_single_quoted "$dry_run")"
read -r -d '' script <<POWERSHELL || true
\$ErrorActionPreference = "Stop"
\$ProgressPreference = "SilentlyContinue"
\$dir = [Environment]::ExpandEnvironmentVariables(${transfer_dir_literal})
\$selectLatestImport = (${select_latest_import_literal} -eq "yes")
\$expectedId = ${expected_id_literal}
\$explicitPaths = ${select_paths_literal}
\$dryRun = (${dry_run_literal} -in @("1", "true", "yes", "on"))
if ([string]::IsNullOrWhiteSpace(\$dir)) {
  \$dir = Join-Path \$env:USERPROFILE "Downloads\\Moonlight Companion"
}
New-Item -ItemType Directory -Force -Path \$dir | Out-Null
\$targetPath = \$dir
\$selectedLatestImport = \$false
\$openResult = "folder"

function Decode-StateBase64([string]\$value) {
  if ([string]::IsNullOrWhiteSpace(\$value)) { return "" }
  try {
    return [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(\$value))
  } catch {
    return ""
  }
}

function ConvertTo-StateBase64([string]\$value) {
  if (\$null -eq \$value) { return "" }
  return [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes(\$value))
}

if (\$explicitPaths.Count -gt 0) {
  \$validPaths = @()
  foreach (\$path in \$explicitPaths) {
    if (-not [string]::IsNullOrWhiteSpace(\$path) -and (Test-Path -LiteralPath \$path)) {
      \$validPaths += \$path
    }
  }

  \$partialMissing = \$validPaths.Count -gt 0 -and \$validPaths.Count -lt \$explicitPaths.Count
  if (\$validPaths.Count -eq 1) {
    \$targetPath = \$validPaths[0]
    \$selectedLatestImport = \$true
    if (\$partialMissing) {
      \$openResult = "selected-explicit-partial-missing"
    } else {
      \$openResult = "selected-explicit"
    }
  } elseif (\$validPaths.Count -gt 1) {
    \$commonParent = Split-Path -Parent \$validPaths[0]
    foreach (\$path in \$validPaths) {
      \$parent = Split-Path -Parent \$path
      if ([string]::IsNullOrWhiteSpace(\$commonParent) -or \$parent -ne \$commonParent) {
        \$commonParent = ""
        break
      }
    }
    if (-not [string]::IsNullOrWhiteSpace(\$commonParent) -and (Test-Path -LiteralPath \$commonParent)) {
      \$targetPath = \$commonParent
      if (\$partialMissing) {
        \$openResult = "folder-explicit-common-parent-partial-missing"
      } else {
        \$openResult = "folder-explicit-common-parent"
      }
    } else {
      \$targetPath = \$dir
      if (\$partialMissing) {
        \$openResult = "folder-explicit-multi-parent-partial-missing"
      } else {
        \$openResult = "folder-explicit-multi-parent"
      }
    }
  } else {
    \$openResult = "folder-explicit-missing-item"
  }
} elseif (\$selectLatestImport) {
  \$openResult = "folder-no-state"
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
    \$candidate = Decode-StateBase64 ([string]\$state["imported_path_1_b64"])
    if ([string]::IsNullOrWhiteSpace(\$candidate)) {
      \$candidate = [string]\$state["imported_path_1"]
    }
    \$idMatches = [string]::IsNullOrWhiteSpace(\$expectedId) -or \$stateId -eq \$expectedId
    if (\$idMatches -and \$importedCount -eq 1 -and -not [string]::IsNullOrWhiteSpace(\$candidate) -and (Test-Path -LiteralPath \$candidate)) {
      \$targetPath = \$candidate
      \$selectedLatestImport = \$true
      \$openResult = "selected"
    } elseif (-not \$idMatches) {
      \$openResult = "folder-id-mismatch"
    } elseif (\$importedCount -ne 1) {
      \$openResult = "folder-multi-item"
    } elseif ([string]::IsNullOrWhiteSpace(\$candidate) -or -not (Test-Path -LiteralPath \$candidate)) {
      \$openResult = "folder-missing-item"
    } else {
      \$openResult = "folder"
    }
  }
}

if (-not \$dryRun) {
  \$taskName = "MoonlightCompanionOpenReceiveFolder"
  Unregister-ScheduledTask -TaskName \$taskName -Confirm:\$false -ErrorAction SilentlyContinue | Out-Null
  \$argument = if (\$selectedLatestImport) { ('/select,"{0}"' -f \$targetPath) } else { ('"{0}"' -f \$targetPath) }
  \$action = New-ScheduledTaskAction -Execute "explorer.exe" -Argument \$argument
  \$principal = New-ScheduledTaskPrincipal -UserId \$env:USERNAME -LogonType Interactive -RunLevel Limited
  Register-ScheduledTask -TaskName \$taskName -Action \$action -Principal \$principal -Force | Out-Null
  Start-ScheduledTask -TaskName \$taskName
  Start-Sleep -Milliseconds 800
  Unregister-ScheduledTask -TaskName \$taskName -Confirm:\$false -ErrorAction SilentlyContinue | Out-Null
}
Write-Output ("MOONLIGHT_OPEN_RESULT={0}" -f \$openResult)
if (\$null -ne \$validPaths -and \$validPaths.Count -gt 0) {
  for (\$i = 0; \$i -lt \$validPaths.Count; \$i++) {
    Write-Output ("MOONLIGHT_OPEN_PATH_{0}_B64={1}" -f (\$i + 1), (ConvertTo-StateBase64 \$validPaths[\$i]))
  }
}
POWERSHELL

script_tmp="$(mktemp "${TMPDIR:-/tmp}/moonlight-open-windows-receive.XXXXXX.ps1")"
remote_script="${remote_dir}/moonlight-open-windows-receive-$$-$RANDOM.ps1"
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
cleanup_stale_remote_scripts
scp "${scp_opts[@]}" "$script_tmp" "${WINDOWS_SSH}:${remote_script}" >/dev/null
remote_output="$(
  ssh "${ssh_opts[@]}" "$WINDOWS_SSH" \
    "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"${remote_script_cmd}\""
)"
open_result="$(printf '%s\n' "$remote_output" | awk -F= '$1 == "MOONLIGHT_OPEN_RESULT" {sub(/\r$/, "", $2); print $2; exit}')"

print_open_machine_paths() {
  case "$machine_output" in
    1|y|yes|true|on) ;;
    *) return 0 ;;
  esac
  printf '%s\n' "$remote_output" | awk '/^MOONLIGHT_OPEN_PATH_[0-9]+_B64=/ { sub(/\r$/, ""); print }'
}

case "$open_result" in
  selected-explicit)
    printf 'asked Windows to select the received item\n'
    print_open_machine_paths
    ;;
  selected-explicit-partial-missing)
    printf 'asked Windows to select the remaining received item; some received items were unavailable\n'
    print_open_machine_paths
    ;;
  selected)
    printf 'asked Windows to select the latest received item\n'
    print_open_machine_paths
    ;;
  folder-explicit-multi-item)
    printf 'asked Windows to open the receive folder for multiple received items\n'
    print_open_machine_paths
    ;;
  folder-explicit-common-parent)
    printf 'asked Windows to open the containing folder for multiple received items\n'
    print_open_machine_paths
    ;;
  folder-explicit-common-parent-partial-missing)
    printf 'asked Windows to open the containing folder for remaining received items; some received items were unavailable\n'
    print_open_machine_paths
    ;;
  folder-explicit-multi-parent)
    printf 'asked Windows to open the receive folder for multiple received items in different folders\n'
    print_open_machine_paths
    ;;
  folder-explicit-multi-parent-partial-missing)
    printf 'asked Windows to open the receive folder for remaining received items in different folders; some received items were unavailable\n'
    print_open_machine_paths
    ;;
  folder-explicit-missing-item)
    printf 'asked Windows to open the receive folder; received item was unavailable\n'
    ;;
  folder-explicit-partial-missing)
    printf 'asked Windows to open the receive folder; some received items were unavailable\n'
    print_open_machine_paths
    ;;
  folder-id-mismatch)
    printf 'asked Windows to open the receive folder; latest item did not match this transfer\n'
    ;;
  folder-multi-item)
    printf 'asked Windows to open the receive folder for multiple received items\n'
    ;;
  folder-missing-item)
    printf 'asked Windows to open the receive folder; latest received item was unavailable\n'
    ;;
  folder-no-state)
    printf 'asked Windows to open the receive folder; latest receive state was unavailable\n'
    ;;
  *)
    printf 'asked Windows to open the receive folder\n'
    ;;
esac
