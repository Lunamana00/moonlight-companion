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
MOONLIGHT_CLIPBOARD_MAC_TO_WINDOWS_TCP_PORT="${MOONLIGHT_CLIPBOARD_MAC_TO_WINDOWS_TCP_PORT:-47331}"
MOONLIGHT_CLIPBOARD_MAC_TO_WINDOWS_TCP_LOCAL_PORT="${MOONLIGHT_CLIPBOARD_MAC_TO_WINDOWS_TCP_LOCAL_PORT:-$MOONLIGHT_CLIPBOARD_MAC_TO_WINDOWS_TCP_PORT}"
MOONLIGHT_TRANSFER_CONFIRM_TIMEOUT_MS="${MOONLIGHT_TRANSFER_CONFIRM_TIMEOUT_MS:-1800}"
MOONLIGHT_TRANSFER_OVERSIZE_DIRECT="${MOONLIGHT_TRANSFER_OVERSIZE_DIRECT:-yes}"
MOONLIGHT_TRANSFER_WINDOWS_DIR="${MOONLIGHT_TRANSFER_WINDOWS_DIR:-%USERPROFILE%\\Downloads\\Moonlight Companion}"

runtime_dir="${MOONLIGHT_CLIPBOARD_RUNTIME_DIR:-${HOME}/Library/Application Support/MoonlightClipboardSync}"
helper="${MOONLIGHT_CLIPBOARD_HELPER:-${runtime_dir}/moonclipctl}"
tcp_helper="${MOONLIGHT_CLIPBOARD_TCP_HELPER:-${runtime_dir}/mooncliptcp}"
source_helper="${script_dir}/moonclipctl.swift"
source_tcp_helper="${script_dir}/mooncliptcp.swift"
log_path="${MOONLIGHT_CLIPBOARD_LOG:-${HOME}/Library/Logs/moonlight-clipboard-sync.log}"

remote_dir=".moonlight-clipboard-sync"
remote_mac_zip="${remote_dir}/mac-to-windows.zip"
remote_mac_tmp="${remote_dir}/mac-to-windows.zip.tmp"
remote_mac_zip_cmd="${remote_dir}\\mac-to-windows.zip"
remote_mac_tmp_cmd="${remote_dir}\\mac-to-windows.zip.tmp"
remote_direct_zip="${remote_dir}/mac-to-windows-direct.zip"
remote_direct_tmp="${remote_dir}/mac-to-windows-direct.zip.tmp"
remote_direct_script="${remote_dir}/mac-to-windows-direct.ps1"
remote_direct_script_cmd="${remote_dir}\\mac-to-windows-direct.ps1"

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

mkdir -p "$runtime_dir" "$(dirname "$log_path")"

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$log_path"
}

progress() {
  [[ "$(normalize_yes_no "${MOONLIGHT_TRANSFER_PROGRESS_EVENTS:-no}")" == "yes" ]] || return 0
  printf '__MOONLIGHT_COMPANION_PROGRESS__ %s\n' "$*" >&2
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

normalize_positive_int() {
  local value="$1"
  local fallback="$2"
  if [[ "$value" =~ ^[0-9]+$ && "$value" -gt 0 ]]; then
    printf '%s\n' "$value"
  else
    printf '%s\n' "$fallback"
  fi
}

format_bytes() {
  local bytes="${1:-0}"
  awk -v bytes="$bytes" '
    function human(value, unit) {
      if (value == int(value)) {
        return sprintf("%d %s", value, unit)
      }
      return sprintf("%.1f %s", value, unit)
    }
    BEGIN {
      if (bytes < 1024) {
        printf "%d B", bytes
      } else if (bytes < 1048576) {
        printf "%s", human(bytes / 1024, "KiB")
      } else if (bytes < 1073741824) {
        printf "%s", human(bytes / 1048576, "MiB")
      } else {
        printf "%s", human(bytes / 1073741824, "GiB")
      }
    }
  '
}

path_bytes() {
  local path="$1"
  if [[ -d "$path" ]]; then
    find "$path" -type f -exec stat -f "%z" {} + 2>/dev/null |
      awk '{ total += $1 } END { printf "%d\n", total + 0 }'
  elif [[ -f "$path" ]]; then
    stat -f "%z" "$path" 2>/dev/null || printf '0\n'
  else
    printf '0\n'
  fi
}

source_payload_bytes() {
  local total=0 bytes path
  for path in "$@"; do
    bytes="$(path_bytes "$path")"
    [[ "$bytes" =~ ^[0-9]+$ ]] || bytes="0"
    total=$((total + bytes))
  done
  printf '%s\n' "$total"
}

first_unreadable_path() {
  local path="$1"
  find "$path" \
    \( ! -exec test -r {} \; -o \( -type d ! -exec test -x {} \; \) \) \
    -print -quit 2>/dev/null || true
}

validate_source_paths() {
  local path blocked
  for path in "$@"; do
    if [[ ! -e "$path" ]]; then
      echo "missing dropped item: $path" >&2
      exit 1
    fi
    if [[ ! -r "$path" ]]; then
      echo "cannot read dropped item: $path. Check file permissions and try again." >&2
      exit 1
    fi
    if [[ -d "$path" && ! -x "$path" ]]; then
      echo "cannot open dropped folder: $path. Check folder permissions and try again." >&2
      exit 1
    fi
    if [[ -d "$path" ]]; then
      blocked="$(first_unreadable_path "$path")"
      if [[ -n "$blocked" ]]; then
        echo "cannot read item inside dropped folder: $blocked. Check file permissions and try again." >&2
        exit 1
      fi
    fi
  done
}

reject_oversized_payload() {
  local payload_bytes="$1"
  local bytes_text max_bytes_text
  bytes_text="$(format_bytes "$payload_bytes")"
  max_bytes_text="$(format_bytes "$MOONLIGHT_CLIPBOARD_MAX_BYTES")"
  echo "payload too large: ${bytes_text} exceeds the ${max_bytes_text} clipboard transfer limit. Split the transfer or use a file sync tool for large files." >&2
  log "skip File drop Mac -> Windows ${kind:-files} (${payload_bytes}B); limit is ${MOONLIGHT_CLIPBOARD_MAX_BYTES}B"
  exit 1
}

ps_single_quoted() {
  local value="$1"
  value=${value//\'/\'\'}
  printf "'%s'" "$value"
}

payload_value() {
  local key="$1"
  local path="$2"
  awk -F= -v key="$key" '$1 == key {print substr($0, length(key) + 2); exit}' "$path"
}

state_value() {
  local key="$1"
  awk -F= -v key="$key" '$1 == key {value = substr($0, length(key) + 2); sub(/\r$/, "", value); print value; exit}'
}

decode_imported_names_b64() {
  local encoded="$1"
  [[ -n "$encoded" ]] || return 0
  printf '%s' "$encoded" | /usr/bin/base64 -D 2>/dev/null | tr '\037' '\n' || true
}

imported_path_names_from_state() {
  awk -F= '$1 ~ /^imported_path_[0-9]+$/ {
    value = substr($0, length($1) + 2)
    sub(/\r$/, "", value)
    gsub(/\\/, "/", value)
    count = split(value, parts, "/")
    if (parts[count] != "") print parts[count]
  }'
}

summarize_imported_names() {
  local total_count="$1"
  shift || true
  local names=("$@")
  ((${#names[@]} > 0)) || return 0

  local visible_count=${#names[@]}
  if (( visible_count > 2 )); then
    visible_count=2
  fi

  local summary="${names[0]}"
  if (( visible_count > 1 )); then
    summary+=", ${names[1]}"
  fi

  local remaining=0
  if [[ "$total_count" =~ ^[0-9]+$ ]]; then
    remaining=$(( total_count - visible_count ))
  else
    remaining=$(( ${#names[@]} - visible_count ))
  fi
  if (( remaining > 0 )); then
    summary+=", +${remaining} more"
  fi

  printf '%s\n' "$summary"
}

imported_names_summary() {
  local state="$1"
  local total_count="$2"
  local names_b64 name
  local names=()

  names_b64="$(printf '%s\n' "$state" | state_value imported_names_b64)"
  if [[ -n "$names_b64" ]]; then
    while IFS= read -r name || [[ -n "$name" ]]; do
      [[ -n "$name" ]] && names+=("$name")
    done < <(decode_imported_names_b64 "$names_b64")
  else
    while IFS= read -r name || [[ -n "$name" ]]; do
      [[ -n "$name" ]] && names+=("$name")
    done < <(printf '%s\n' "$state" | imported_path_names_from_state)
  fi

  ((${#names[@]} > 0)) || return 0
  summarize_imported_names "$total_count" "${names[@]}"
}

imported_names_b64_from_state() {
  local state="$1"
  local names_b64 name
  local names=()

  names_b64="$(printf '%s\n' "$state" | state_value imported_names_b64)"
  if [[ -n "$names_b64" ]]; then
    printf '%s\n' "$names_b64"
    return 0
  fi

  while IFS= read -r name || [[ -n "$name" ]]; do
    [[ -n "$name" ]] && names+=("$name")
  done < <(printf '%s\n' "$state" | imported_path_names_from_state)

  ((${#names[@]} > 0)) || return 0
  (IFS=$'\037'; printf '%s' "${names[*]}") | /usr/bin/base64 | tr -d '\n'
  printf '\n'
}

write_transfer_result_state() {
  local state_path="${MOONLIGHT_TRANSFER_RESULT_STATE:-}"
  [[ -n "$state_path" ]] || return 0

  local state_dir tmp_path imported_path index
  state_dir="$(dirname "$state_path")"
  tmp_path="${state_path}.tmp"
  mkdir -p "$state_dir" 2>/dev/null || return 0
  {
    printf 'id=%s\n' "${payload_id:-}"
    printf 'kind=%s\n' "${kind:-}"
    printf 'bytes=%s\n' "${bytes:-}"
    printf 'transport=%s\n' "${transport:-}"
    printf 'confirmation=%s\n' "${windows_import_confirmation:-pending}"
    printf 'imported_paths=%s\n' "${imported_paths:-0}"
    printf 'imported_names_b64=%s\n' "${imported_names_b64:-}"
    printf 'clipboard_ready=%s\n' "${clipboard_ready:-yes}"
    if [[ "${imported_paths:-0}" =~ ^[0-9]+$ ]]; then
      for ((index = 1; index <= imported_paths; index++)); do
        imported_path="$(printf '%s\n' "${windows_import_state:-}" | state_value "imported_path_${index}")"
        if [[ -n "$imported_path" ]]; then
          printf 'imported_path_%s=%s\n' "$index" "$imported_path"
        fi
      done
    fi
  } > "$tmp_path" 2>/dev/null && mv "$tmp_path" "$state_path" 2>/dev/null || rm -f "$tmp_path"
}

encode_powershell() {
  iconv -f UTF-8 -t UTF-16LE | base64 | tr -d '\n'
}

read_windows_import_state() {
  local expected_id="$1"
  local script encoded
  script="\$ErrorActionPreference = 'SilentlyContinue'; \$expected = '${expected_id}'; \$dir = Join-Path \$env:USERPROFILE '.moonlight-clipboard-sync'; \$path = Join-Path \$dir 'mac-to-windows-import-state.txt'; \$deadline = (Get-Date).AddMilliseconds(${MOONLIGHT_TRANSFER_CONFIRM_TIMEOUT_MS}); do { if (Test-Path -LiteralPath \$path) { \$text = Get-Content -LiteralPath \$path -Raw -Encoding UTF8; if (\$text -match ('(?m)^id=' + [regex]::Escape(\$expected) + '\\r?\$')) { Write-Output \$text; exit 0 } }; Start-Sleep -Milliseconds 150 } while ((Get-Date) -lt \$deadline); exit 1"
  encoded="$(printf '%s' "$script" | encode_powershell)"
  ssh "${ssh_opts[@]}" "$WINDOWS_SSH" \
    "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand ${encoded}"
}

wait_for_windows_import() {
  local expected_id="$1"
  local state state_id
  [[ -n "$expected_id" ]] || return 1

  if [[ -n "${tcp_ack_state:-}" ]]; then
    state_id="$(printf '%s\n' "$tcp_ack_state" | state_value id)"
    if [[ "$state_id" == "$expected_id" ]]; then
      windows_import_state="$tcp_ack_state"
      windows_import_confirmation="tcp-ack"
      state="$(read_windows_import_state "$expected_id" 2>/dev/null || true)"
      state_id="$(printf '%s\n' "$state" | state_value id)"
      if [[ "$state_id" == "$expected_id" ]]; then
        windows_import_state="$state"
      fi
      return 0
    fi
  fi

  if [[ "$(normalize_yes_no "${MOONLIGHT_TRANSFER_REQUIRE_TCP_ACK:-no}")" == "yes" ]]; then
    return 1
  fi

  state="$(read_windows_import_state "$expected_id" 2>/dev/null || true)"
  state_id="$(printf '%s\n' "$state" | state_value id)"
  if [[ "$state_id" == "$expected_id" ]]; then
    windows_import_state="$state"
    windows_import_confirmation="ssh-state"
    return 0
  fi

  return 1
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

cleanup_remote_mac_tmp() {
  ssh "${ssh_opts[@]}" "$WINDOWS_SSH" \
    "cmd.exe /c del /Q \"${remote_mac_tmp_cmd}\" 2>nul" >/dev/null 2>&1 || true
}

ensure_helpers() {
  progress "Preparing transfer helpers."
  if [[ ! -x "$helper" || "$source_helper" -nt "$helper" ]]; then
    if ! command -v swiftc >/dev/null 2>&1; then
      echo "swiftc is required to build the macOS clipboard helper." >&2
      exit 1
    fi
    swiftc "$source_helper" -o "$helper"
  fi
  chmod 700 "$helper"

  if [[ "$(normalize_yes_no "$MOONLIGHT_CLIPBOARD_TCP")" == "yes" ]]; then
    if [[ ! -x "$tcp_helper" || "$source_tcp_helper" -nt "$tcp_helper" ]]; then
      if ! command -v swiftc >/dev/null 2>&1; then
        echo "swiftc is required to build the macOS clipboard TCP helper." >&2
        exit 1
      fi
      swiftc "$source_tcp_helper" -o "$tcp_helper"
    fi
    chmod 700 "$tcp_helper"
  fi
}

send_zip() {
  local zip_path="$1"
  if [[ "$(normalize_yes_no "$MOONLIGHT_CLIPBOARD_TCP")" == "yes" && -x "$tcp_helper" ]]; then
    local output
    progress "Sending payload over the live TCP clipboard channel."
    if output="$("$tcp_helper" send 127.0.0.1 "$MOONLIGHT_CLIPBOARD_MAC_TO_WINDOWS_TCP_LOCAL_PORT" "$zip_path" 2>/dev/null)"; then
      tcp_ack_state="$output"
      transport="tcp"
      return 0
    fi
    progress "TCP send was unavailable; falling back to SSH upload."
    log "File drop Mac -> Windows TCP unavailable; falling back to SSH payload"
  fi

  progress "Uploading payload over SSH fallback."
  ssh "${ssh_opts[@]}" "$WINDOWS_SSH" "cmd.exe /c if not exist ${remote_dir} mkdir ${remote_dir}" >/dev/null
  cleanup_remote_mac_tmp
  if ! scp "${scp_opts[@]}" "$zip_path" "${WINDOWS_SSH}:${remote_mac_tmp}" >/dev/null; then
    cleanup_remote_mac_tmp
    return 1
  fi
  if ! ssh "${ssh_opts[@]}" "$WINDOWS_SSH" "cmd.exe /c move /Y \"${remote_mac_tmp_cmd}\" \"${remote_mac_zip_cmd}\" >nul"; then
    cleanup_remote_mac_tmp
    return 1
  fi
  transport="ssh"
}

send_direct_to_windows_receive_folder() {
  local zip_path="$1"
  local transfer_dir_literal script_path state ssh_status
  transfer_dir_literal="$(ps_single_quoted "$MOONLIGHT_TRANSFER_WINDOWS_DIR")"
  script_path="${tmp_dir}/mac-to-windows-direct.ps1"

  progress "Uploading oversized payload directly to the Windows receive folder."
  ssh "${ssh_opts[@]}" "$WINDOWS_SSH" "cmd.exe /c if not exist ${remote_dir} mkdir ${remote_dir}" >/dev/null
  scp "${scp_opts[@]}" "$zip_path" "${WINDOWS_SSH}:${remote_direct_tmp}" >/dev/null

  cat > "$script_path" <<POWERSHELL
\$ErrorActionPreference = "Stop"
\$ProgressPreference = "SilentlyContinue"
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Get-NormalizedFileName(\$name) {
  if ([string]::IsNullOrWhiteSpace(\$name)) { return "file" }
  \$safeName = \$name.Normalize([System.Text.NormalizationForm]::FormC)
  foreach (\$invalidChar in [System.IO.Path]::GetInvalidFileNameChars()) {
    \$safeName = \$safeName.Replace([string]\$invalidChar, "_")
  }
  \$safeName = \$safeName.TrimEnd([char[]]@(" ", "."))
  if ([string]::IsNullOrWhiteSpace(\$safeName) -or \$safeName -eq "." -or \$safeName -eq "..") {
    \$safeName = "file"
  }

  \$reservedNames = @(
    "CON", "PRN", "AUX", "NUL",
    "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
    "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9"
  )
  \$stem = [System.IO.Path]::GetFileNameWithoutExtension(\$safeName)
  if (\$reservedNames -contains \$stem.ToUpperInvariant()) {
    \$safeName = "_\$safeName"
  }

  return \$safeName
}

function Normalize-PathTreeNames(\$path) {
  if (-not (Test-Path -LiteralPath \$path)) { return \$path }

  \$item = Get-Item -LiteralPath \$path -Force -ErrorAction Stop
  if (\$item.PSIsContainer) {
    Get-ChildItem -LiteralPath \$item.FullName -Force | ForEach-Object {
      Normalize-PathTreeNames \$_.FullName | Out-Null
    }
  }

  \$name = Split-Path -Leaf \$item.FullName
  \$normalizedName = Get-NormalizedFileName \$name
  if (\$name -eq \$normalizedName) { return \$item.FullName }

  \$parent = Split-Path -Parent \$item.FullName
  \$candidate = \$normalizedName
  \$stem = [System.IO.Path]::GetFileNameWithoutExtension(\$normalizedName)
  \$ext = [System.IO.Path]::GetExtension(\$normalizedName)
  \$index = 2
  while (Test-Path -LiteralPath (Join-Path \$parent \$candidate)) {
    \$candidate = if ([string]::IsNullOrEmpty(\$ext)) { "\$stem-\$index" } else { "\$stem-\$index\$ext" }
    \$index++
  }

  \$dest = Join-Path \$parent \$candidate
  Move-Item -LiteralPath \$item.FullName -Destination \$dest -Force -ErrorAction Stop
  return \$dest
}

function Get-UniqueDestinationPath(\$destDir, \$name, \$usedNames) {
  \$normalizedName = Get-NormalizedFileName \$name
  \$stem = [System.IO.Path]::GetFileNameWithoutExtension(\$normalizedName)
  \$ext = [System.IO.Path]::GetExtension(\$normalizedName)
  \$candidate = \$normalizedName
  \$index = 2
  while ((Test-Path -LiteralPath (Join-Path \$destDir \$candidate)) -or \$usedNames.Contains(\$candidate.ToLowerInvariant())) {
    \$candidate = if ([string]::IsNullOrEmpty(\$ext)) { "\$stem-\$index" } else { "\$stem-\$index\$ext" }
    \$index++
  }
  [void]\$usedNames.Add(\$candidate.ToLowerInvariant())
  return Join-Path \$destDir \$candidate
}

function Copy-PayloadFilesAtomically(\$payloadDir, \$items, \$destDir) {
  New-Item -ItemType Directory -Force -Path \$destDir -ErrorAction Stop | Out-Null
  if (-not (Test-Path -LiteralPath \$destDir -PathType Container)) {
    throw "receive folder path is not a directory: \$destDir"
  }
  \$usedNames = New-Object 'System.Collections.Generic.HashSet[string]'
  \$planned = @()
  foreach (\$item in \$items) {
    \$sourcePath = Join-Path \$payloadDir \$item.path
    \$targetPath = Get-UniqueDestinationPath \$destDir \$item.name \$usedNames
    \$planned += [pscustomobject]@{
      Source = \$sourcePath
      Target = \$targetPath
      Name = Split-Path -Leaf \$targetPath
    }
  }

  \$stagingDir = Join-Path \$destDir (".moonlight-companion-import-" + [guid]::NewGuid().ToString("N"))
  \$staged = @()
  \$moved = @()
  \$stagingItem = New-Item -ItemType Directory -Path \$stagingDir -ErrorAction Stop
  if (\$null -eq \$stagingItem -or -not (Test-Path -LiteralPath \$stagingDir -PathType Container)) {
    throw "could not create staging directory: \$stagingDir"
  }
  \$stagingItem.Attributes = \$stagingItem.Attributes -bor [System.IO.FileAttributes]::Hidden
  try {
    foreach (\$entry in \$planned) {
      \$stagedPath = Join-Path \$stagingDir \$entry.Name
      Copy-Item -LiteralPath \$entry.Source -Destination \$stagedPath -Recurse -Force -ErrorAction Stop
      if (-not (Test-Path -LiteralPath \$stagedPath)) {
        throw "copy did not create staging destination: \$stagedPath"
      }
      \$stagedPath = Normalize-PathTreeNames \$stagedPath
      \$staged += [pscustomobject]@{
        Path = \$stagedPath
        Target = \$entry.Target
      }
    }

    foreach (\$entry in \$staged) {
      Move-Item -LiteralPath \$entry.Path -Destination \$entry.Target -ErrorAction Stop
      \$moved += \$entry.Target
    }

    Remove-Item -LiteralPath \$stagingDir -Recurse -Force -ErrorAction SilentlyContinue
    return \$moved
  } catch {
    foreach (\$path in \$moved) {
      Remove-Item -LiteralPath \$path -Recurse -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath \$stagingDir -Recurse -Force -ErrorAction SilentlyContinue
    throw
  }
}

function Write-KeyValueState(\$path, [string[]]\$lines) {
  \$tmpPath = "\$path.tmp"
  Set-Content -LiteralPath \$tmpPath -Value \$lines -Encoding UTF8
  Move-Item -LiteralPath \$tmpPath -Destination \$path -Force
}

\$remoteDir = Join-Path \$env:USERPROFILE ".moonlight-clipboard-sync"
\$zipPath = Join-Path \$remoteDir "mac-to-windows-direct.zip"
\$tmpZipPath = Join-Path \$remoteDir "mac-to-windows-direct.zip.tmp"
\$payloadDir = Join-Path \$remoteDir "direct-mac-payload"
\$statePath = Join-Path \$remoteDir "mac-to-windows-import-state.txt"
\$transferDir = [Environment]::ExpandEnvironmentVariables(${transfer_dir_literal})
if ([string]::IsNullOrWhiteSpace(\$transferDir)) {
  \$transferDir = Join-Path \$env:USERPROFILE "Downloads\\Moonlight Companion"
}

\$directTransferError = \$null
try {
  New-Item -ItemType Directory -Force -Path \$remoteDir | Out-Null
  Move-Item -LiteralPath \$tmpZipPath -Destination \$zipPath -Force
  if (Test-Path -LiteralPath \$payloadDir) {
    Remove-Item -LiteralPath \$payloadDir -Recurse -Force
  }
  New-Item -ItemType Directory -Force -Path \$payloadDir | Out-Null
  [System.IO.Compression.ZipFile]::ExtractToDirectory(\$zipPath, \$payloadDir)
  \$manifest = Get-Content -LiteralPath (Join-Path \$payloadDir "manifest.json") -Raw -Encoding UTF8 | ConvertFrom-Json
  if (\$manifest.kind -ne "files" -or \$null -eq \$manifest.files) {
    throw "direct receive-folder transfer only supports file payloads"
  }
  \$manifestItems = @(\$manifest.files)
  if (\$manifestItems.Count -le 0) {
    throw "direct receive-folder transfer payload did not contain files"
  }

  \$targetPaths = @(Copy-PayloadFilesAtomically \$payloadDir \$manifestItems \$transferDir)
  if (\$targetPaths.Count -ne \$manifestItems.Count) {
    throw "direct receive-folder transfer copied \$(\$targetPaths.Count) of \$(\$manifestItems.Count) item(s)"
  }

  \$archiveHash = (Get-FileHash -LiteralPath \$zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
  \$fileCount = \$manifestItems.Count
  \$lines = @(
    "archive_hash=\$archiveHash",
    "id=\$(\$manifest.id)",
    "kind=\$(\$manifest.kind)",
    "bytes=\$(\$manifest.bytes)",
    "files=\$fileCount",
    "imported_paths=\$(\$targetPaths.Count)",
    "clipboard_ready=no",
    "direct_transfer=yes"
  )

  for (\$i = 0; \$i -lt \$targetPaths.Count; \$i++) {
    \$lines += "imported_path_\$(\$i + 1)=\$(\$targetPaths[\$i])"
  }

  \$names = @()
  foreach (\$path in \$targetPaths) {
    \$name = Split-Path -Leaf \$path
    if (-not [string]::IsNullOrWhiteSpace(\$name)) {
      \$names += \$name
    }
  }
  \$namesForState = @(\$names | Select-Object -First 12)
  if (\$namesForState.Count -gt 0) {
    \$namesText = [string]::Join([string][char]31, \$namesForState)
    \$namesB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes(\$namesText))
    \$lines += "imported_names_b64=\$namesB64"
  }

  Write-KeyValueState \$statePath \$lines
  \$stateText = Get-Content -LiteralPath \$statePath -Raw -Encoding UTF8
  Write-Output \$stateText
} catch {
  \$directTransferError = \$_.Exception.Message
} finally {
  Remove-Item -LiteralPath \$payloadDir -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath \$zipPath -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath \$tmpZipPath -Force -ErrorAction SilentlyContinue
}
if (\$null -ne \$directTransferError) {
  [Console]::Error.WriteLine(\$directTransferError)
  exit 1
}
POWERSHELL
  cleanup_remote_direct_script
  scp "${scp_opts[@]}" "$script_path" "${WINDOWS_SSH}:${remote_direct_script}" >/dev/null

  set +e
  state="$(
    ssh "${ssh_opts[@]}" "$WINDOWS_SSH" \
      "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ${remote_direct_script_cmd}" 2>&1
  )"
  ssh_status=$?
  set -e
  cleanup_remote_direct_script
  if (( ssh_status != 0 )); then
    printf '%s\n' "$state" >&2
    return "$ssh_status"
  fi
  printf '%s\n' "$state"
}

cleanup_remote_direct_script() {
  ssh "${ssh_opts[@]}" "$WINDOWS_SSH" \
    "cmd.exe /c del /Q \"${remote_direct_script_cmd}\" 2>nul" >/dev/null 2>&1 || true
}

if [[ $# -lt 1 ]]; then
  echo "usage: send-files-to-windows.sh <path>..." >&2
  exit 2
fi

validate_source_paths "$@"

MOONLIGHT_CLIPBOARD_MAX_BYTES="$(normalize_positive_int "$MOONLIGHT_CLIPBOARD_MAX_BYTES" 52428800)"
progress "Checking transfer size."
source_bytes="$(source_payload_bytes "$@")"
oversized_payload="no"
if (( source_bytes > MOONLIGHT_CLIPBOARD_MAX_BYTES )); then
  if [[ "$(normalize_yes_no "$MOONLIGHT_TRANSFER_OVERSIZE_DIRECT")" != "yes" ]]; then
    reject_oversized_payload "$source_bytes"
  fi
  oversized_payload="yes"
  progress "Payload exceeds the clipboard limit; using direct receive-folder transfer."
fi

ensure_helpers

MOONLIGHT_TRANSFER_CONFIRM_TIMEOUT_MS="$(normalize_positive_int "$MOONLIGHT_TRANSFER_CONFIRM_TIMEOUT_MS" 1800)"

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/moonlight-file-drop.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

payload_dir="${tmp_dir}/payload"
meta_path="${tmp_dir}/meta.txt"
zip_path="${tmp_dir}/mac-to-windows.zip"

progress "Collecting file metadata."
"$helper" export-paths "$payload_dir" "$@" > "$meta_path"
kind="$(payload_value kind "$meta_path")"
bytes="$(payload_value bytes "$meta_path")"
payload_id="$(payload_value id "$meta_path")"

if [[ -z "$bytes" ]]; then
  echo "could not read payload metadata" >&2
  exit 1
fi

if (( bytes > MOONLIGHT_CLIPBOARD_MAX_BYTES )); then
  if [[ "$(normalize_yes_no "$MOONLIGHT_TRANSFER_OVERSIZE_DIRECT")" != "yes" ]]; then
    reject_oversized_payload "$bytes"
  fi
  oversized_payload="yes"
fi

progress "Packaging ${kind:-files} payload (${bytes}B)."
zip_payload "$payload_dir" "$zip_path"
tcp_ack_state=""
transport=""
if [[ "$oversized_payload" == "yes" ]]; then
  windows_import_state="$(send_direct_to_windows_receive_folder "$zip_path")"
  imported_paths="$(printf '%s\n' "$windows_import_state" | state_value imported_paths)"
  direct_state_id="$(printf '%s\n' "$windows_import_state" | state_value id)"
  direct_transfer="$(printf '%s\n' "$windows_import_state" | state_value direct_transfer)"
  if [[ "$direct_state_id" != "$payload_id" ||
        "$direct_transfer" != "yes" ||
        ! "$imported_paths" =~ ^[0-9]+$ ||
        "$imported_paths" == "0" ]]; then
    printf '%s\n' "$windows_import_state" >&2
    echo "direct receive-folder transfer did not report a complete Windows import" >&2
    exit 1
  fi
  transport="ssh-direct"
  windows_import_confirmation="direct-ssh"
  imported_names_b64="$(imported_names_b64_from_state "$windows_import_state")"
  imported_summary="$(imported_names_summary "$windows_import_state" "${imported_paths:-0}")"
  imported_suffix=""
  if [[ -n "$imported_summary" ]]; then
    imported_suffix=": ${imported_summary}"
  fi
  clipboard_ready="no"
  write_transfer_result_state
  log "File drop Mac -> Windows ${kind:-files} (${bytes}B) via ${transport}; direct receive-folder copy"
  if [[ "${imported_paths:-0}" == "1" ]]; then
    printf 'sent oversized %s payload (%sB) via %s; Windows copied 1 item to the receive folder%s; not placed on the Windows clipboard\n' "${kind:-files}" "$bytes" "$transport" "$imported_suffix"
  else
    printf 'sent oversized %s payload (%sB) via %s; Windows copied %s items to the receive folder%s; not placed on the Windows clipboard\n' "${kind:-files}" "$bytes" "$transport" "${imported_paths:-0}" "$imported_suffix"
  fi
  exit 0
fi

send_zip "$zip_path"
log "File drop Mac -> Windows ${kind:-files} (${bytes}B) via ${transport}"
windows_import_state=""
windows_import_confirmation=""
imported_paths="0"
imported_names_b64=""
clipboard_ready="yes"
progress "Waiting for Windows receive confirmation."
if wait_for_windows_import "$payload_id"; then
  log "File drop Mac -> Windows import confirmed via ${windows_import_confirmation:-unknown}"
  imported_paths="$(printf '%s\n' "$windows_import_state" | state_value imported_paths)"
  imported_names_b64="$(imported_names_b64_from_state "$windows_import_state")"
  imported_summary="$(imported_names_summary "$windows_import_state" "${imported_paths:-0}")"
  imported_suffix=""
  if [[ -n "$imported_summary" ]]; then
    imported_suffix=": ${imported_summary}"
  fi
  write_transfer_result_state
  if [[ "${imported_paths:-0}" == "1" ]]; then
    printf 'sent %s payload (%sB) via %s; Windows confirmed 1 item in the receive folder%s\n' "${kind:-files}" "$bytes" "$transport" "$imported_suffix"
  else
    printf 'sent %s payload (%sB) via %s; Windows confirmed %s items in the receive folder%s\n' "${kind:-files}" "$bytes" "$transport" "${imported_paths:-0}" "$imported_suffix"
  fi
else
  write_transfer_result_state
  printf 'sent %s payload (%sB) via %s; Windows import confirmation is pending\n' "${kind:-files}" "$bytes" "$transport"
fi
