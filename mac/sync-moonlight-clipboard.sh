#!/usr/bin/env bash
set -euo pipefail

ssh_alias_exists() {
  [[ -f "${HOME}/.ssh/config" ]] && awk '
    /^[[:space:]]*Host[[:space:]]/ {
      for (i = 2; i <= NF; i++) {
        if ($i == "moonlight-windows") {
          found = 1
        }
      }
    }
    END { exit found ? 0 : 1 }
  ' "${HOME}/.ssh/config"
}

if [[ -n "${WINDOWS_SSH:-}" ]]; then
  remote="$WINDOWS_SSH"
elif ssh_alias_exists; then
  remote="moonlight-windows"
else
  remote="windows-user@100.x.y.z"
fi

runtime_dir="${MOONLIGHT_CLIPBOARD_RUNTIME_DIR:-${HOME}/Library/Application Support/MoonlightClipboardSync}"
helper="${MOONLIGHT_CLIPBOARD_HELPER:-${runtime_dir}/moonclipctl}"
interval="${MOONLIGHT_CLIPBOARD_INTERVAL:-0.8}"
windows_interval="${MOONLIGHT_CLIPBOARD_WINDOWS_INTERVAL:-2.0}"
max_bytes="${MOONLIGHT_CLIPBOARD_MAX_BYTES:-52428800}"
log_path="${MOONLIGHT_CLIPBOARD_LOG:-${HOME}/Library/Logs/moonlight-clipboard-sync.log}"
tcp_enabled="${MOONLIGHT_CLIPBOARD_TCP_ENABLED:-${MOONLIGHT_CLIPBOARD_TCP:-yes}}"
tcp_helper="${MOONLIGHT_CLIPBOARD_TCP_HELPER:-${runtime_dir}/mooncliptcp}"
tcp_send_host="${MOONLIGHT_CLIPBOARD_TCP_SEND_HOST:-127.0.0.1}"
tcp_send_port="${MOONLIGHT_CLIPBOARD_TCP_SEND_PORT:-47331}"
tcp_state="${MOONLIGHT_CLIPBOARD_TCP_STATE:-${runtime_dir}/clipboard-tcp-windows-state.txt}"
transfer_notify="${MOONLIGHT_TRANSFER_NOTIFY:-yes}"
transfer_reveal_mac_dir="${MOONLIGHT_TRANSFER_REVEAL_MAC_DIR:-no}"
transfer_mac_dir="${MOONLIGHT_TRANSFER_MAC_DIR:-${HOME}/Downloads/Moonlight Companion}"

remote_dir=".moonlight-clipboard-sync"
remote_mac_zip="${remote_dir}/mac-to-windows.zip"
remote_mac_tmp="${remote_dir}/mac-to-windows.zip.tmp"
remote_mac_zip_cmd="${remote_dir}\\mac-to-windows.zip"
remote_mac_tmp_cmd="${remote_dir}\\mac-to-windows.zip.tmp"
remote_windows_zip="${remote_dir}/windows-to-mac.zip"

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

mkdir -p "$(dirname "$log_path")" "$runtime_dir"

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$log_path"
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

payload_id() {
  awk -F= '/^id=/{print $2; exit}' "$1"
}

payload_kind() {
  awk -F= '/^kind=/{print $2; exit}' "$1"
}

payload_bytes() {
  awk -F= '/^bytes=/{print $2; exit}' "$1"
}

payload_files() {
  awk -F= '/^files=/{print $2; exit}' "$1"
}

file_hash() {
  shasum -a 256 "$1" | awk '{print $1}'
}

state_value() {
  local key="$1"
  local path="$2"
  awk -F= -v key="$key" '$1 == key {print substr($0, length(key) + 2); exit}' "$path"
}

dir_size_bytes() {
  du -sk "$1" | awk '{print $1 * 1024}'
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

unzip_payload() {
  local zip_path="$1"
  local dest_dir="$2"
  rm -rf "$dest_dir"
  mkdir -p "$dest_dir"
  /usr/bin/ditto -x -k --noqtn "$zip_path" "$dest_dir"
}

upload_to_windows() {
  local zip_path="$1"
  upload_transport="ssh"
  if [[ "$tcp_enabled" == "yes" && -x "$tcp_helper" ]]; then
    if "$tcp_helper" send "$tcp_send_host" "$tcp_send_port" "$zip_path" >/dev/null 2>&1; then
      upload_transport="tcp"
      return 0
    fi
    log "Mac -> Windows TCP unavailable; falling back to SSH payload"
  fi

  scp "${scp_opts[@]}" "$zip_path" "${remote}:${remote_mac_tmp}" >/dev/null
  ssh "${ssh_opts[@]}" "$remote" "cmd.exe /c move /Y \"${remote_mac_tmp_cmd}\" \"${remote_mac_zip_cmd}\" >nul"
}

download_from_windows() {
  local zip_path="$1"
  scp "${scp_opts[@]}" "${remote}:${remote_windows_zip}" "$zip_path" >/dev/null
}

require_ready() {
  if [[ ! -x "$helper" ]]; then
    log "missing helper: $helper"
    exit 1
  fi

  if ! ssh "${ssh_opts[@]}" "$remote" "cmd.exe /c if not exist ${remote_dir} mkdir ${remote_dir}" >/dev/null 2>&1; then
    log "passwordless SSH to ${remote} failed; run Setup Moonlight Clipboard SSH.app"
    exit 1
  fi
}

read_tcp_state() {
  [[ "$tcp_enabled" == "yes" ]] || return 0
  [[ -f "$tcp_state" ]] || return 0

  local state_hash archive_hash win_id normalized_id
  state_hash="$(file_hash "$tcp_state" 2>/dev/null || true)"
  [[ -n "$state_hash" && "$state_hash" != "$last_tcp_state_hash" ]] || return 0

  win_id="$(state_value "windows_id" "$tcp_state")"
  [[ -n "$win_id" ]] || return 0

  archive_hash="$(state_value "archive_hash" "$tcp_state")"
  normalized_id="$(state_value "normalized_id" "$tcp_state")"
  last_tcp_state_hash="$state_hash"
  if [[ -n "$archive_hash" ]]; then
    last_windows_archive_hash="$archive_hash"
  fi
  last_windows_id="$win_id"
  if [[ -n "$normalized_id" ]]; then
    last_mac_id="$normalized_id"
  else
    last_mac_id="$win_id"
  fi
  return 0
}

notify_windows_files_received() {
  local meta_path="$1"
  local kind count item_text

  kind="$(payload_kind "$meta_path")"
  [[ "$kind" == "files" ]] || return 0

  count="$(payload_files "$meta_path")"
  if [[ "$count" == "1" ]]; then
    item_text="1 item"
  else
    item_text="${count:-1} items"
  fi

  if [[ "$(normalize_yes_no "$transfer_notify")" == "yes" ]]; then
    /usr/bin/osascript -e '
on run argv
  display notification (item 1 of argv) with title "Moonlight Companion" subtitle "Files received from Windows"
end run
' "Received ${item_text} from Windows. Paste in Finder or open the Mac receive folder." >/dev/null 2>&1 || true
  fi

  if [[ "$(normalize_yes_no "$transfer_reveal_mac_dir")" == "yes" ]]; then
    /usr/bin/open "$transfer_mac_dir" >/dev/null 2>&1 || true
  fi
}

tcp_enabled="$(normalize_yes_no "$tcp_enabled")"

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/moonlight-clipboard-sync.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

mac_payload="${tmp_dir}/mac-payload"
mac_meta="${tmp_dir}/mac-meta.txt"
mac_normalized_payload="${tmp_dir}/mac-normalized-payload"
mac_normalized_meta="${tmp_dir}/mac-normalized-meta.txt"
mac_zip="${tmp_dir}/mac-to-windows.zip"
windows_zip="${tmp_dir}/windows-to-mac.zip"
windows_payload="${runtime_dir}/imported-windows-payload"

last_mac_id=""
last_windows_id=""
last_windows_archive_hash=""
last_windows_poll="0"
last_tcp_state_hash=""
upload_transport="ssh"

log "starting payload sync with ${remote}; local interval=${interval}s, windows interval=${windows_interval}s, max=${max_bytes}B, tcp=${tcp_enabled}"
require_ready

while true; do
  read_tcp_state

  if "$helper" export "$mac_payload" > "$mac_meta" 2>/dev/null; then
    mac_id="$(payload_id "$mac_meta")"
    mac_kind="$(payload_kind "$mac_meta")"
    mac_bytes="$(payload_bytes "$mac_meta")"

    if [[ -n "$mac_id" && "$mac_id" != "$last_mac_id" ]]; then
      read_tcp_state
      if [[ "$mac_id" == "$last_windows_id" ]]; then
        last_mac_id="$mac_id"
      elif (( mac_bytes > max_bytes )); then
        log "skip Mac -> Windows ${mac_kind} (${mac_bytes}B); limit is ${max_bytes}B"
        last_mac_id="$mac_id"
      else
        zip_payload "$mac_payload" "$mac_zip"
        if upload_to_windows "$mac_zip"; then
          last_mac_id="$mac_id"
          log "Mac -> Windows ${mac_kind} (${mac_bytes}B) via ${upload_transport}"
        else
          log "Mac -> Windows failed"
        fi
      fi
    fi
  fi

  now="$(date +%s)"
  if awk "BEGIN { exit !(($now - $last_windows_poll) >= $windows_interval) }"; then
    last_windows_poll="$now"
    if download_from_windows "$windows_zip" 2>/dev/null; then
      archive_hash="$(file_hash "$windows_zip")"
      if [[ "$archive_hash" != "$last_windows_archive_hash" ]]; then
        unzip_payload "$windows_zip" "$windows_payload"
        if "$helper" import "$windows_payload" > "${tmp_dir}/windows-meta.txt" 2>/dev/null; then
          win_id="$(payload_id "${tmp_dir}/windows-meta.txt")"
          win_kind="$(payload_kind "${tmp_dir}/windows-meta.txt")"
          win_bytes="$(payload_bytes "${tmp_dir}/windows-meta.txt")"
          notify_windows_files_received "${tmp_dir}/windows-meta.txt"
          normalized_id="$win_id"
          if "$helper" export "$mac_normalized_payload" > "$mac_normalized_meta" 2>/dev/null; then
            normalized_id="$(payload_id "$mac_normalized_meta")"
          fi
          last_windows_archive_hash="$archive_hash"
          last_windows_id="$win_id"
          last_mac_id="$normalized_id"
          log "Windows -> Mac ${win_kind} (${win_bytes}B)"
        else
          log "Windows -> Mac import failed"
        fi
      fi
    fi
  fi

  sleep "$interval"
done
