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

payload_value() {
  local key="$1"
  local path="$2"
  awk -F= -v key="$key" '$1 == key {print substr($0, length(key) + 2); exit}' "$path"
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
    if "$tcp_helper" send 127.0.0.1 "$MOONLIGHT_CLIPBOARD_MAC_TO_WINDOWS_TCP_LOCAL_PORT" "$zip_path" >/dev/null 2>&1; then
      printf 'tcp\n'
      return 0
    fi
    log "File drop Mac -> Windows TCP unavailable; falling back to SSH payload"
  fi

  ssh "${ssh_opts[@]}" "$WINDOWS_SSH" "cmd.exe /c if not exist ${remote_dir} mkdir ${remote_dir}" >/dev/null
  scp "${scp_opts[@]}" "$zip_path" "${WINDOWS_SSH}:${remote_mac_tmp}" >/dev/null
  ssh "${ssh_opts[@]}" "$WINDOWS_SSH" "cmd.exe /c move /Y \"${remote_mac_tmp_cmd}\" \"${remote_mac_zip_cmd}\" >nul"
  printf 'ssh\n'
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

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/moonlight-file-drop.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

payload_dir="${tmp_dir}/payload"
meta_path="${tmp_dir}/meta.txt"
zip_path="${tmp_dir}/mac-to-windows.zip"

"$helper" export-paths "$payload_dir" "$@" > "$meta_path"
kind="$(payload_value kind "$meta_path")"
bytes="$(payload_value bytes "$meta_path")"

if [[ -z "$bytes" ]]; then
  echo "could not read payload metadata" >&2
  exit 1
fi

if (( bytes > MOONLIGHT_CLIPBOARD_MAX_BYTES )); then
  echo "payload too large: ${bytes}B > ${MOONLIGHT_CLIPBOARD_MAX_BYTES}B" >&2
  log "skip File drop Mac -> Windows ${kind:-files} (${bytes}B); limit is ${MOONLIGHT_CLIPBOARD_MAX_BYTES}B"
  exit 1
fi

zip_payload "$payload_dir" "$zip_path"
transport="$(send_zip "$zip_path")"
log "File drop Mac -> Windows ${kind:-files} (${bytes}B) via ${transport}"
printf 'sent %s payload (%sB) via %s\n' "${kind:-files}" "$bytes" "$transport"
