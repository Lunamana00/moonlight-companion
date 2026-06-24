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
source_helper="${script_dir}/moonclipctl.swift"
source_tcp_helper="${script_dir}/mooncliptcp.swift"

ssh_opts=(
  -q
  -o BatchMode=yes
  -o ConnectTimeout=5
  -o LogLevel=ERROR
  -o ServerAliveInterval=15
  -o ServerAliveCountMax=2
  -o StrictHostKeyChecking=accept-new
)

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
  fi
  chmod 700 "$tcp_helper"
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

windows_file_exists() {
  local file_name="$1"
  local script encoded
  script="\$ErrorActionPreference = 'Stop'; \$dir = [Environment]::ExpandEnvironmentVariables('${MOONLIGHT_TRANSFER_WINDOWS_DIR}'); \$path = Join-Path \$dir '${file_name}'; if (Test-Path -LiteralPath \$path) { exit 0 } else { exit 1 }"
  encoded="$(printf '%s' "$script" | iconv -f UTF-8 -t UTF-16LE | base64 | tr -d '\n')"
  ssh "${ssh_opts[@]}" "$WINDOWS_SSH" \
    "powershell.exe -NoProfile -NonInteractive -EncodedCommand ${encoded}" >/dev/null 2>&1
}

cleanup_windows_self_test_files() {
  local script encoded
  script="\$ErrorActionPreference = 'SilentlyContinue'; \$dir = [Environment]::ExpandEnvironmentVariables('${MOONLIGHT_TRANSFER_WINDOWS_DIR}'); if (Test-Path -LiteralPath \$dir) { Get-ChildItem -LiteralPath \$dir -File | Where-Object { \$_.Name -like 'mac-to-windows-*.txt' -or \$_.Name -like 'windows-to-mac-*.txt' } | Remove-Item -Force }"
  encoded="$(printf '%s' "$script" | iconv -f UTF-8 -t UTF-16LE | base64 | tr -d '\n')"
  ssh "${ssh_opts[@]}" "$WINDOWS_SSH" \
    "powershell.exe -NoProfile -NonInteractive -EncodedCommand ${encoded}" >/dev/null 2>&1 || true
}

remove_windows_file() {
  local file_name="$1"
  local script encoded
  script="\$ErrorActionPreference = 'SilentlyContinue'; \$dir = [Environment]::ExpandEnvironmentVariables('${MOONLIGHT_TRANSFER_WINDOWS_DIR}'); \$path = Join-Path \$dir '${file_name}'; if (Test-Path -LiteralPath \$path -PathType Leaf) { Remove-Item -LiteralPath \$path -Force }"
  encoded="$(printf '%s' "$script" | iconv -f UTF-8 -t UTF-16LE | base64 | tr -d '\n')"
  ssh "${ssh_opts[@]}" "$WINDOWS_SSH" \
    "powershell.exe -NoProfile -NonInteractive -EncodedCommand ${encoded}" >/dev/null 2>&1 || true
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

cleanup_mac_self_test_files() {
  local directory="$1"
  find "$directory" -maxdepth 1 -type f \
    \( -name 'mac-to-windows-*.txt' -o -name 'windows-to-mac-*.txt' \) \
    -delete 2>/dev/null || true
}

wait_for_mac_file() {
  local directory="$1"
  local file_name="$2"
  for _ in {1..20}; do
    if [[ -f "${directory}/${file_name}" ]]; then
      return 0
    fi
    sleep 0.25
  done
  return 1
}

if [[ "$(tr '[:upper:]' '[:lower:]' <<<"$MOONLIGHT_CLIPBOARD_TCP")" != "yes" ]]; then
  echo "Clipboard TCP is disabled; enable MOONLIGHT_CLIPBOARD_TCP for the live transfer test." >&2
  exit 1
fi

ensure_helpers

transfer_mac_dir="$(expand_mac_path "$MOONLIGHT_TRANSFER_MAC_DIR")"
mkdir -p "$transfer_mac_dir"
cleanup_mac_self_test_files "$transfer_mac_dir"
cleanup_windows_self_test_files

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/moonlight-transfer-test.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

stamp="$(date -u +%Y%m%dT%H%M%SZ)-$$"

echo "Testing Mac -> Windows file transfer..."
m2w_file="${tmp_dir}/mac-to-windows-${stamp}.txt"
m2w_name="$(basename "$m2w_file")"
printf 'Moonlight Companion Mac -> Windows test %s\n' "$stamp" > "$m2w_file"
MOONLIGHT_COMPANION_CONFIG="$config" "${script_dir}/send-files-to-windows.sh" "$m2w_file" >/dev/null
if ! wait_for_windows_file "$m2w_name"; then
  echo "Mac -> Windows transfer did not appear in the Windows receive folder." >&2
  exit 1
fi
remove_windows_file "$m2w_name"
echo "Mac -> Windows ok."

echo "Testing Windows -> Mac file transfer..."
w2m_file="${tmp_dir}/windows-to-mac-${stamp}.txt"
w2m_name="$(basename "$w2m_file")"
printf 'Moonlight Companion Windows -> Mac test %s\n' "$stamp" > "$w2m_file"
payload_dir="${tmp_dir}/w2m-payload"
zip_path="${tmp_dir}/windows-to-mac.zip"
MOONLIGHT_TRANSFER_MAC_DIR="$transfer_mac_dir" "$helper" export-paths "$payload_dir" "$w2m_file" >/dev/null
zip_payload "$payload_dir" "$zip_path"
MOONLIGHT_TRANSFER_NOTIFY=no MOONLIGHT_TRANSFER_REVEAL_MAC_DIR=no MOONLIGHT_TRANSFER_MAC_DIR="$transfer_mac_dir" \
  "$tcp_helper" send 127.0.0.1 "$MOONLIGHT_CLIPBOARD_WINDOWS_TO_MAC_TCP_LOCAL_PORT" "$zip_path"
if ! wait_for_mac_file "$transfer_mac_dir" "$w2m_name"; then
  echo "Windows -> Mac transfer did not appear in the Mac receive folder." >&2
  exit 1
fi
rm -f "${transfer_mac_dir}/${w2m_name}"
echo "Windows -> Mac ok."

echo "File transfer test passed."
