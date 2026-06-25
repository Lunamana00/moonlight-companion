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
MOONLIGHT_CLIPBOARD_TCP="${MOONLIGHT_CLIPBOARD_TCP:-yes}"
MOONLIGHT_CLIPBOARD_MAX_BYTES="${MOONLIGHT_CLIPBOARD_MAX_BYTES:-52428800}"
MOONLIGHT_CLIPBOARD_WINDOWS_TO_MAC_TCP_PORT="${MOONLIGHT_CLIPBOARD_WINDOWS_TO_MAC_TCP_PORT:-47332}"
MOONLIGHT_CLIPBOARD_WINDOWS_TO_MAC_TCP_LOCAL_PORT="${MOONLIGHT_CLIPBOARD_WINDOWS_TO_MAC_TCP_LOCAL_PORT:-$MOONLIGHT_CLIPBOARD_WINDOWS_TO_MAC_TCP_PORT}"
MOONLIGHT_TRANSFER_MAC_DIR="${MOONLIGHT_TRANSFER_MAC_DIR:-${HOME}/Downloads/Moonlight Companion}"
MOONLIGHT_TRANSFER_WINDOWS_DIR="${MOONLIGHT_TRANSFER_WINDOWS_DIR:-%USERPROFILE%\\Downloads\\Moonlight Companion}"

runtime_dir="${MOONLIGHT_CLIPBOARD_RUNTIME_DIR:-${HOME}/Library/Application Support/MoonlightClipboardSync}"
helper="${MOONLIGHT_CLIPBOARD_HELPER:-${runtime_dir}/moonclipctl}"
tcp_helper="${MOONLIGHT_CLIPBOARD_TCP_HELPER:-${runtime_dir}/mooncliptcp}"
tcp_state="${MOONLIGHT_CLIPBOARD_TCP_STATE:-${runtime_dir}/clipboard-tcp-windows-state.txt}"
mac_ignore_state="${MOONLIGHT_CLIPBOARD_MAC_IGNORE_STATE:-${runtime_dir}/clipboard-mac-ignore-state.txt}"
mac_suspend_state="${MOONLIGHT_CLIPBOARD_MAC_SUSPEND_STATE:-${runtime_dir}/clipboard-mac-suspend-state.txt}"
transfer_quiet_state="${MOONLIGHT_TRANSFER_QUIET_STATE:-${runtime_dir}/transfer-quiet-state.txt}"
source_helper="${script_dir}/moonclipctl.swift"
source_tcp_helper="${script_dir}/mooncliptcp.swift"
source_sync_script="${script_dir}/sync-moonlight-clipboard.sh"
deploy_agent="${script_dir}/deploy-windows-agent.sh"
start_services="${script_dir}/start-moonlight-clipboard-sync.sh"
clip_tcp_label="com.lunamana.moonlight-clipboard-tcp-receiver"
tcp_helper_rebuilt="no"

ssh_opts=(
  -q
  -o BatchMode=yes
  -o ConnectTimeout=5
  -o LogLevel=ERROR
  -o ServerAliveInterval=15
  -o ServerAliveCountMax=2
  -o StrictHostKeyChecking=accept-new
)

scp_opts=("${ssh_opts[@]}")

remote_dir=".moonlight-clipboard-sync"
remote_windows_zip="${remote_dir}/windows-to-mac.zip"
remote_windows_tmp="${remote_dir}/windows-to-mac.tmp.zip"
remote_windows_zip_cmd="${remote_dir}\\windows-to-mac.zip"
remote_windows_tmp_cmd="${remote_dir}\\windows-to-mac.tmp.zip"

expand_mac_path() {
  local value="$1"
  value="${value//'${HOME}'/$HOME}"
  value="${value//\$HOME/$HOME}"
  case "$value" in
    "~")
      value="$HOME"
      ;;
    "~/"*)
      value="${HOME}/${value#~/}"
      ;;
  esac
  printf '%s\n' "$value"
}

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

ps_single_quoted() {
  local value="$1"
  value=${value//\'/\'\'}
  printf "'%s'" "$value"
}

ensure_helpers() {
  mkdir -p "$runtime_dir"
  if [[ ! -x "$helper" || "$source_helper" -nt "$helper" ]]; then
    if ! command -v swiftc >/dev/null 2>&1; then
      echo "swiftc is required to build the macOS clipboard helper." >&2
      exit 1
    fi
    swiftc "$source_helper" -o "$helper"
  fi
  chmod 700 "$helper"

  if [[ ! -x "$tcp_helper" || "$source_tcp_helper" -nt "$tcp_helper" ]]; then
    if ! command -v swiftc >/dev/null 2>&1; then
      echo "swiftc is required to build the macOS clipboard TCP helper." >&2
      exit 1
    fi
    swiftc "$source_tcp_helper" -o "$tcp_helper"
    tcp_helper_rebuilt="yes"
  fi
  chmod 700 "$tcp_helper"
}

verify_mac_sync_temp_cleanup() {
  local temp_root stale_dir fresh_dir
  temp_root="${TMPDIR:-/tmp}"
  stale_dir="${temp_root%/}/moonlight-clipboard-sync.stale-self-test"
  fresh_dir="${temp_root%/}/moonlight-clipboard-sync.fresh-self-test"

  rm -rf "$stale_dir" "$fresh_dir"
  mkdir -p "$stale_dir" "$fresh_dir"
  touch -t 202401010101 "$stale_dir"
  if ! MOONLIGHT_CLIPBOARD_SYNC_CLEANUP_ONLY=yes "${script_dir}/sync-moonlight-clipboard.sh"; then
    rm -rf "$stale_dir" "$fresh_dir"
    echo "Mac clipboard sync temp cleanup helper failed." >&2
    return 1
  fi
  if [[ -e "$stale_dir" ]]; then
    rm -rf "$stale_dir" "$fresh_dir"
    echo "Mac clipboard sync did not remove a stale temp directory." >&2
    return 1
  fi
  if [[ ! -d "$fresh_dir" ]]; then
    rm -rf "$fresh_dir"
    echo "Mac clipboard sync removed a fresh temp directory unexpectedly." >&2
    return 1
  fi
  rm -rf "$fresh_dir"
}

zip_payload() {
  local payload_dir="$1"
  local zip_path="$2"
  rm -f "$zip_path"
  (
    cd "$payload_dir"
    /usr/bin/zip -qry "$zip_path" .
  )
}

write_test_png() {
  local path="$1"
  /usr/bin/base64 -D > "$path" <<'PNG'
iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII=
PNG
}

mac_file_sha256() {
  shasum -a 256 "$1" | awk '{print $1}'
}

windows_path_exists() {
  local relative_path="$1"
  local path_type="${2:-Any}"
  local script encoded transfer_dir_literal relative_literal path_type_literal
  transfer_dir_literal="$(ps_single_quoted "$MOONLIGHT_TRANSFER_WINDOWS_DIR")"
  relative_literal="$(ps_single_quoted "$relative_path")"
  path_type_literal="$(ps_single_quoted "$path_type")"
  script="\$ErrorActionPreference = 'Stop'; \$dir = [Environment]::ExpandEnvironmentVariables(${transfer_dir_literal}); \$relative = ${relative_literal} -replace '/', [System.IO.Path]::DirectorySeparatorChar; \$path = Join-Path \$dir \$relative; \$pathType = ${path_type_literal}; if (\$pathType -eq 'Any') { if (Test-Path -LiteralPath \$path) { exit 0 } else { exit 1 } } elseif (Test-Path -LiteralPath \$path -PathType \$pathType) { exit 0 } else { exit 1 }"
  encoded="$(printf '%s' "$script" | iconv -f UTF-8 -t UTF-16LE | base64 | tr -d '\n')"
  ssh "${ssh_opts[@]}" "$WINDOWS_SSH" \
    "powershell.exe -NoProfile -NonInteractive -EncodedCommand ${encoded}" >/dev/null 2>&1
}

windows_file_exists() {
  windows_path_exists "$1" "Leaf"
}

windows_file_sha256() {
  local relative_path="$1"
  local script encoded transfer_dir_literal relative_literal
  transfer_dir_literal="$(ps_single_quoted "$MOONLIGHT_TRANSFER_WINDOWS_DIR")"
  relative_literal="$(ps_single_quoted "$relative_path")"
  script="\$ErrorActionPreference = 'Stop'; \$ProgressPreference = 'SilentlyContinue'; \$dir = [Environment]::ExpandEnvironmentVariables(${transfer_dir_literal}); \$relative = ${relative_literal} -replace '/', [System.IO.Path]::DirectorySeparatorChar; \$path = Join-Path \$dir \$relative; if (-not (Test-Path -LiteralPath \$path -PathType Leaf)) { exit 1 }; (Get-FileHash -LiteralPath \$path -Algorithm SHA256).Hash.ToLowerInvariant()"
  encoded="$(printf '%s' "$script" | iconv -f UTF-8 -t UTF-16LE | base64 | tr -d '\n')"
  ssh "${ssh_opts[@]}" "$WINDOWS_SSH" \
    "powershell.exe -NoProfile -NonInteractive -EncodedCommand ${encoded}" 2>/dev/null | tr -d '\r'
}

cleanup_windows_self_test_files() {
  local script encoded transfer_dir_literal
  transfer_dir_literal="$(ps_single_quoted "$MOONLIGHT_TRANSFER_WINDOWS_DIR")"
  script="\$ErrorActionPreference = 'SilentlyContinue'; \$dir = [Environment]::ExpandEnvironmentVariables(${transfer_dir_literal}); if (Test-Path -LiteralPath \$dir) { Get-ChildItem -LiteralPath \$dir | Where-Object { \$_.Name -like 'moonlight-companion-transfer-test-*' } | Remove-Item -Recurse -Force }"
  encoded="$(printf '%s' "$script" | iconv -f UTF-8 -t UTF-16LE | base64 | tr -d '\n')"
  ssh "${ssh_opts[@]}" "$WINDOWS_SSH" \
    "powershell.exe -NoProfile -NonInteractive -EncodedCommand ${encoded}" >/dev/null 2>&1 || true
}

remove_windows_fallback_zip() {
  ssh "${ssh_opts[@]}" "$WINDOWS_SSH" \
    "cmd.exe /c del /Q \"${remote_windows_zip_cmd}\" \"${remote_windows_tmp_cmd}\" 2>nul" >/dev/null 2>&1 || true
}

windows_fallback_zip_exists() {
  ssh "${ssh_opts[@]}" "$WINDOWS_SSH" \
    "cmd.exe /c if exist \"${remote_windows_zip_cmd}\" (exit 0) else (exit 1)" >/dev/null 2>&1
}

sync_service_running() {
  pgrep -f "sync-moonlight-clipboard.sh" >/dev/null 2>&1
}

wait_for_windows_fallback_zip_absent() {
  local attempts="${1:-80}"
  local index
  for ((index = 0; index < attempts; index++)); do
    if ! windows_fallback_zip_exists; then
      return 0
    fi
    sleep 0.25
  done
  return 1
}

upload_windows_fallback_zip() {
  local zip_path="$1"
  ssh "${ssh_opts[@]}" "$WINDOWS_SSH" \
    "cmd.exe /c if not exist ${remote_dir} mkdir ${remote_dir}" >/dev/null
  scp "${scp_opts[@]}" "$zip_path" "${WINDOWS_SSH}:${remote_windows_tmp}" >/dev/null
  ssh "${ssh_opts[@]}" "$WINDOWS_SSH" \
    "cmd.exe /c move /Y \"${remote_windows_tmp_cmd}\" \"${remote_windows_zip_cmd}\" >nul"
}

verify_windows_agent_settings() {
  local expected_max expected_oversize script encoded output
  expected_max="${MOONLIGHT_CLIPBOARD_MAX_BYTES:-52428800}"
  expected_oversize="$(normalize_yes_no "${MOONLIGHT_TRANSFER_OVERSIZE_DIRECT:-yes}")"
  script="\$ErrorActionPreference = 'Stop'; \$dir = Join-Path \$env:USERPROFILE '.moonlight-clipboard-sync'; \$settings = Join-Path \$dir 'windows-agent-settings.ps1'; . \$settings; Write-Output ('max=' + [string]\$MoonlightClipboardMaxBytes); Write-Output ('oversize=' + [string]\$MoonlightTransferOversizeDirect); \$agent = Join-Path \$dir 'windows-clipboard-agent.ps1'; \$tokens = \$null; \$parseErrors = \$null; [System.Management.Automation.Language.Parser]::ParseFile(\$agent, [ref]\$tokens, [ref]\$parseErrors) | Out-Null; if (\$parseErrors.Count -gt 0) { foreach (\$parseError in \$parseErrors) { Write-Output ('parse_error=' + \$parseError.Message) }; exit 1 }; Write-Output 'agent_parse=ok'"
  encoded="$(printf '%s' "$script" | iconv -f UTF-8 -t UTF-16LE | base64 | tr -d '\n')"
  if ! output="$(
    ssh "${ssh_opts[@]}" "$WINDOWS_SSH" \
      "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand ${encoded}" 2>/dev/null | tr -d '\r'
  )"; then
    echo "Windows agent settings or script parse check failed." >&2
    printf '%s\n' "$output" >&2
    return 1
  fi
  if [[ "$output" != *"max=${expected_max}"* ||
        "$output" != *"oversize=${expected_oversize}"* ||
        "$output" != *"agent_parse=ok"* ]]; then
    echo "Windows agent settings or script parse output was incomplete." >&2
    printf '%s\n' "$output" >&2
    return 1
  fi
}

verify_windows_agent_file_drop_export_guard() {
  local script encoded output
  script="\$ErrorActionPreference = 'Stop'; \$dir = Join-Path \$env:USERPROFILE '.moonlight-clipboard-sync'; \$agent = Join-Path \$dir 'windows-clipboard-agent.ps1'; \$env:MOONLIGHT_AGENT_LOAD_ONLY = 'yes'; . \$agent; \$ErrorActionPreference = 'Stop'; \$root = Join-Path \$dir ('agent-export-guard-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory -Force -Path \$root | Out-Null; try { \$valid = Join-Path \$root 'valid.txt'; \$missing = Join-Path \$root 'missing.txt'; \$payload = Join-Path \$root 'broken-payload'; \$validPayload = Join-Path \$root 'valid-payload'; Set-Content -LiteralPath \$valid -Value 'valid windows file drop item' -Encoding UTF8; New-Item -ItemType Directory -Force -Path \$payload, \$validPayload | Out-Null; \$brokenResult = Export-FileDropPathsPayload \$payload @(\$valid, \$missing); if (\$null -ne \$brokenResult) { Write-Output 'broken_result_not_null'; exit 1 }; if (Test-Path -LiteralPath (Join-Path \$payload 'manifest.json')) { Write-Output 'broken_manifest_written'; exit 1 }; if (Test-Path -LiteralPath (Join-Path \$payload 'files')) { Write-Output 'broken_partial_files_left'; exit 1 }; \$validResult = Export-FileDropPathsPayload \$validPayload @(\$valid); if (\$null -eq \$validResult -or \$validResult.kind -ne 'files' -or @(\$validResult.files).Count -ne 1) { Write-Output 'valid_result_missing'; exit 1 }; Write-Output 'file_drop_export_guard=ok' } finally { Remove-Item -LiteralPath \$root -Recurse -Force -ErrorAction SilentlyContinue; Remove-Item Env:MOONLIGHT_AGENT_LOAD_ONLY -ErrorAction SilentlyContinue }"
  encoded="$(printf '%s' "$script" | iconv -f UTF-8 -t UTF-16LE | base64 | tr -d '\n')"
  if ! output="$(
    ssh "${ssh_opts[@]}" "$WINDOWS_SSH" \
      "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand ${encoded}" 2>/dev/null | tr -d '\r'
  )"; then
    echo "Windows agent file-drop export guard failed." >&2
    printf '%s\n' "$output" >&2
    return 1
  fi
  if [[ "$output" != *"file_drop_export_guard=ok"* ]]; then
    echo "Windows agent file-drop export guard output was incomplete." >&2
    printf '%s\n' "$output" >&2
    return 1
  fi
}

verify_windows_agent_file_import_guard() {
  local script encoded output
  script="\$ErrorActionPreference = 'Stop'; \$dir = Join-Path \$env:USERPROFILE '.moonlight-clipboard-sync'; \$agent = Join-Path \$dir 'windows-clipboard-agent.ps1'; \$env:MOONLIGHT_AGENT_LOAD_ONLY = 'yes'; . \$agent; \$ErrorActionPreference = 'Stop'; \$root = Join-Path \$dir ('agent-import-guard-' + [guid]::NewGuid().ToString('N')); \$receive = Join-Path \$root 'receive'; New-Item -ItemType Directory -Force -Path \$root, \$receive | Out-Null; try { \$fileA = Join-Path \$root 'partial-a.txt'; \$fileB = Join-Path \$root 'partial-b.txt'; \$payload = Join-Path \$root 'payload'; Set-Content -LiteralPath \$fileA -Value 'partial import first file' -Encoding UTF8; Set-Content -LiteralPath \$fileB -Value 'partial import second file' -Encoding UTF8; New-Item -ItemType Directory -Force -Path \$payload | Out-Null; \$manifest = Export-FileDropPathsPayload \$payload @(\$fileA, \$fileB); if (\$null -eq \$manifest) { Write-Output 'export_missing'; exit 1 }; Remove-Item -LiteralPath (Join-Path (Join-Path \$payload 'files') 'partial-b.txt') -Force; \$script:transferWindowsDir = \$receive; \$failed = \$false; try { Import-ClipboardPayload \$payload | Out-Null } catch { \$failed = \$true }; if (-not \$failed) { Write-Output 'broken_import_succeeded'; exit 1 }; if (Test-Path -LiteralPath (Join-Path \$receive 'partial-a.txt')) { Write-Output 'partial_file_left'; exit 1 }; if (Test-Path -LiteralPath (Join-Path \$receive 'partial-b.txt')) { Write-Output 'missing_file_left'; exit 1 }; if (@(Get-ChildItem -LiteralPath \$receive -Force -Directory -Filter '.moonlight-companion-import-*' -ErrorAction SilentlyContinue).Count -gt 0) { Write-Output 'staging_left'; exit 1 }; Write-Output 'file_import_guard=ok' } finally { Remove-Item -LiteralPath \$root -Recurse -Force -ErrorAction SilentlyContinue; Remove-Item Env:MOONLIGHT_AGENT_LOAD_ONLY -ErrorAction SilentlyContinue }"
  encoded="$(printf '%s' "$script" | iconv -f UTF-8 -t UTF-16LE | base64 | tr -d '\n')"
  if ! output="$(
    ssh "${ssh_opts[@]}" "$WINDOWS_SSH" \
      "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand ${encoded}" 2>/dev/null | tr -d '\r'
  )"; then
    echo "Windows agent file import guard failed." >&2
    printf '%s\n' "$output" >&2
    return 1
  fi
  if [[ "$output" != *"file_import_guard=ok"* ]]; then
    echo "Windows agent file import guard output was incomplete." >&2
    printf '%s\n' "$output" >&2
    return 1
  fi
}

verify_windows_agent_compress_cleanup() {
  local script encoded output
  script="$(cat <<'POWERSHELL'
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$dir = Join-Path $env:USERPROFILE '.moonlight-clipboard-sync'
$agent = Join-Path $dir 'windows-clipboard-agent.ps1'
$env:MOONLIGHT_AGENT_LOAD_ONLY = 'yes'
. $agent
$ErrorActionPreference = 'Stop'
$root = Join-Path $dir ('agent-compress-cleanup-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $root | Out-Null
try {
    $zip = Join-Path $root 'windows-to-mac.zip'
    $tmp = Join-Path $root 'windows-to-mac.tmp.zip'
    $payload = Join-Path $root 'payload'
    $missing = Join-Path $root 'missing-payload'
    New-Item -ItemType Directory -Force -Path $payload | Out-Null
    Set-Content -LiteralPath (Join-Path $payload 'item.txt') -Value 'compress cleanup payload' -Encoding UTF8
    Set-Content -LiteralPath $zip -Value 'existing fallback zip should stay until replacement is ready' -Encoding UTF8
    Set-Content -LiteralPath $tmp -Value 'stale tmp zip' -Encoding UTF8
    $failed = $false
    try {
        Compress-Payload $missing $zip $tmp
    } catch {
        $failed = $true
    }
    if (-not $failed) { Write-Output 'missing_payload_compress_succeeded'; exit 1 }
    if (Test-Path -LiteralPath $tmp) { Write-Output 'tmp_left_after_failure'; exit 1 }
    if (-not (Test-Path -LiteralPath $zip -PathType Leaf)) { Write-Output 'existing_zip_removed_on_failure'; exit 1 }
    Compress-Payload $payload $zip $tmp
    if (-not (Test-Path -LiteralPath $zip -PathType Leaf)) { Write-Output 'zip_missing_after_success'; exit 1 }
    if (Test-Path -LiteralPath $tmp) { Write-Output 'tmp_left_after_success'; exit 1 }
    Write-Output 'compress_cleanup=ok'
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item Env:MOONLIGHT_AGENT_LOAD_ONLY -ErrorAction SilentlyContinue
}
POWERSHELL
)"
  encoded="$(printf '%s' "$script" | iconv -f UTF-8 -t UTF-16LE | base64 | tr -d '\n')"
  if ! output="$(
    ssh "${ssh_opts[@]}" "$WINDOWS_SSH" \
      "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand ${encoded}" 2>/dev/null | tr -d '\r'
  )"; then
    echo "Windows agent compression cleanup guard failed." >&2
    printf '%s\n' "$output" >&2
    return 1
  fi
  if [[ "$output" != *"compress_cleanup=ok"* ]]; then
    echo "Windows agent compression cleanup guard output was incomplete." >&2
    printf '%s\n' "$output" >&2
    return 1
  fi
}

write_windows_file() {
  local file_name="$1"
  local content="$2"
  local script encoded transfer_dir_literal file_name_literal content_literal
  transfer_dir_literal="$(ps_single_quoted "$MOONLIGHT_TRANSFER_WINDOWS_DIR")"
  file_name_literal="$(ps_single_quoted "$file_name")"
  content_literal="$(ps_single_quoted "$content")"
  script="\$ErrorActionPreference = 'Stop'; \$ProgressPreference = 'SilentlyContinue'; \$dir = [Environment]::ExpandEnvironmentVariables(${transfer_dir_literal}); New-Item -ItemType Directory -Force -Path \$dir | Out-Null; Set-Content -LiteralPath (Join-Path \$dir ${file_name_literal}) -Value ${content_literal} -Encoding UTF8"
  encoded="$(printf '%s' "$script" | iconv -f UTF-8 -t UTF-16LE | base64 | tr -d '\n')"
  ssh "${ssh_opts[@]}" "$WINDOWS_SSH" \
    "powershell.exe -NoProfile -NonInteractive -EncodedCommand ${encoded}" >/dev/null
}

remove_windows_path() {
  local relative_path="$1"
  local script encoded transfer_dir_literal relative_literal
  transfer_dir_literal="$(ps_single_quoted "$MOONLIGHT_TRANSFER_WINDOWS_DIR")"
  relative_literal="$(ps_single_quoted "$relative_path")"
  script="\$ErrorActionPreference = 'SilentlyContinue'; \$dir = [Environment]::ExpandEnvironmentVariables(${transfer_dir_literal}); \$relative = ${relative_literal} -replace '/', [System.IO.Path]::DirectorySeparatorChar; \$path = Join-Path \$dir \$relative; if (Test-Path -LiteralPath \$path) { Remove-Item -LiteralPath \$path -Recurse -Force }"
  encoded="$(printf '%s' "$script" | iconv -f UTF-8 -t UTF-16LE | base64 | tr -d '\n')"
  ssh "${ssh_opts[@]}" "$WINDOWS_SSH" \
    "powershell.exe -NoProfile -NonInteractive -EncodedCommand ${encoded}" >/dev/null 2>&1 || true
}

remove_windows_file() {
  remove_windows_path "$1"
}

wait_for_windows_file() {
  local file_name="$1"
  for _ in {1..20}; do
    if windows_file_exists "$file_name"; then
      return 0
    fi
    sleep 0.25
  done
  return 1
}

wait_for_windows_path() {
  local relative_path="$1"
  local path_type="${2:-Any}"
  for _ in {1..20}; do
    if windows_path_exists "$relative_path" "$path_type"; then
      return 0
    fi
    sleep 0.25
  done
  return 1
}

windows_receive_staging_count() {
  local script encoded transfer_dir_literal
  transfer_dir_literal="$(ps_single_quoted "$MOONLIGHT_TRANSFER_WINDOWS_DIR")"
  script="\$ErrorActionPreference = 'Stop'; \$dir = [Environment]::ExpandEnvironmentVariables(${transfer_dir_literal}); if (-not (Test-Path -LiteralPath \$dir)) { Write-Output '0'; exit 0 }; Write-Output ([string]@(Get-ChildItem -LiteralPath \$dir -Force -Directory -Filter '.moonlight-companion-import-*' -ErrorAction SilentlyContinue).Count)"
  encoded="$(printf '%s' "$script" | iconv -f UTF-8 -t UTF-16LE | base64 | tr -d '\n')"
  ssh "${ssh_opts[@]}" "$WINDOWS_SSH" \
    "powershell.exe -NoProfile -NonInteractive -EncodedCommand ${encoded}" 2>/dev/null | tr -d '\r'
}

windows_direct_temp_count() {
  local script encoded
  script="\$ErrorActionPreference = 'Stop'; \$ProgressPreference = 'SilentlyContinue'; \$dir = Join-Path \$env:USERPROFILE '.moonlight-clipboard-sync'; \$paths = @((Join-Path \$dir 'direct-mac-payload'), (Join-Path \$dir 'mac-to-windows-direct.zip'), (Join-Path \$dir 'mac-to-windows-direct.zip.tmp'), (Join-Path \$dir 'mac-to-windows-direct.ps1')); \$count = 0; foreach (\$path in \$paths) { if (Test-Path -LiteralPath \$path) { \$count++ } }; Write-Output ([string]\$count)"
  encoded="$(printf '%s' "$script" | iconv -f UTF-8 -t UTF-16LE | base64 | tr -d '\n')"
  ssh "${ssh_opts[@]}" "$WINDOWS_SSH" \
    "powershell.exe -NoProfile -NonInteractive -EncodedCommand ${encoded}" 2>/dev/null | tr -d '\r'
}

remove_windows_direct_temp_artifacts() {
  local script encoded
  script="\$ErrorActionPreference = 'SilentlyContinue'; \$ProgressPreference = 'SilentlyContinue'; \$dir = Join-Path \$env:USERPROFILE '.moonlight-clipboard-sync'; Remove-Item -LiteralPath (Join-Path \$dir 'direct-mac-payload') -Recurse -Force; Remove-Item -LiteralPath (Join-Path \$dir 'mac-to-windows-direct.zip') -Force; Remove-Item -LiteralPath (Join-Path \$dir 'mac-to-windows-direct.zip.tmp') -Force; Remove-Item -LiteralPath (Join-Path \$dir 'mac-to-windows-direct.ps1') -Force"
  encoded="$(printf '%s' "$script" | iconv -f UTF-8 -t UTF-16LE | base64 | tr -d '\n')"
  ssh "${ssh_opts[@]}" "$WINDOWS_SSH" \
    "powershell.exe -NoProfile -NonInteractive -EncodedCommand ${encoded}" >/dev/null 2>&1 || true
}

write_stale_windows_mac_tmp_zip() {
  local script encoded
  script="\$ErrorActionPreference = 'Stop'; \$ProgressPreference = 'SilentlyContinue'; \$dir = Join-Path \$env:USERPROFILE '.moonlight-clipboard-sync'; New-Item -ItemType Directory -Force -Path \$dir | Out-Null; Set-Content -LiteralPath (Join-Path \$dir 'mac-to-windows.zip.tmp') -Value 'stale mac-to-windows tmp' -Encoding UTF8"
  encoded="$(printf '%s' "$script" | iconv -f UTF-8 -t UTF-16LE | base64 | tr -d '\n')"
  ssh "${ssh_opts[@]}" "$WINDOWS_SSH" \
    "powershell.exe -NoProfile -NonInteractive -EncodedCommand ${encoded}" >/dev/null
}

windows_mac_tmp_zip_exists() {
  ssh "${ssh_opts[@]}" "$WINDOWS_SSH" \
    "cmd.exe /c if exist \"${remote_dir}\\mac-to-windows.zip.tmp\" (exit 0) else (exit 1)" >/dev/null 2>&1
}

windows_mac_zip_exists() {
  ssh "${ssh_opts[@]}" "$WINDOWS_SSH" \
    "cmd.exe /c if exist \"${remote_dir}\\mac-to-windows.zip\" (exit 0) else (exit 1)" >/dev/null 2>&1
}

wait_for_windows_mac_zip_absent() {
  local attempts="${1:-80}"
  local index
  for ((index = 0; index < attempts; index++)); do
    if ! windows_mac_zip_exists; then
      return 0
    fi
    sleep 0.25
  done
  return 1
}

upload_windows_mac_zip() {
  local zip_path="$1"
  ssh "${ssh_opts[@]}" "$WINDOWS_SSH" \
    "cmd.exe /c if not exist ${remote_dir} mkdir ${remote_dir}" >/dev/null
  scp "${scp_opts[@]}" "$zip_path" "${WINDOWS_SSH}:${remote_dir}/mac-to-windows.zip.tmp" >/dev/null
  ssh "${ssh_opts[@]}" "$WINDOWS_SSH" \
    "cmd.exe /c move /Y \"${remote_dir}\\mac-to-windows.zip.tmp\" \"${remote_dir}\\mac-to-windows.zip\" >nul"
}

remove_windows_mac_upload_artifacts() {
  ssh "${ssh_opts[@]}" "$WINDOWS_SSH" \
    "cmd.exe /c del /Q \"${remote_dir}\\mac-to-windows.zip\" \"${remote_dir}\\mac-to-windows.zip.tmp\" 2>nul" >/dev/null 2>&1 || true
}

write_stale_windows_receive_opener_script() {
  local script encoded
  script="\$ErrorActionPreference = 'Stop'; \$ProgressPreference = 'SilentlyContinue'; \$dir = Join-Path \$env:USERPROFILE '.moonlight-clipboard-sync'; New-Item -ItemType Directory -Force -Path \$dir | Out-Null; \$path = Join-Path \$dir 'moonlight-open-windows-receive-stale-test.ps1'; Set-Content -LiteralPath \$path -Value 'stale opener script' -Encoding UTF8; (Get-Item -LiteralPath \$path).LastWriteTime = (Get-Date).AddHours(-12)"
  encoded="$(printf '%s' "$script" | iconv -f UTF-8 -t UTF-16LE | base64 | tr -d '\n')"
  ssh "${ssh_opts[@]}" "$WINDOWS_SSH" \
    "powershell.exe -NoProfile -NonInteractive -EncodedCommand ${encoded}" >/dev/null
}

windows_receive_opener_test_script_exists() {
  ssh "${ssh_opts[@]}" "$WINDOWS_SSH" \
    "cmd.exe /c if exist \"${remote_dir}\\moonlight-open-windows-receive-stale-test.ps1\" (exit 0) else (exit 1)" >/dev/null 2>&1
}

remove_windows_receive_opener_test_script() {
  ssh "${ssh_opts[@]}" "$WINDOWS_SSH" \
    "cmd.exe /c del /Q \"${remote_dir}\\moonlight-open-windows-receive-stale-test.ps1\" 2>nul" >/dev/null 2>&1 || true
}

create_windows_blocking_transfer_dir() {
  local script encoded
  script="\$ErrorActionPreference = 'Stop'; \$ProgressPreference = 'SilentlyContinue'; \$path = Join-Path \$env:TEMP ('moonlight-direct-blocker-' + [guid]::NewGuid().ToString('N')); Set-Content -LiteralPath \$path -Value 'moonlight direct transfer blocker' -Encoding UTF8; Write-Output \$path"
  encoded="$(printf '%s' "$script" | iconv -f UTF-8 -t UTF-16LE | base64 | tr -d '\n')"
  ssh "${ssh_opts[@]}" "$WINDOWS_SSH" \
    "powershell.exe -NoProfile -NonInteractive -EncodedCommand ${encoded}" 2>/dev/null | tr -d '\r'
}

remove_windows_absolute_path() {
  local path="$1"
  local script encoded path_literal
  path_literal="$(ps_single_quoted "$path")"
  script="\$ErrorActionPreference = 'SilentlyContinue'; \$path = ${path_literal}; if (Test-Path -LiteralPath \$path) { Remove-Item -LiteralPath \$path -Recurse -Force }"
  encoded="$(printf '%s' "$script" | iconv -f UTF-8 -t UTF-16LE | base64 | tr -d '\n')"
  ssh "${ssh_opts[@]}" "$WINDOWS_SSH" \
    "powershell.exe -NoProfile -NonInteractive -EncodedCommand ${encoded}" >/dev/null 2>&1 || true
}

assert_windows_receive_staging_absent() {
  local count
  count="$(windows_receive_staging_count)"
  if [[ "$count" != "0" ]]; then
    echo "Windows receive folder has leftover staging folders: ${count}" >&2
    return 1
  fi
}

assert_windows_path_absent() {
  local relative_path="$1"
  local path_type="${2:-Any}"
  if windows_path_exists "$relative_path" "$path_type"; then
    echo "Unexpected Windows receive-folder echo: ${relative_path}" >&2
    return 1
  fi
}

cleanup_mac_self_test_files() {
  local directory="$1"
  find "$directory" -maxdepth 1 \
    -name 'moonlight-companion-transfer-test-*' \
    -exec rm -rf {} + 2>/dev/null || true
}

wait_for_mac_file() {
  local directory="$1"
  local file_name="$2"
  local attempts="${3:-20}"
  local index
  for ((index = 0; index < attempts; index++)); do
    if [[ -f "${directory}/${file_name}" ]]; then
      return 0
    fi
    sleep 0.25
  done
  return 1
}

wait_for_mac_path() {
  local directory="$1"
  local relative_path="$2"
  local path_type="${3:-Any}"
  local attempts="${4:-20}"
  local full_path="${directory}/${relative_path}"
  local index
  for ((index = 0; index < attempts; index++)); do
    if [[ "$path_type" == "Directory" && -d "$full_path" ]]; then
      return 0
    fi
    if [[ "$path_type" == "File" && -f "$full_path" ]]; then
      return 0
    fi
    if [[ "$path_type" == "Any" && -e "$full_path" ]]; then
      return 0
    fi
    sleep 0.25
  done
  return 1
}

wait_for_mac_receive_state_id() {
  local expected_id="$1"
  local attempts="${2:-80}"
  local index windows_id normalized_id
  for ((index = 0; index < attempts; index++)); do
    if [[ -f "$tcp_state" ]]; then
      windows_id="$(meta_value "windows_id" "$tcp_state")"
      normalized_id="$(meta_value "normalized_id" "$tcp_state")"
      if [[ "$windows_id" == "$expected_id" || "$normalized_id" == "$expected_id" ]]; then
        return 0
      fi
    fi
    sleep 0.25
  done
  return 1
}

mac_transfer_services_ready() {
  /usr/bin/nc -z 127.0.0.1 "$MOONLIGHT_CLIPBOARD_WINDOWS_TO_MAC_TCP_LOCAL_PORT" >/dev/null 2>&1
}

mac_tcp_receiver_stale() {
  local pid started_at started_epoch helper_epoch
  pid="$(pgrep -f "mooncliptcp listen 127\\.0\\.0\\.1 ${MOONLIGHT_CLIPBOARD_WINDOWS_TO_MAC_TCP_LOCAL_PORT}" | head -n 1 || true)"
  [[ -n "$pid" && -x "$tcp_helper" ]] || return 1

  started_at="$(ps -p "$pid" -o lstart= | sed 's/^[[:space:]]*//')"
  started_epoch="$(date -j -f "%a %b %e %T %Y" "$started_at" "+%s" 2>/dev/null || printf '0')"
  helper_epoch="$(stat -f "%m" "$tcp_helper" 2>/dev/null || printf '0')"
  [[ "$helper_epoch" -gt "$started_epoch" ]]
}

mac_sync_service_stale() {
  local pid started_at started_epoch source_epoch
  pid="$(pgrep -f "sync-moonlight-clipboard.sh" | head -n 1 || true)"
  [[ -n "$pid" ]] || return 0

  started_at="$(ps -p "$pid" -o lstart= | sed 's/^[[:space:]]*//')"
  started_epoch="$(date -j -f "%a %b %e %T %Y" "$started_at" "+%s" 2>/dev/null || printf '0')"
  source_epoch="$(stat -f "%m" "$source_sync_script" 2>/dev/null || printf '0')"
  [[ "$source_epoch" -gt "$started_epoch" ]]
}

restart_mac_tcp_receiver() {
  launchctl kickstart -k "gui/$(id -u)/${clip_tcp_label}" >/dev/null 2>&1 || return 1
  for _ in {1..30}; do
    if mac_transfer_services_ready; then
      return 0
    fi
    sleep 0.2
  done
  return 1
}

refresh_mac_transfer_services() {
  MOONLIGHT_COMPANION_CONFIG="$config" "$start_services" >/dev/null
  if ! mac_transfer_services_ready; then
    echo "Mac transfer TCP receiver did not become ready." >&2
    exit 1
  fi
}

meta_value() {
  local key="$1"
  local path="$2"
  awk -F= -v key="$key" '$1 == key {print substr($0, length(key) + 2); exit}' "$path"
}

update_receive_state_normalized_id() {
  local restored_id="$1"
  local tmp_state="${tcp_state}.tmp"
  awk -F= -v restored_id="$restored_id" '
    BEGIN { updated = 0 }
    $1 == "normalized_id" {
      print "normalized_id=" restored_id
      updated = 1
      next
    }
    { print }
    END {
      if (!updated) {
        print "normalized_id=" restored_id
      }
    }
  ' "$tcp_state" > "$tmp_state"
  mv "$tmp_state" "$tcp_state"
}

clipboard_file_paths_from_meta() {
  local meta_path="$1"
  local count index path
  count="$(meta_value file_paths "$meta_path")"
  [[ "$count" =~ ^[0-9]+$ ]] || return 0
  for ((index = 1; index <= count; index++)); do
    path="$(meta_value "file_path_${index}" "$meta_path")"
    [[ -n "$path" ]] && printf '%s\n' "$path"
  done
}

write_mac_clipboard_ignore_id() {
  local payload_id="$1"
  [[ -n "$payload_id" ]] || return 0

  local state_dir tmp_state
  state_dir="$(dirname "$mac_ignore_state")"
  tmp_state="${mac_ignore_state}.tmp"
  mkdir -p "$state_dir"
  {
    printf 'id=%s\n' "$payload_id"
    printf 'reason=test-clipboard-restore\n'
  } > "$tmp_state"
  mv "$tmp_state" "$mac_ignore_state"
}

write_mac_clipboard_suspend_state() {
  local state_dir tmp_state
  state_dir="$(dirname "$mac_suspend_state")"
  tmp_state="${mac_suspend_state}.tmp"
  mkdir -p "$state_dir"
  {
    printf 'reason=file-transfer-test\n'
    printf 'pid=%s\n' "$$"
  } > "$tmp_state"
  mv "$tmp_state" "$mac_suspend_state"
}

write_transfer_quiet_state() {
  local state_dir tmp_state
  state_dir="$(dirname "$transfer_quiet_state")"
  tmp_state="${transfer_quiet_state}.tmp"
  mkdir -p "$state_dir"
  {
    printf 'reason=file-transfer-test\n'
    printf 'pid=%s\n' "$$"
  } > "$tmp_state"
  mv "$tmp_state" "$transfer_quiet_state"
}

save_clipboard_snapshot() {
  clipboard_snapshot_saved="no"
  clipboard_snapshot_payload="${tmp_dir}/clipboard-snapshot-payload"
  clipboard_snapshot_meta="${tmp_dir}/clipboard-snapshot-meta.txt"
  if "$helper" snapshot "$clipboard_snapshot_payload" > "$clipboard_snapshot_meta" 2>/dev/null; then
    clipboard_snapshot_saved="yes"
  fi
}

restore_clipboard_snapshot() {
  [[ "${clipboard_snapshot_saved:-no}" == "yes" ]] || return 0
  [[ -f "$clipboard_snapshot_meta" ]] || return 0

  local kind restore_payload snapshot_id
  kind="$(meta_value kind "$clipboard_snapshot_meta")"
  snapshot_id="$(meta_value id "$clipboard_snapshot_meta")"
  if [[ "$kind" == "files" ]]; then
    local paths=()
    while IFS= read -r path || [[ -n "$path" ]]; do
      [[ -n "$path" ]] && paths+=("$path")
    done < <(clipboard_file_paths_from_meta "$clipboard_snapshot_meta")
    ((${#paths[@]} > 0)) || return 0
    restore_payload="${tmp_dir}/clipboard-snapshot-restore-payload"
    write_mac_clipboard_ignore_id "$snapshot_id"
    if ! "$helper" set-files "$restore_payload" "${paths[@]}" >/dev/null 2>&1; then
      rm -f "$mac_ignore_state"
    fi
  else
    write_mac_clipboard_ignore_id "$snapshot_id"
    if ! env -u MOONLIGHT_TRANSFER_MAC_DIR "$helper" import "$clipboard_snapshot_payload" >/dev/null 2>&1; then
      rm -f "$mac_ignore_state"
    fi
  fi
}

collision_name() {
  local file_name="$1"
  local stem ext
  if [[ "$file_name" == *.* ]]; then
    stem="${file_name%.*}"
    ext=".${file_name##*.}"
  else
    stem="$file_name"
    ext=""
  fi
  printf '%s-2%s\n' "$stem" "$ext"
}

if [[ "$(tr '[:upper:]' '[:lower:]' <<<"$MOONLIGHT_CLIPBOARD_TCP")" != "yes" ]]; then
  echo "Clipboard TCP is disabled; enable MOONLIGHT_CLIPBOARD_TCP for the live transfer test." >&2
  exit 1
fi

ensure_helpers
verify_mac_sync_temp_cleanup

transfer_mac_dir="$(expand_mac_path "$MOONLIGHT_TRANSFER_MAC_DIR")"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/moonlight-transfer-test.XXXXXX")"

cleanup_self_test_artifacts() {
  restore_clipboard_snapshot
  rm -f "$mac_suspend_state"
  rm -f "$transfer_quiet_state"
  rm -rf "$tmp_dir"
  cleanup_mac_self_test_files "$transfer_mac_dir"
  remove_windows_fallback_zip
  remove_windows_mac_upload_artifacts
  remove_windows_receive_opener_test_script
  cleanup_windows_self_test_files
}

trap cleanup_self_test_artifacts EXIT

save_clipboard_snapshot
write_mac_clipboard_suspend_state
write_transfer_quiet_state

if [[ "${MOONLIGHT_TRANSFER_TEST_SKIP_AGENT_DEPLOY:-no}" != "yes" ]]; then
  echo "Refreshing Windows agent..."
  MOONLIGHT_COMPANION_CONFIG="$config" "$deploy_agent" >/dev/null
  verify_windows_agent_settings
  verify_windows_agent_file_drop_export_guard
  verify_windows_agent_file_import_guard
  verify_windows_agent_compress_cleanup
  echo "Windows agent ready."
fi

if [[ "${MOONLIGHT_TRANSFER_TEST_SKIP_SERVICE_START:-no}" != "yes" ]]; then
  if mac_sync_service_stale; then
    echo "Refreshing Mac transfer services..."
    refresh_mac_transfer_services
    echo "Mac transfer services ready."
  elif [[ "$tcp_helper_rebuilt" == "yes" ]] || mac_tcp_receiver_stale; then
    echo "Refreshing Mac transfer services..."
    if ! restart_mac_tcp_receiver; then
      refresh_mac_transfer_services
    fi
    if ! mac_transfer_services_ready; then
      echo "Mac transfer TCP receiver did not become ready." >&2
      exit 1
    fi
    echo "Mac transfer services ready."
  elif mac_transfer_services_ready; then
    echo "Mac transfer services ready."
  else
    echo "Starting Mac transfer services..."
    refresh_mac_transfer_services
    echo "Mac transfer services ready."
  fi
fi

mkdir -p "$transfer_mac_dir"
cleanup_mac_self_test_files "$transfer_mac_dir"
cleanup_windows_self_test_files

stamp="$(date -u +%Y%m%dT%H%M%SZ)-$$"

echo "Testing received file metadata..."
metadata_src="${tmp_dir}/moonlight-companion-transfer-test-receive-metadata-${stamp}.txt"
metadata_payload="${tmp_dir}/receive-metadata-payload"
metadata_out="${tmp_dir}/receive-metadata.txt"
metadata_name="$(basename "$metadata_src")"
metadata_collision_name="$(collision_name "$metadata_name")"
printf 'Moonlight Companion receive metadata test %s\n' "$stamp" > "$metadata_src"
printf 'existing Mac receive file %s\n' "$stamp" > "${transfer_mac_dir}/${metadata_name}"
MOONLIGHT_TRANSFER_MAC_DIR="$transfer_mac_dir" "$helper" export-paths "$metadata_payload" "$metadata_src" >/dev/null
MOONLIGHT_TRANSFER_MAC_DIR="$transfer_mac_dir" "$helper" import "$metadata_payload" > "$metadata_out"
metadata_path="$(meta_value "file_path_1" "$metadata_out")"
if [[ -z "$metadata_path" || ! -f "$metadata_path" || "$(basename "$metadata_path")" != "$metadata_collision_name" ]]; then
  echo "Windows -> Mac import did not report the collision-safe received file path." >&2
  exit 1
fi
rm -f "$metadata_path" "${transfer_mac_dir}/${metadata_name}"
echo "Received file metadata ok."

echo "Testing Windows -> Mac partial import rejection..."
partial_import_file_a="${tmp_dir}/moonlight-companion-transfer-test-partial-import-a-${stamp}.txt"
partial_import_file_b="${tmp_dir}/moonlight-companion-transfer-test-partial-import-b-${stamp}.txt"
partial_import_payload="${tmp_dir}/partial-import-payload"
partial_import_out="${tmp_dir}/partial-import.txt"
printf 'Moonlight Companion partial import first file %s\n' "$stamp" > "$partial_import_file_a"
printf 'Moonlight Companion partial import second file %s\n' "$stamp" > "$partial_import_file_b"
MOONLIGHT_TRANSFER_MAC_DIR="$transfer_mac_dir" "$helper" export-paths "$partial_import_payload" "$partial_import_file_a" "$partial_import_file_b" >/dev/null
rm -f "${partial_import_payload}/files/$(basename "$partial_import_file_b")"
if MOONLIGHT_TRANSFER_MAC_DIR="$transfer_mac_dir" "$helper" import "$partial_import_payload" > "$partial_import_out" 2>&1; then
  echo "Windows -> Mac partial import payload unexpectedly succeeded." >&2
  cat "$partial_import_out" >&2
  exit 1
fi
if [[ -e "${transfer_mac_dir}/$(basename "$partial_import_file_a")" ||
      -e "${transfer_mac_dir}/$(basename "$partial_import_file_b")" ]]; then
  echo "Windows -> Mac partial import left files in the Mac receive folder." >&2
  ls -la "$transfer_mac_dir" >&2
  exit 1
fi
if find "$transfer_mac_dir" -maxdepth 1 -name '.moonlight-companion-import-*' | grep -q .; then
  echo "Windows -> Mac partial import left a staging folder in the Mac receive folder." >&2
  find "$transfer_mac_dir" -maxdepth 1 -name '.moonlight-companion-import-*' >&2
  exit 1
fi
echo "Windows -> Mac partial import rejection ok."

echo "Testing helper set-files metadata id..."
helper_id_file_a="${tmp_dir}/helper-id-a/same-name-${stamp}.txt"
helper_id_file_b="${tmp_dir}/helper-id-b/same-name-${stamp}.txt"
helper_id_dir="${tmp_dir}/helper-id-folder-${stamp}"
mkdir -p "$(dirname "$helper_id_file_a")" "$(dirname "$helper_id_file_b")" "${helper_id_dir}/nested"
printf 'Moonlight Companion helper id A %s\n' "$stamp" > "$helper_id_file_a"
printf 'Moonlight Companion helper id B %s\n' "$stamp" > "$helper_id_file_b"
printf 'Moonlight Companion helper id folder %s\n' "$stamp" > "${helper_id_dir}/nested/from-folder.txt"
helper_export_meta="${tmp_dir}/helper-id-export-meta.txt"
helper_set_meta="${tmp_dir}/helper-id-set-meta.txt"
helper_snapshot_meta="${tmp_dir}/helper-id-snapshot-meta.txt"
helper_set_payload="${tmp_dir}/helper-id-set-payload"
helper_snapshot_payload="${tmp_dir}/helper-id-snapshot-payload"
"$helper" export-paths "${tmp_dir}/helper-id-export-payload" "$helper_id_file_a" "$helper_id_file_b" "$helper_id_dir" > "$helper_export_meta"
"$helper" set-files "$helper_set_payload" "$helper_id_file_a" "$helper_id_file_b" "$helper_id_dir" > "$helper_set_meta"
if [[ "$(meta_value id "$helper_set_meta")" != "$(meta_value id "$helper_export_meta")" ]]; then
  echo "Helper set-files metadata-only id did not match export-paths id." >&2
  cat "$helper_export_meta" >&2
  cat "$helper_set_meta" >&2
  exit 1
fi
if [[ -e "${helper_set_payload}/files" ]]; then
  echo "Helper set-files copied a Windows-safe test payload instead of using metadata-only id calculation." >&2
  exit 1
fi
"$helper" snapshot "$helper_snapshot_payload" > "$helper_snapshot_meta"
if [[ "$(meta_value id "$helper_snapshot_meta")" != "$(meta_value id "$helper_export_meta")" ]]; then
  echo "Helper snapshot metadata-only id did not match export-paths id." >&2
  cat "$helper_export_meta" >&2
  cat "$helper_snapshot_meta" >&2
  exit 1
fi
if [[ -e "${helper_snapshot_payload}/files" ]]; then
  echo "Helper snapshot copied a Windows-safe clipboard payload instead of using metadata-only id calculation." >&2
  exit 1
fi
echo "Helper set-files metadata id ok."

echo "Testing helper empty clipboard snapshot..."
empty_payload="${tmp_dir}/empty-clipboard-payload"
empty_snapshot_payload="${tmp_dir}/empty-clipboard-snapshot-payload"
empty_snapshot_meta="${tmp_dir}/empty-clipboard-snapshot-meta.txt"
mkdir -p "$empty_payload"
printf '{\n  "bytes" : 0,\n  "id" : "empty",\n  "kind" : "empty",\n  "origin" : "mac",\n  "version" : 2\n}\n' > "${empty_payload}/manifest.json"
"$helper" import "$empty_payload" >/dev/null
"$helper" snapshot "$empty_snapshot_payload" > "$empty_snapshot_meta"
if [[ "$(meta_value kind "$empty_snapshot_meta")" != "empty" || "$(meta_value id "$empty_snapshot_meta")" != "empty" ]]; then
  echo "Helper empty clipboard snapshot did not preserve the empty clipboard state." >&2
  cat "$empty_snapshot_meta" >&2
  exit 1
fi
echo "Helper empty clipboard snapshot ok."

echo "Testing helper URL pasteboard variants..."
url_variant_file="${tmp_dir}/moonlight-companion-transfer-test-url-pasteboard-${stamp}.txt"
url_variant_file_two="${tmp_dir}/moonlight-companion-transfer-test-url-pasteboard-two-${stamp}.txt"
url_variant_writer="${tmp_dir}/write-url-pasteboard.swift"
printf 'Moonlight Companion URL pasteboard variant test %s\n' "$stamp" > "$url_variant_file"
printf 'Moonlight Companion URL pasteboard variant second file %s\n' "$stamp" > "$url_variant_file_two"
cat > "$url_variant_writer" <<'SWIFT'
import AppKit
import Foundation

guard CommandLine.arguments.count >= 3 else {
    exit(2)
}

let rawArguments = Array(CommandLine.arguments.dropFirst())
let itemMode = rawArguments.first == "--items"
let pasteboardType = NSPasteboard.PasteboardType(rawArguments.last!)
let paths = itemMode ? rawArguments.dropFirst().dropLast() : rawArguments.dropLast()
let fileURLs = paths.map {
    URL(fileURLWithPath: $0).absoluteString
}
let items: [NSPasteboardItem]
if itemMode {
    items = fileURLs.map { fileURL in
        let item = NSPasteboardItem()
        item.setString(fileURL, forType: pasteboardType)
        return item
    }
} else {
    let item = NSPasteboardItem()
    item.setString(fileURLs.joined(separator: "\n"), forType: pasteboardType)
    items = [item]
}

let pasteboard = NSPasteboard.general
pasteboard.clearContents()
if !pasteboard.writeObjects(items) {
    exit(1)
}
SWIFT
for pasteboard_type in "public.url" "public.file-url"; do
  url_variant_payload="${tmp_dir}/url-pasteboard-${pasteboard_type}-payload"
  url_variant_meta="${tmp_dir}/url-pasteboard-${pasteboard_type}-meta.txt"
  swift "$url_variant_writer" "$url_variant_file" "$pasteboard_type"
  if ! "$helper" export "$url_variant_payload" > "$url_variant_meta"; then
    echo "Helper did not export a file clipboard from ${pasteboard_type}." >&2
    exit 1
  fi
  if [[ "$(meta_value kind "$url_variant_meta")" != "files" ||
        "$(meta_value file_name_1 "$url_variant_meta")" != "$(basename "$url_variant_file")" ]]; then
    echo "Helper did not recognize ${pasteboard_type} as a file URL clipboard." >&2
    cat "$url_variant_meta" >&2
    exit 1
  fi
  url_variant_multi_payload="${tmp_dir}/url-pasteboard-${pasteboard_type}-multi-payload"
  url_variant_multi_meta="${tmp_dir}/url-pasteboard-${pasteboard_type}-multi-meta.txt"
  if [[ "$pasteboard_type" == "public.file-url" ]]; then
    swift "$url_variant_writer" --items "$url_variant_file" "$url_variant_file_two" "$pasteboard_type"
  else
    swift "$url_variant_writer" "$url_variant_file" "$url_variant_file_two" "$pasteboard_type"
  fi
  if ! "$helper" export "$url_variant_multi_payload" > "$url_variant_multi_meta"; then
    echo "Helper did not export a multi-file clipboard from ${pasteboard_type}." >&2
    exit 1
  fi
  if [[ "$(meta_value kind "$url_variant_multi_meta")" != "files" ||
        "$(meta_value file_paths "$url_variant_multi_meta")" != "2" ||
        "$(meta_value file_name_1 "$url_variant_multi_meta")" != "$(basename "$url_variant_file")" ||
        "$(meta_value file_name_2 "$url_variant_multi_meta")" != "$(basename "$url_variant_file_two")" ]]; then
    echo "Helper did not recognize newline-separated ${pasteboard_type} values as multiple file URLs." >&2
    cat "$url_variant_multi_meta" >&2
    exit 1
  fi
done
echo "Helper URL pasteboard variants ok."

echo "Testing Mac -> Windows unreadable source rejection..."
unreadable_file="${tmp_dir}/moonlight-companion-transfer-test-unreadable-${stamp}.txt"
unreadable_out="${tmp_dir}/mac-to-windows-unreadable-send.txt"
printf 'Moonlight Companion unreadable source test %s\n' "$stamp" > "$unreadable_file"
chmod 000 "$unreadable_file"
if "${script_dir}/send-files-to-windows.sh" "$unreadable_file" > "$unreadable_out" 2>&1; then
  chmod 600 "$unreadable_file"
  echo "Mac -> Windows unreadable source was not rejected before transfer." >&2
  cat "$unreadable_out" >&2
  exit 1
fi
chmod 600 "$unreadable_file"
if ! grep -Fq "cannot read dropped item:" "$unreadable_out" || ! grep -Fq "Check file permissions" "$unreadable_out"; then
  echo "Mac -> Windows unreadable source rejection did not explain the permission issue." >&2
  cat "$unreadable_out" >&2
  exit 1
fi
echo "Mac -> Windows unreadable source rejection ok."

echo "Testing Mac -> Windows oversized direct transfer..."
limit_file="${tmp_dir}/moonlight-companion-transfer-test-limit-${stamp}.txt"
limit_name="$(basename "$limit_file")"
limit_out="${tmp_dir}/mac-to-windows-limit-send.txt"
limit_state="${tmp_dir}/mac-to-windows-limit-state.txt"
limit_config="${tmp_dir}/moonlight-companion-limit.conf"
printf 'Moonlight Companion payload limit test %s\n' "$stamp" > "$limit_file"
printf 'source %q\nMOONLIGHT_CLIPBOARD_MAX_BYTES="1"\nMOONLIGHT_TRANSFER_OVERSIZE_DIRECT="yes"\n' "$config" > "$limit_config"
if ! MOONLIGHT_COMPANION_CONFIG="$limit_config" MOONLIGHT_TRANSFER_RESULT_STATE="$limit_state" "${script_dir}/send-files-to-windows.sh" "$limit_file" > "$limit_out" 2>&1; then
  echo "Mac -> Windows oversized payload did not use direct receive-folder transfer." >&2
  cat "$limit_out" >&2
  exit 1
fi
if ! grep -Fq "sent oversized" "$limit_out" || ! grep -Fq "not placed on the Windows clipboard" "$limit_out"; then
  echo "Mac -> Windows oversized payload did not explain the direct receive-folder fallback clearly." >&2
  cat "$limit_out" >&2
  exit 1
fi
if [[ ! -f "$limit_state" || "$(meta_value confirmation "$limit_state")" != "direct-ssh" || "$(meta_value clipboard_ready "$limit_state")" != "no" ]]; then
  echo "Mac -> Windows oversized payload did not write direct-transfer GUI state." >&2
  [[ -f "$limit_state" ]] && cat "$limit_state" >&2
  exit 1
fi
limit_state_path="$(meta_value imported_path_1 "$limit_state")"
if [[ "$limit_state_path" != *"$limit_name"* ]]; then
  echo "Mac -> Windows oversized payload did not write the imported Windows receive path to the GUI state." >&2
  [[ -f "$limit_state" ]] && cat "$limit_state" >&2
  exit 1
fi
if ! wait_for_windows_file "$limit_name"; then
  echo "Mac -> Windows oversized payload did not arrive in the Windows receive folder." >&2
  cat "$limit_out" >&2
  exit 1
fi
if ! assert_windows_receive_staging_absent; then
  echo "Mac -> Windows oversized direct transfer left a staging folder in the Windows receive folder." >&2
  exit 1
fi
direct_temp_count="$(windows_direct_temp_count)"
if [[ "$direct_temp_count" != "0" ]]; then
  remove_windows_direct_temp_artifacts
  echo "Mac -> Windows oversized direct transfer left direct temp artifacts on Windows." >&2
  echo "direct temp artifact count: ${direct_temp_count}" >&2
  cat "$limit_out" >&2
  exit 1
fi
remove_windows_file "$limit_name"
echo "Mac -> Windows oversized direct transfer ok."

echo "Testing Mac -> Windows oversized direct transfer failure cleanup..."
limit_cleanup_out="${tmp_dir}/mac-to-windows-limit-cleanup-send.txt"
limit_cleanup_config="${tmp_dir}/moonlight-companion-limit-cleanup.conf"
remove_windows_direct_temp_artifacts
limit_cleanup_blocker="$(create_windows_blocking_transfer_dir)"
if [[ -z "$limit_cleanup_blocker" ]]; then
  echo "Could not create Windows blocking path for direct transfer cleanup test." >&2
  exit 1
fi
printf 'source %q\nMOONLIGHT_CLIPBOARD_MAX_BYTES="1"\nMOONLIGHT_TRANSFER_OVERSIZE_DIRECT="yes"\nMOONLIGHT_TRANSFER_WINDOWS_DIR=%q\n' "$config" "$limit_cleanup_blocker" > "$limit_cleanup_config"
if MOONLIGHT_COMPANION_CONFIG="$limit_cleanup_config" "${script_dir}/send-files-to-windows.sh" "$limit_file" > "$limit_cleanup_out" 2>&1; then
  remove_windows_absolute_path "$limit_cleanup_blocker"
  echo "Mac -> Windows oversized direct transfer unexpectedly succeeded against a blocking receive path." >&2
  cat "$limit_cleanup_out" >&2
  exit 1
fi
remove_windows_absolute_path "$limit_cleanup_blocker"
direct_temp_count="$(windows_direct_temp_count)"
if [[ "$direct_temp_count" != "0" ]]; then
  remove_windows_direct_temp_artifacts
  echo "Mac -> Windows oversized direct transfer failure left direct temp artifacts on Windows." >&2
  echo "direct temp artifact count: ${direct_temp_count}" >&2
  cat "$limit_cleanup_out" >&2
  exit 1
fi
echo "Mac -> Windows oversized direct transfer failure cleanup ok."

echo "Testing Mac -> Windows oversized direct transfer disabled..."
limit_disabled_out="${tmp_dir}/mac-to-windows-limit-disabled-send.txt"
limit_disabled_config="${tmp_dir}/moonlight-companion-limit-disabled.conf"
printf 'source %q\nMOONLIGHT_CLIPBOARD_MAX_BYTES="1"\nMOONLIGHT_TRANSFER_OVERSIZE_DIRECT="no"\n' "$config" > "$limit_disabled_config"
if MOONLIGHT_COMPANION_CONFIG="$limit_disabled_config" "${script_dir}/send-files-to-windows.sh" "$limit_file" > "$limit_disabled_out" 2>&1; then
  echo "Mac -> Windows oversized payload was not rejected when direct transfer was disabled." >&2
  cat "$limit_disabled_out" >&2
  exit 1
fi
if ! grep -Fq "payload too large:" "$limit_disabled_out" || ! grep -Fq "clipboard transfer limit" "$limit_disabled_out"; then
  echo "Mac -> Windows oversized rejection did not explain the disabled direct-transfer case." >&2
  cat "$limit_disabled_out" >&2
  exit 1
fi
echo "Mac -> Windows oversized direct transfer disabled ok."

echo "Testing Mac -> Windows SSH fallback stale tmp cleanup..."
ssh_fallback_file="${tmp_dir}/moonlight-companion-transfer-test-ssh-fallback-${stamp}.txt"
ssh_fallback_name="$(basename "$ssh_fallback_file")"
ssh_fallback_out="${tmp_dir}/mac-to-windows-ssh-fallback-send.txt"
ssh_fallback_config="${tmp_dir}/moonlight-companion-ssh-fallback.conf"
printf 'Moonlight Companion SSH fallback cleanup test %s\n' "$stamp" > "$ssh_fallback_file"
printf 'source %q\nMOONLIGHT_CLIPBOARD_TCP="no"\n' "$config" > "$ssh_fallback_config"
remove_windows_mac_upload_artifacts
write_stale_windows_mac_tmp_zip
if ! MOONLIGHT_COMPANION_CONFIG="$ssh_fallback_config" "${script_dir}/send-files-to-windows.sh" "$ssh_fallback_file" > "$ssh_fallback_out" 2>&1; then
  remove_windows_mac_upload_artifacts
  echo "Mac -> Windows SSH fallback send failed." >&2
  cat "$ssh_fallback_out" >&2
  exit 1
fi
if windows_mac_tmp_zip_exists; then
  remove_windows_mac_upload_artifacts
  echo "Mac -> Windows SSH fallback left a stale tmp ZIP in the Windows sync folder." >&2
  cat "$ssh_fallback_out" >&2
  exit 1
fi
if ! wait_for_windows_file "$ssh_fallback_name"; then
  echo "Mac -> Windows SSH fallback payload did not arrive in the Windows receive folder." >&2
  cat "$ssh_fallback_out" >&2
  exit 1
fi
if ! wait_for_windows_mac_zip_absent 80; then
  remove_windows_mac_upload_artifacts
  echo "Mac -> Windows SSH fallback did not consume the remote fallback ZIP after import." >&2
  cat "$ssh_fallback_out" >&2
  exit 1
fi
remove_windows_file "$ssh_fallback_name"
echo "Mac -> Windows SSH fallback cleanup ok."

echo "Testing Mac -> Windows stale fallback cleanup..."
bad_mac_fallback_zip="${tmp_dir}/mac-to-windows-bad-fallback.zip"
printf 'not a zip %s\n' "$stamp" > "$bad_mac_fallback_zip"
remove_windows_mac_upload_artifacts
upload_windows_mac_zip "$bad_mac_fallback_zip"
if ! wait_for_windows_mac_zip_absent 80; then
  remove_windows_mac_upload_artifacts
  echo "Mac -> Windows stale fallback ZIP was not removed after repeated import failures." >&2
  exit 1
fi
upload_windows_mac_zip "$bad_mac_fallback_zip"
if ! wait_for_windows_mac_zip_absent 80; then
  remove_windows_mac_upload_artifacts
  echo "Mac -> Windows reappeared stale fallback ZIP with the same hash was not removed." >&2
  exit 1
fi
echo "Mac -> Windows stale fallback cleanup ok."

echo "Testing Mac -> Windows file transfer..."
m2w_file="${tmp_dir}/moonlight-companion-transfer-test-mac-to-windows-${stamp}.txt"
m2w_name="$(basename "$m2w_file")"
m2w_collision_name="$(collision_name "$m2w_name")"
m2w_out="${tmp_dir}/mac-to-windows-send.txt"
m2w_state="${tmp_dir}/mac-to-windows-send-state.txt"
printf 'Moonlight Companion Mac -> Windows test %s\n' "$stamp" > "$m2w_file"
write_windows_file "$m2w_name" "existing Windows receive file ${stamp}"
send_env=(MOONLIGHT_COMPANION_CONFIG="$config")
if [[ "$(normalize_yes_no "$MOONLIGHT_CLIPBOARD_TCP")" == "yes" ]]; then
  send_env+=(MOONLIGHT_TRANSFER_REQUIRE_TCP_ACK=yes)
fi
env "${send_env[@]}" MOONLIGHT_TRANSFER_RESULT_STATE="$m2w_state" "${script_dir}/send-files-to-windows.sh" "$m2w_file" > "$m2w_out"
if ! grep -q "Windows confirmed" "$m2w_out"; then
  echo "Mac -> Windows transfer did not receive Windows import confirmation." >&2
  cat "$m2w_out" >&2
  exit 1
fi
if [[ ! -f "$m2w_state" || "$(meta_value id "$m2w_state")" != files:* ]]; then
  echo "Mac -> Windows transfer did not write a GUI result state id." >&2
  [[ -f "$m2w_state" ]] && cat "$m2w_state" >&2
  exit 1
fi
m2w_state_names_b64="$(meta_value imported_names_b64 "$m2w_state")"
m2w_state_names="$(printf '%s' "$m2w_state_names_b64" | /usr/bin/base64 -D 2>/dev/null | tr '\037' '\n' || true)"
if [[ -z "$m2w_state_names_b64" || "$m2w_state_names" != *"$m2w_collision_name"* ]]; then
  echo "Mac -> Windows transfer did not write the imported Windows receive name to the GUI result state." >&2
  [[ -f "$m2w_state" ]] && cat "$m2w_state" >&2
  exit 1
fi
m2w_state_path="$(meta_value imported_path_1 "$m2w_state")"
if [[ "$m2w_state_path" != *"$m2w_collision_name"* ]]; then
  echo "Mac -> Windows transfer did not write the imported Windows receive path to the GUI result state." >&2
  [[ -f "$m2w_state" ]] && cat "$m2w_state" >&2
  exit 1
fi
if ! wait_for_windows_file "$m2w_collision_name"; then
  echo "Mac -> Windows transfer did not create a collision-safe file in the Windows receive folder." >&2
  exit 1
fi
remove_windows_receive_opener_test_script
write_stale_windows_receive_opener_script
windows_reveal_out="$(
  MOONLIGHT_COMPANION_CONFIG="$config" MOONLIGHT_OPEN_WINDOWS_RECEIVE_DRY_RUN=yes \
    "${script_dir}/open-windows-receive-folder.sh" --select-path "$m2w_state_path"
)"
if ! grep -Fq "asked Windows to select the received item" <<<"$windows_reveal_out"; then
  echo "Windows receive reveal did not select the explicit imported path." >&2
  printf '%s\n' "$windows_reveal_out" >&2
  exit 1
fi
if windows_receive_opener_test_script_exists; then
  remove_windows_receive_opener_test_script
  echo "Windows receive reveal left a stale remote opener script behind." >&2
  exit 1
fi
remove_windows_file "$m2w_name"
remove_windows_file "$m2w_collision_name"
echo "Mac -> Windows ok."

echo "Testing Mac -> Windows spaced filename transfer..."
m2w_spaced_name="moonlight-companion-transfer-test-spaced mac (${stamp}).txt"
m2w_spaced_file="${tmp_dir}/${m2w_spaced_name}"
m2w_spaced_out="${tmp_dir}/mac-to-windows-spaced-send.txt"
printf 'Moonlight Companion Mac -> Windows spaced filename test %s\n' "$stamp" > "$m2w_spaced_file"
env "${send_env[@]}" "${script_dir}/send-files-to-windows.sh" "$m2w_spaced_file" > "$m2w_spaced_out"
if ! grep -q "Windows confirmed" "$m2w_spaced_out"; then
  echo "Mac -> Windows spaced filename transfer did not receive Windows import confirmation." >&2
  cat "$m2w_spaced_out" >&2
  exit 1
fi
if ! wait_for_windows_file "$m2w_spaced_name"; then
  echo "Mac -> Windows spaced filename transfer did not preserve the file name." >&2
  exit 1
fi
remove_windows_file "$m2w_spaced_name"
echo "Mac -> Windows spaced filename ok."

echo "Testing Mac -> Windows apostrophe filename transfer..."
m2w_apostrophe_name="moonlight-companion-transfer-test-mac's file (${stamp}).txt"
m2w_apostrophe_file="${tmp_dir}/${m2w_apostrophe_name}"
m2w_apostrophe_out="${tmp_dir}/mac-to-windows-apostrophe-send.txt"
printf 'Moonlight Companion Mac -> Windows apostrophe filename test %s\n' "$stamp" > "$m2w_apostrophe_file"
env "${send_env[@]}" "${script_dir}/send-files-to-windows.sh" "$m2w_apostrophe_file" > "$m2w_apostrophe_out"
if ! grep -q "Windows confirmed" "$m2w_apostrophe_out"; then
  echo "Mac -> Windows apostrophe filename transfer did not receive Windows import confirmation." >&2
  cat "$m2w_apostrophe_out" >&2
  exit 1
fi
if ! wait_for_windows_file "$m2w_apostrophe_name"; then
  echo "Mac -> Windows apostrophe filename transfer did not preserve the file name." >&2
  exit 1
fi
remove_windows_file "$m2w_apostrophe_name"
echo "Mac -> Windows apostrophe filename ok."

echo "Testing Mac -> Windows Korean filename transfer..."
m2w_korean_name="moonlight-companion-transfer-test-한글 맥 (${stamp}).txt"
m2w_korean_file="${tmp_dir}/${m2w_korean_name}"
m2w_korean_out="${tmp_dir}/mac-to-windows-korean-send.txt"
printf 'Moonlight Companion Mac -> Windows Korean filename test %s\n' "$stamp" > "$m2w_korean_file"
env "${send_env[@]}" "${script_dir}/send-files-to-windows.sh" "$m2w_korean_file" > "$m2w_korean_out"
if ! grep -q "Windows confirmed" "$m2w_korean_out"; then
  echo "Mac -> Windows Korean filename transfer did not receive Windows import confirmation." >&2
  cat "$m2w_korean_out" >&2
  exit 1
fi
if ! wait_for_windows_file "$m2w_korean_name"; then
  echo "Mac -> Windows Korean filename transfer did not preserve the file name." >&2
  exit 1
fi
remove_windows_file "$m2w_korean_name"
echo "Mac -> Windows Korean filename ok."

echo "Testing Mac -> Windows Windows-safe filename transfer..."
m2w_windows_safe_source_name="moonlight-companion-transfer-test-windows-safe ? star * colon: pipe| (${stamp}).txt"
m2w_windows_safe_expected_name="moonlight-companion-transfer-test-windows-safe _ star _ colon_ pipe_ (${stamp}).txt"
m2w_windows_safe_file="${tmp_dir}/${m2w_windows_safe_source_name}"
m2w_windows_safe_out="${tmp_dir}/mac-to-windows-safe-name-send.txt"
printf 'Moonlight Companion Mac -> Windows safe filename test %s\n' "$stamp" > "$m2w_windows_safe_file"
m2w_windows_safe_hash="$(mac_file_sha256 "$m2w_windows_safe_file")"
env "${send_env[@]}" "${script_dir}/send-files-to-windows.sh" "$m2w_windows_safe_file" > "$m2w_windows_safe_out"
if ! grep -q "Windows confirmed" "$m2w_windows_safe_out"; then
  echo "Mac -> Windows Windows-safe filename transfer did not receive Windows import confirmation." >&2
  cat "$m2w_windows_safe_out" >&2
  exit 1
fi
if ! grep -Fq "$m2w_windows_safe_expected_name" "$m2w_windows_safe_out"; then
  echo "Mac -> Windows Windows-safe filename transfer did not report the sanitized receive-folder file name." >&2
  cat "$m2w_windows_safe_out" >&2
  exit 1
fi
if ! wait_for_windows_file "$m2w_windows_safe_expected_name"; then
  echo "Mac -> Windows Windows-safe filename transfer did not create the sanitized file name." >&2
  exit 1
fi
if [[ "$(windows_file_sha256 "$m2w_windows_safe_expected_name")" != "$m2w_windows_safe_hash" ]]; then
  echo "Mac -> Windows Windows-safe filename transfer changed the file bytes." >&2
  exit 1
fi
remove_windows_file "$m2w_windows_safe_expected_name"
echo "Mac -> Windows Windows-safe filename ok."

echo "Testing Mac -> Windows image file transfer..."
m2w_image_name="moonlight-companion-transfer-test-image-mac-${stamp}.png"
m2w_image_file="${tmp_dir}/${m2w_image_name}"
m2w_image_out="${tmp_dir}/mac-to-windows-image-send.txt"
m2w_image_hash="$(write_test_png "$m2w_image_file"; mac_file_sha256 "$m2w_image_file")"
env "${send_env[@]}" "${script_dir}/send-files-to-windows.sh" "$m2w_image_file" > "$m2w_image_out"
if ! grep -q "Windows confirmed" "$m2w_image_out"; then
  echo "Mac -> Windows image file transfer did not receive Windows import confirmation." >&2
  cat "$m2w_image_out" >&2
  exit 1
fi
if ! wait_for_windows_file "$m2w_image_name"; then
  echo "Mac -> Windows image file transfer did not create the image file." >&2
  exit 1
fi
if [[ "$(windows_file_sha256 "$m2w_image_name")" != "$m2w_image_hash" ]]; then
  echo "Mac -> Windows image file transfer changed the file bytes." >&2
  exit 1
fi
remove_windows_file "$m2w_image_name"
echo "Mac -> Windows image file ok."

echo "Testing Mac -> Windows empty file transfer..."
m2w_empty_file_name="moonlight-companion-transfer-test-empty-mac-${stamp}.txt"
m2w_empty_file="${tmp_dir}/${m2w_empty_file_name}"
m2w_empty_out="${tmp_dir}/mac-to-windows-empty-send.txt"
: > "$m2w_empty_file"
m2w_empty_hash="$(mac_file_sha256 "$m2w_empty_file")"
env "${send_env[@]}" "${script_dir}/send-files-to-windows.sh" "$m2w_empty_file" > "$m2w_empty_out"
if ! grep -q "Windows confirmed" "$m2w_empty_out"; then
  echo "Mac -> Windows empty file transfer did not receive Windows import confirmation." >&2
  cat "$m2w_empty_out" >&2
  exit 1
fi
if ! wait_for_windows_file "$m2w_empty_file_name"; then
  echo "Mac -> Windows empty file transfer did not create the empty file." >&2
  exit 1
fi
if [[ "$(windows_file_sha256 "$m2w_empty_file_name")" != "$m2w_empty_hash" ]]; then
  echo "Mac -> Windows empty file transfer changed the file bytes." >&2
  exit 1
fi
remove_windows_file "$m2w_empty_file_name"
echo "Mac -> Windows empty file ok."

echo "Testing Mac -> Windows multi-item transfer..."
m2w_multi_file="${tmp_dir}/moonlight-companion-transfer-test-mac-multi-file-${stamp}.txt"
m2w_multi_file_name="$(basename "$m2w_multi_file")"
m2w_multi_dir="${tmp_dir}/moonlight-companion-transfer-test-mac-multi-folder-${stamp}"
m2w_multi_dir_name="$(basename "$m2w_multi_dir")"
m2w_multi_nested_path="nested/from-mac-multi.txt"
m2w_multi_out="${tmp_dir}/mac-to-windows-multi-send.txt"
m2w_multi_state="${tmp_dir}/mac-to-windows-multi-state.txt"
mkdir -p "${m2w_multi_dir}/nested"
printf 'Moonlight Companion Mac -> Windows multi file test %s\n' "$stamp" > "$m2w_multi_file"
printf 'Moonlight Companion Mac -> Windows multi folder test %s\n' "$stamp" > "${m2w_multi_dir}/${m2w_multi_nested_path}"
env "${send_env[@]}" MOONLIGHT_TRANSFER_RESULT_STATE="$m2w_multi_state" "${script_dir}/send-files-to-windows.sh" "$m2w_multi_file" "$m2w_multi_dir" > "$m2w_multi_out"
if ! grep -q "Windows confirmed 2 items" "$m2w_multi_out"; then
  echo "Mac -> Windows multi-item transfer did not receive confirmation for both items." >&2
  cat "$m2w_multi_out" >&2
  exit 1
fi
if [[ "$(meta_value imported_paths "$m2w_multi_state")" != "2" ]]; then
  echo "Mac -> Windows multi-item transfer did not write both imported paths to the GUI result state." >&2
  [[ -f "$m2w_multi_state" ]] && cat "$m2w_multi_state" >&2
  exit 1
fi
if ! wait_for_windows_file "$m2w_multi_file_name"; then
  echo "Mac -> Windows multi-item transfer did not preserve the top-level file." >&2
  exit 1
fi
if ! wait_for_windows_path "${m2w_multi_dir_name}/${m2w_multi_nested_path}" "Leaf"; then
  echo "Mac -> Windows multi-item transfer did not preserve the folder item." >&2
  exit 1
fi
m2w_multi_path_1="$(meta_value imported_path_1 "$m2w_multi_state")"
m2w_multi_path_2="$(meta_value imported_path_2 "$m2w_multi_state")"
windows_multi_reveal_out="$(
  MOONLIGHT_COMPANION_CONFIG="$config" MOONLIGHT_OPEN_WINDOWS_RECEIVE_DRY_RUN=yes \
    "${script_dir}/open-windows-receive-folder.sh" --select-path "$m2w_multi_path_1" --select-path "$m2w_multi_path_2"
)"
if ! grep -Fq "asked Windows to open the containing folder for multiple received items" <<<"$windows_multi_reveal_out"; then
  echo "Windows receive reveal did not open the common parent for multiple explicit imported paths." >&2
  printf '%s\n' "$windows_multi_reveal_out" >&2
  exit 1
fi
remove_windows_file "$m2w_multi_file_name"
remove_windows_path "$m2w_multi_dir_name"
echo "Mac -> Windows multi-item ok."

echo "Testing Mac -> Windows folder transfer..."
m2w_dir="${tmp_dir}/moonlight-companion-transfer-test-mac-folder-${stamp}"
m2w_dir_name="$(basename "$m2w_dir")"
m2w_nested_path="nested/from-mac.txt"
m2w_empty_dir_path="nested/empty-from-mac"
m2w_windows_safe_nested_source_dir="nested/windows?unsafe*dir"
m2w_windows_safe_nested_source_file="${m2w_windows_safe_nested_source_dir}/from:mac|nested?.txt"
m2w_windows_safe_nested_expected_dir="nested/windows_unsafe_dir"
m2w_windows_safe_nested_expected_file="${m2w_windows_safe_nested_expected_dir}/from_mac_nested_.txt"
m2w_reserved_nested_source_file="nested/CON.txt"
m2w_reserved_nested_expected_file="nested/_CON.txt"
m2w_trailing_nested_source_file="nested/trailing dot. "
m2w_trailing_nested_expected_file="nested/trailing dot"
m2w_dir_out="${tmp_dir}/mac-to-windows-folder-send.txt"
mkdir -p "${m2w_dir}/nested" "${m2w_dir}/${m2w_empty_dir_path}" "${m2w_dir}/${m2w_windows_safe_nested_source_dir}"
printf 'Moonlight Companion Mac -> Windows folder test %s\n' "$stamp" > "${m2w_dir}/${m2w_nested_path}"
printf 'Moonlight Companion Mac -> Windows nested safe filename test %s\n' "$stamp" > "${m2w_dir}/${m2w_windows_safe_nested_source_file}"
printf 'Moonlight Companion Mac -> Windows reserved filename test %s\n' "$stamp" > "${m2w_dir}/${m2w_reserved_nested_source_file}"
printf 'Moonlight Companion Mac -> Windows trailing filename test %s\n' "$stamp" > "${m2w_dir}/${m2w_trailing_nested_source_file}"
env "${send_env[@]}" "${script_dir}/send-files-to-windows.sh" "$m2w_dir" > "$m2w_dir_out"
if ! grep -q "Windows confirmed" "$m2w_dir_out"; then
  echo "Mac -> Windows folder transfer did not receive Windows import confirmation." >&2
  cat "$m2w_dir_out" >&2
  exit 1
fi
if ! wait_for_windows_path "${m2w_dir_name}/${m2w_nested_path}" "Leaf"; then
  echo "Mac -> Windows folder transfer did not preserve the nested file." >&2
  exit 1
fi
if ! wait_for_windows_path "${m2w_dir_name}/${m2w_empty_dir_path}" "Container"; then
  echo "Mac -> Windows folder transfer did not preserve the empty nested folder." >&2
  exit 1
fi
if ! wait_for_windows_path "${m2w_dir_name}/${m2w_windows_safe_nested_expected_file}" "Leaf"; then
  echo "Mac -> Windows folder transfer did not sanitize a nested Windows-unsafe file name." >&2
  exit 1
fi
if ! wait_for_windows_path "${m2w_dir_name}/${m2w_windows_safe_nested_expected_dir}" "Container"; then
  echo "Mac -> Windows folder transfer did not sanitize a nested Windows-unsafe folder name." >&2
  exit 1
fi
if ! wait_for_windows_path "${m2w_dir_name}/${m2w_reserved_nested_expected_file}" "Leaf"; then
  echo "Mac -> Windows folder transfer did not sanitize a nested Windows-reserved file name." >&2
  exit 1
fi
if ! wait_for_windows_path "${m2w_dir_name}/${m2w_trailing_nested_expected_file}" "Leaf"; then
  echo "Mac -> Windows folder transfer did not sanitize a nested trailing-dot file name." >&2
  exit 1
fi
remove_windows_path "$m2w_dir_name"
echo "Mac -> Windows folder ok."

echo "Testing Windows -> Mac file transfer..."
w2m_file="${tmp_dir}/moonlight-companion-transfer-test-windows-to-mac-${stamp}.txt"
w2m_name="$(basename "$w2m_file")"
w2m_collision_name="$(collision_name "$w2m_name")"
printf 'Moonlight Companion Windows -> Mac test %s\n' "$stamp" > "$w2m_file"
printf 'existing Mac receive file %s\n' "$stamp" > "${transfer_mac_dir}/${w2m_name}"
payload_dir="${tmp_dir}/w2m-payload"
payload_meta="${tmp_dir}/w2m-payload-meta.txt"
zip_path="${tmp_dir}/windows-to-mac.zip"
w2m_tcp_ack="${tmp_dir}/w2m-tcp-ack.txt"
MOONLIGHT_TRANSFER_MAC_DIR="$transfer_mac_dir" "$helper" export-paths "$payload_dir" "$w2m_file" > "$payload_meta"
w2m_id="$(meta_value id "$payload_meta")"
zip_payload "$payload_dir" "$zip_path"
MOONLIGHT_TRANSFER_NOTIFY=no MOONLIGHT_TRANSFER_REVEAL_MAC_DIR=no MOONLIGHT_TRANSFER_MAC_DIR="$transfer_mac_dir" \
  "$tcp_helper" send 127.0.0.1 "$MOONLIGHT_CLIPBOARD_WINDOWS_TO_MAC_TCP_LOCAL_PORT" "$zip_path" > "$w2m_tcp_ack"
if [[ "$(meta_value id "$w2m_tcp_ack")" != "$w2m_id" ||
      "$(meta_value imported_paths "$w2m_tcp_ack")" != "1" ]]; then
  echo "Windows -> Mac TCP transfer did not receive a Mac import acknowledgement." >&2
  cat "$w2m_tcp_ack" >&2
  exit 1
fi
if ! wait_for_mac_file "$transfer_mac_dir" "$w2m_collision_name"; then
  echo "Windows -> Mac transfer did not create a collision-safe file in the Mac receive folder." >&2
  exit 1
fi
if ! grep -Fqx "file_path_1=${transfer_mac_dir}/${w2m_collision_name}" "$tcp_state"; then
  echo "Windows -> Mac transfer did not record the latest received Mac file path." >&2
  [[ -f "$tcp_state" ]] && cat "$tcp_state" >&2
  exit 1
fi
if ! grep -Fqx "file_name_1=${w2m_collision_name}" "$tcp_state"; then
  echo "Windows -> Mac transfer did not record the latest received Mac file name." >&2
  [[ -f "$tcp_state" ]] && cat "$tcp_state" >&2
  exit 1
fi

echo "Testing latest Mac receive clipboard restore..."
printf 'Moonlight Companion clipboard overwrite test %s\n' "$stamp" | pbcopy
w2m_restore_meta="${tmp_dir}/w2m-restore-meta.txt"
w2m_restore_payload="${tmp_dir}/w2m-restore-set-payload"
w2m_restore_lock="${tcp_state}.lock"
printf 'restoring\n' > "$w2m_restore_lock"
if ! "$helper" set-files "$w2m_restore_payload" "${transfer_mac_dir}/${w2m_collision_name}" > "$w2m_restore_meta"; then
  rm -f "$w2m_restore_lock"
  echo "Latest Mac receive clipboard restore failed to set the file clipboard." >&2
  exit 1
fi
if [[ -e "${w2m_restore_payload}/files/${w2m_collision_name}" ]]; then
  rm -f "$w2m_restore_lock"
  echo "Latest Mac receive clipboard restore copied the received file instead of using metadata-only restore." >&2
  exit 1
fi
w2m_restore_id="$(meta_value id "$w2m_restore_meta")"
if [[ -z "$w2m_restore_id" ]]; then
  rm -f "$w2m_restore_lock"
  echo "Latest Mac receive clipboard restore did not calculate a payload id." >&2
  exit 1
fi
if ! update_receive_state_normalized_id "$w2m_restore_id"; then
  rm -f "$w2m_restore_lock"
  echo "Latest Mac receive clipboard restore did not update the receive state." >&2
  exit 1
fi
rm -f "$w2m_restore_lock"
if ! "$helper" export "${tmp_dir}/w2m-restored-clipboard-payload" > "${tmp_dir}/w2m-restored-clipboard-meta.txt" 2>/dev/null; then
  echo "Latest Mac receive clipboard restore did not leave a readable file clipboard." >&2
  exit 1
fi
if [[ "$(meta_value id "${tmp_dir}/w2m-restored-clipboard-meta.txt")" != "$w2m_restore_id" ]]; then
  echo "Latest Mac receive clipboard restore produced an unexpected clipboard payload id." >&2
  cat "${tmp_dir}/w2m-restored-clipboard-meta.txt" >&2
  exit 1
fi
sleep 3
assert_windows_path_absent "$w2m_name" "Leaf"
assert_windows_path_absent "$w2m_collision_name" "Leaf"
echo "Latest Mac receive clipboard restore ok."
rm -f "${transfer_mac_dir}/${w2m_name}" "${transfer_mac_dir}/${w2m_collision_name}"
echo "Windows -> Mac ok."

echo "Testing Windows -> Mac SSH fallback file transfer..."
w2m_fallback_name="moonlight-companion-transfer-test-windows-fallback-${stamp}.txt"
w2m_fallback_file="${tmp_dir}/${w2m_fallback_name}"
w2m_fallback_payload="${tmp_dir}/w2m-fallback-payload"
w2m_fallback_meta="${tmp_dir}/w2m-fallback-meta.txt"
w2m_fallback_zip="${tmp_dir}/windows-to-mac-fallback.zip"
printf 'Moonlight Companion Windows -> Mac SSH fallback test %s\n' "$stamp" > "$w2m_fallback_file"
w2m_fallback_hash="$(mac_file_sha256 "$w2m_fallback_file")"
MOONLIGHT_TRANSFER_MAC_DIR="$transfer_mac_dir" "$helper" export-paths "$w2m_fallback_payload" "$w2m_fallback_file" > "$w2m_fallback_meta"
w2m_fallback_id="$(meta_value id "$w2m_fallback_meta")"
zip_payload "$w2m_fallback_payload" "$w2m_fallback_zip"
remove_windows_fallback_zip
upload_windows_fallback_zip "$w2m_fallback_zip"
if ! wait_for_mac_file "$transfer_mac_dir" "$w2m_fallback_name" 80; then
  echo "Windows -> Mac SSH fallback transfer did not create the file in the Mac receive folder." >&2
  [[ -f "$tcp_state" ]] && cat "$tcp_state" >&2
  exit 1
fi
if [[ "$(mac_file_sha256 "${transfer_mac_dir}/${w2m_fallback_name}")" != "$w2m_fallback_hash" ]]; then
  echo "Windows -> Mac SSH fallback transfer changed the file bytes." >&2
  exit 1
fi
if ! wait_for_mac_receive_state_id "$w2m_fallback_id" 80; then
  echo "Windows -> Mac SSH fallback transfer did not update the latest receive state." >&2
  [[ -f "$tcp_state" ]] && cat "$tcp_state" >&2
  exit 1
fi
if ! grep -Fqx "file_path_1=${transfer_mac_dir}/${w2m_fallback_name}" "$tcp_state"; then
  echo "Windows -> Mac SSH fallback transfer did not record the latest received Mac file path." >&2
  [[ -f "$tcp_state" ]] && cat "$tcp_state" >&2
  exit 1
fi
if ! wait_for_windows_fallback_zip_absent 80; then
  echo "Windows -> Mac SSH fallback transfer did not consume the remote fallback ZIP." >&2
  exit 1
fi
sleep 3
assert_windows_path_absent "$w2m_fallback_name" "Leaf"
remove_windows_fallback_zip
rm -f "${transfer_mac_dir}/${w2m_fallback_name}"
echo "Windows -> Mac SSH fallback file ok."

echo "Testing Windows -> Mac stale fallback cleanup..."
bad_fallback_zip="${tmp_dir}/windows-to-mac-bad-fallback.zip"
printf 'not a zip %s\n' "$stamp" > "$bad_fallback_zip"
remove_windows_fallback_zip
upload_windows_fallback_zip "$bad_fallback_zip"
if ! wait_for_windows_fallback_zip_absent 80; then
  echo "Windows -> Mac stale fallback ZIP was not removed after repeated import failures." >&2
  exit 1
fi
if ! sync_service_running; then
  echo "Mac clipboard sync service exited while handling a bad Windows fallback ZIP." >&2
  exit 1
fi
echo "Windows -> Mac stale fallback cleanup ok."

echo "Testing Windows -> Mac spaced filename transfer..."
w2m_spaced_name="moonlight-companion-transfer-test-spaced windows (${stamp}).txt"
w2m_spaced_file="${tmp_dir}/${w2m_spaced_name}"
w2m_spaced_payload="${tmp_dir}/w2m-spaced-payload"
w2m_spaced_zip="${tmp_dir}/windows-to-mac-spaced.zip"
printf 'Moonlight Companion Windows -> Mac spaced filename test %s\n' "$stamp" > "$w2m_spaced_file"
MOONLIGHT_TRANSFER_MAC_DIR="$transfer_mac_dir" "$helper" export-paths "$w2m_spaced_payload" "$w2m_spaced_file" >/dev/null
zip_payload "$w2m_spaced_payload" "$w2m_spaced_zip"
MOONLIGHT_TRANSFER_NOTIFY=no MOONLIGHT_TRANSFER_REVEAL_MAC_DIR=no MOONLIGHT_TRANSFER_MAC_DIR="$transfer_mac_dir" \
  "$tcp_helper" send 127.0.0.1 "$MOONLIGHT_CLIPBOARD_WINDOWS_TO_MAC_TCP_LOCAL_PORT" "$w2m_spaced_zip" >/dev/null
if ! wait_for_mac_file "$transfer_mac_dir" "$w2m_spaced_name"; then
  echo "Windows -> Mac spaced filename transfer did not preserve the file name." >&2
  exit 1
fi
sleep 3
assert_windows_path_absent "$w2m_spaced_name" "Leaf"
rm -f "${transfer_mac_dir}/${w2m_spaced_name}"
echo "Windows -> Mac spaced filename ok."

echo "Testing Windows -> Mac apostrophe filename transfer..."
w2m_apostrophe_name="moonlight-companion-transfer-test-windows's file (${stamp}).txt"
w2m_apostrophe_file="${tmp_dir}/${w2m_apostrophe_name}"
w2m_apostrophe_payload="${tmp_dir}/w2m-apostrophe-payload"
w2m_apostrophe_zip="${tmp_dir}/windows-to-mac-apostrophe.zip"
printf 'Moonlight Companion Windows -> Mac apostrophe filename test %s\n' "$stamp" > "$w2m_apostrophe_file"
MOONLIGHT_TRANSFER_MAC_DIR="$transfer_mac_dir" "$helper" export-paths "$w2m_apostrophe_payload" "$w2m_apostrophe_file" >/dev/null
zip_payload "$w2m_apostrophe_payload" "$w2m_apostrophe_zip"
MOONLIGHT_TRANSFER_NOTIFY=no MOONLIGHT_TRANSFER_REVEAL_MAC_DIR=no MOONLIGHT_TRANSFER_MAC_DIR="$transfer_mac_dir" \
  "$tcp_helper" send 127.0.0.1 "$MOONLIGHT_CLIPBOARD_WINDOWS_TO_MAC_TCP_LOCAL_PORT" "$w2m_apostrophe_zip" >/dev/null
if ! wait_for_mac_file "$transfer_mac_dir" "$w2m_apostrophe_name"; then
  echo "Windows -> Mac apostrophe filename transfer did not preserve the file name." >&2
  exit 1
fi
sleep 3
assert_windows_path_absent "$w2m_apostrophe_name" "Leaf"
rm -f "${transfer_mac_dir}/${w2m_apostrophe_name}"
echo "Windows -> Mac apostrophe filename ok."

echo "Testing Windows -> Mac Korean filename transfer..."
w2m_korean_name="moonlight-companion-transfer-test-한글 윈도우 (${stamp}).txt"
w2m_korean_file="${tmp_dir}/${w2m_korean_name}"
w2m_korean_payload="${tmp_dir}/w2m-korean-payload"
w2m_korean_zip="${tmp_dir}/windows-to-mac-korean.zip"
printf 'Moonlight Companion Windows -> Mac Korean filename test %s\n' "$stamp" > "$w2m_korean_file"
MOONLIGHT_TRANSFER_MAC_DIR="$transfer_mac_dir" "$helper" export-paths "$w2m_korean_payload" "$w2m_korean_file" >/dev/null
zip_payload "$w2m_korean_payload" "$w2m_korean_zip"
MOONLIGHT_TRANSFER_NOTIFY=no MOONLIGHT_TRANSFER_REVEAL_MAC_DIR=no MOONLIGHT_TRANSFER_MAC_DIR="$transfer_mac_dir" \
  "$tcp_helper" send 127.0.0.1 "$MOONLIGHT_CLIPBOARD_WINDOWS_TO_MAC_TCP_LOCAL_PORT" "$w2m_korean_zip" >/dev/null
if ! wait_for_mac_file "$transfer_mac_dir" "$w2m_korean_name"; then
  echo "Windows -> Mac Korean filename transfer did not preserve the file name." >&2
  exit 1
fi
sleep 3
assert_windows_path_absent "$w2m_korean_name" "Leaf"
rm -f "${transfer_mac_dir}/${w2m_korean_name}"
echo "Windows -> Mac Korean filename ok."

echo "Testing Windows -> Mac image file transfer..."
w2m_image_name="moonlight-companion-transfer-test-image-windows-${stamp}.png"
w2m_image_file="${tmp_dir}/${w2m_image_name}"
w2m_image_payload="${tmp_dir}/w2m-image-payload"
w2m_image_zip="${tmp_dir}/windows-to-mac-image.zip"
w2m_image_hash="$(write_test_png "$w2m_image_file"; mac_file_sha256 "$w2m_image_file")"
MOONLIGHT_TRANSFER_MAC_DIR="$transfer_mac_dir" "$helper" export-paths "$w2m_image_payload" "$w2m_image_file" >/dev/null
zip_payload "$w2m_image_payload" "$w2m_image_zip"
MOONLIGHT_TRANSFER_NOTIFY=no MOONLIGHT_TRANSFER_REVEAL_MAC_DIR=no MOONLIGHT_TRANSFER_MAC_DIR="$transfer_mac_dir" \
  "$tcp_helper" send 127.0.0.1 "$MOONLIGHT_CLIPBOARD_WINDOWS_TO_MAC_TCP_LOCAL_PORT" "$w2m_image_zip" >/dev/null
if ! wait_for_mac_file "$transfer_mac_dir" "$w2m_image_name"; then
  echo "Windows -> Mac image file transfer did not create the image file." >&2
  exit 1
fi
if [[ "$(mac_file_sha256 "${transfer_mac_dir}/${w2m_image_name}")" != "$w2m_image_hash" ]]; then
  echo "Windows -> Mac image file transfer changed the file bytes." >&2
  exit 1
fi
sleep 3
assert_windows_path_absent "$w2m_image_name" "Leaf"
rm -f "${transfer_mac_dir}/${w2m_image_name}"
echo "Windows -> Mac image file ok."

echo "Testing Windows -> Mac empty file transfer..."
w2m_empty_file_name="moonlight-companion-transfer-test-empty-windows-${stamp}.txt"
w2m_empty_file="${tmp_dir}/${w2m_empty_file_name}"
w2m_empty_payload="${tmp_dir}/w2m-empty-payload"
w2m_empty_zip="${tmp_dir}/windows-to-mac-empty.zip"
: > "$w2m_empty_file"
w2m_empty_hash="$(mac_file_sha256 "$w2m_empty_file")"
MOONLIGHT_TRANSFER_MAC_DIR="$transfer_mac_dir" "$helper" export-paths "$w2m_empty_payload" "$w2m_empty_file" >/dev/null
zip_payload "$w2m_empty_payload" "$w2m_empty_zip"
MOONLIGHT_TRANSFER_NOTIFY=no MOONLIGHT_TRANSFER_REVEAL_MAC_DIR=no MOONLIGHT_TRANSFER_MAC_DIR="$transfer_mac_dir" \
  "$tcp_helper" send 127.0.0.1 "$MOONLIGHT_CLIPBOARD_WINDOWS_TO_MAC_TCP_LOCAL_PORT" "$w2m_empty_zip" >/dev/null
if ! wait_for_mac_file "$transfer_mac_dir" "$w2m_empty_file_name"; then
  echo "Windows -> Mac empty file transfer did not create the empty file." >&2
  exit 1
fi
if [[ "$(mac_file_sha256 "${transfer_mac_dir}/${w2m_empty_file_name}")" != "$w2m_empty_hash" ]]; then
  echo "Windows -> Mac empty file transfer changed the file bytes." >&2
  exit 1
fi
sleep 3
assert_windows_path_absent "$w2m_empty_file_name" "Leaf"
rm -f "${transfer_mac_dir}/${w2m_empty_file_name}"
echo "Windows -> Mac empty file ok."

echo "Testing Windows -> Mac multi-item transfer..."
w2m_multi_file="${tmp_dir}/moonlight-companion-transfer-test-windows-multi-file-${stamp}.txt"
w2m_multi_file_name="$(basename "$w2m_multi_file")"
w2m_multi_dir="${tmp_dir}/moonlight-companion-transfer-test-windows-multi-folder-${stamp}"
w2m_multi_dir_name="$(basename "$w2m_multi_dir")"
w2m_multi_nested_path="nested/from-windows-multi.txt"
w2m_multi_payload="${tmp_dir}/w2m-multi-payload"
w2m_multi_zip="${tmp_dir}/windows-to-mac-multi.zip"
mkdir -p "${w2m_multi_dir}/nested"
printf 'Moonlight Companion Windows -> Mac multi file test %s\n' "$stamp" > "$w2m_multi_file"
printf 'Moonlight Companion Windows -> Mac multi folder test %s\n' "$stamp" > "${w2m_multi_dir}/${w2m_multi_nested_path}"
MOONLIGHT_TRANSFER_MAC_DIR="$transfer_mac_dir" "$helper" export-paths "$w2m_multi_payload" "$w2m_multi_file" "$w2m_multi_dir" >/dev/null
zip_payload "$w2m_multi_payload" "$w2m_multi_zip"
MOONLIGHT_TRANSFER_NOTIFY=no MOONLIGHT_TRANSFER_REVEAL_MAC_DIR=no MOONLIGHT_TRANSFER_MAC_DIR="$transfer_mac_dir" \
  "$tcp_helper" send 127.0.0.1 "$MOONLIGHT_CLIPBOARD_WINDOWS_TO_MAC_TCP_LOCAL_PORT" "$w2m_multi_zip" >/dev/null
if ! wait_for_mac_file "$transfer_mac_dir" "$w2m_multi_file_name"; then
  echo "Windows -> Mac multi-item transfer did not preserve the top-level file." >&2
  exit 1
fi
if ! wait_for_mac_path "$transfer_mac_dir" "${w2m_multi_dir_name}/${w2m_multi_nested_path}" "File"; then
  echo "Windows -> Mac multi-item transfer did not preserve the folder item." >&2
  exit 1
fi
sleep 3
assert_windows_path_absent "$w2m_multi_file_name" "Leaf"
assert_windows_path_absent "$w2m_multi_dir_name" "Container"
rm -f "${transfer_mac_dir}/${w2m_multi_file_name}"
rm -rf "${transfer_mac_dir:?}/${w2m_multi_dir_name}"
echo "Windows -> Mac multi-item ok."

echo "Testing Windows -> Mac folder transfer..."
w2m_dir="${tmp_dir}/moonlight-companion-transfer-test-windows-folder-${stamp}"
w2m_dir_name="$(basename "$w2m_dir")"
w2m_nested_path="nested/from-windows.txt"
w2m_empty_dir_path="nested/empty-from-windows"
w2m_payload_dir="${tmp_dir}/w2m-folder-payload"
w2m_zip_path="${tmp_dir}/windows-to-mac-folder.zip"
mkdir -p "${w2m_dir}/nested" "${w2m_dir}/${w2m_empty_dir_path}"
printf 'Moonlight Companion Windows -> Mac folder test %s\n' "$stamp" > "${w2m_dir}/${w2m_nested_path}"
MOONLIGHT_TRANSFER_MAC_DIR="$transfer_mac_dir" "$helper" export-paths "$w2m_payload_dir" "$w2m_dir" >/dev/null
zip_payload "$w2m_payload_dir" "$w2m_zip_path"
MOONLIGHT_TRANSFER_NOTIFY=no MOONLIGHT_TRANSFER_REVEAL_MAC_DIR=no MOONLIGHT_TRANSFER_MAC_DIR="$transfer_mac_dir" \
  "$tcp_helper" send 127.0.0.1 "$MOONLIGHT_CLIPBOARD_WINDOWS_TO_MAC_TCP_LOCAL_PORT" "$w2m_zip_path" >/dev/null
if ! wait_for_mac_path "$transfer_mac_dir" "${w2m_dir_name}/${w2m_nested_path}" "File"; then
  echo "Windows -> Mac folder transfer did not preserve the nested file." >&2
  exit 1
fi
if ! wait_for_mac_path "$transfer_mac_dir" "${w2m_dir_name}/${w2m_empty_dir_path}" "Directory"; then
  echo "Windows -> Mac folder transfer did not preserve the empty nested folder." >&2
  exit 1
fi
sleep 3
assert_windows_path_absent "$w2m_dir_name" "Container"
rm -rf "${transfer_mac_dir:?}/${w2m_dir_name}"
echo "Windows -> Mac folder ok."

echo "File transfer test passed."
