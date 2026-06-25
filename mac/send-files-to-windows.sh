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

  local state_dir tmp_path
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
  scp "${scp_opts[@]}" "$zip_path" "${WINDOWS_SSH}:${remote_mac_tmp}" >/dev/null
  ssh "${ssh_opts[@]}" "$WINDOWS_SSH" "cmd.exe /c move /Y \"${remote_mac_tmp_cmd}\" \"${remote_mac_zip_cmd}\" >nul"
  transport="ssh"
}

if [[ $# -lt 1 ]]; then
  echo "usage: send-files-to-windows.sh <path>..." >&2
  exit 2
fi

for path in "$@"; do
  if [[ ! -e "$path" ]]; then
    echo "missing path: $path" >&2
    exit 1
  fi
done

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
  bytes_text="$(format_bytes "$bytes")"
  max_bytes_text="$(format_bytes "$MOONLIGHT_CLIPBOARD_MAX_BYTES")"
  echo "payload too large: ${bytes_text} exceeds the ${max_bytes_text} clipboard transfer limit. Split the transfer or use a file sync tool for large files." >&2
  log "skip File drop Mac -> Windows ${kind:-files} (${bytes}B); limit is ${MOONLIGHT_CLIPBOARD_MAX_BYTES}B"
  exit 1
fi

progress "Packaging ${kind:-files} payload (${bytes}B)."
zip_payload "$payload_dir" "$zip_path"
tcp_ack_state=""
transport=""
send_zip "$zip_path"
log "File drop Mac -> Windows ${kind:-files} (${bytes}B) via ${transport}"
windows_import_state=""
windows_import_confirmation=""
imported_paths="0"
imported_names_b64=""
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
