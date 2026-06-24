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
  script="\$ErrorActionPreference = 'SilentlyContinue'; \$dir = [Environment]::ExpandEnvironmentVariables('${MOONLIGHT_TRANSFER_WINDOWS_DIR}'); if (Test-Path -LiteralPath \$dir) { Get-ChildItem -LiteralPath \$dir -File | Where-Object { \$_.Name -like 'moonlight-companion-transfer-test-*.txt' } | Remove-Item -Force }"
  encoded="$(printf '%s' "$script" | iconv -f UTF-8 -t UTF-16LE | base64 | tr -d '\n')"
  ssh "${ssh_opts[@]}" "$WINDOWS_SSH" \
    "powershell.exe -NoProfile -NonInteractive -EncodedCommand ${encoded}" >/dev/null 2>&1 || true
}

write_windows_file() {
  local file_name="$1"
  local content="$2"
  local script encoded
  script="\$ErrorActionPreference = 'Stop'; \$ProgressPreference = 'SilentlyContinue'; \$dir = [Environment]::ExpandEnvironmentVariables('${MOONLIGHT_TRANSFER_WINDOWS_DIR}'); New-Item -ItemType Directory -Force -Path \$dir | Out-Null; Set-Content -LiteralPath (Join-Path \$dir '${file_name}') -Value '${content}' -Encoding UTF8"
  encoded="$(printf '%s' "$script" | iconv -f UTF-8 -t UTF-16LE | base64 | tr -d '\n')"
  ssh "${ssh_opts[@]}" "$WINDOWS_SSH" \
    "powershell.exe -NoProfile -NonInteractive -EncodedCommand ${encoded}" >/dev/null
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
    -name 'moonlight-companion-transfer-test-*.txt' \
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

meta_value() {
  local key="$1"
  local path="$2"
  awk -F= -v key="$key" '$1 == key {print substr($0, length(key) + 2); exit}' "$path"
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

if [[ "${MOONLIGHT_TRANSFER_TEST_SKIP_AGENT_DEPLOY:-no}" != "yes" ]]; then
  echo "Refreshing Windows agent..."
  MOONLIGHT_COMPANION_CONFIG="$config" "$deploy_agent" >/dev/null
  echo "Windows agent ready."
fi

if [[ "${MOONLIGHT_TRANSFER_TEST_SKIP_SERVICE_START:-no}" != "yes" ]]; then
  if [[ "$tcp_helper_rebuilt" == "yes" ]] || mac_tcp_receiver_stale; then
    echo "Refreshing Mac transfer services..."
    if ! restart_mac_tcp_receiver; then
      MOONLIGHT_COMPANION_CONFIG="$config" "$start_services" >/dev/null
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
    MOONLIGHT_COMPANION_CONFIG="$config" "$start_services" >/dev/null
    if ! mac_transfer_services_ready; then
      echo "Mac transfer TCP receiver did not become ready." >&2
      exit 1
    fi
    echo "Mac transfer services ready."
  fi
fi

transfer_mac_dir="$(expand_mac_path "$MOONLIGHT_TRANSFER_MAC_DIR")"
mkdir -p "$transfer_mac_dir"
cleanup_mac_self_test_files "$transfer_mac_dir"
cleanup_windows_self_test_files

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/moonlight-transfer-test.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

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

echo "Testing Mac -> Windows file transfer..."
m2w_file="${tmp_dir}/moonlight-companion-transfer-test-mac-to-windows-${stamp}.txt"
m2w_name="$(basename "$m2w_file")"
m2w_collision_name="$(collision_name "$m2w_name")"
m2w_out="${tmp_dir}/mac-to-windows-send.txt"
printf 'Moonlight Companion Mac -> Windows test %s\n' "$stamp" > "$m2w_file"
write_windows_file "$m2w_name" "existing Windows receive file ${stamp}"
send_env=(MOONLIGHT_COMPANION_CONFIG="$config")
if [[ "$(normalize_yes_no "$MOONLIGHT_CLIPBOARD_TCP")" == "yes" ]]; then
  send_env+=(MOONLIGHT_TRANSFER_REQUIRE_TCP_ACK=yes)
fi
env "${send_env[@]}" "${script_dir}/send-files-to-windows.sh" "$m2w_file" > "$m2w_out"
if ! grep -q "Windows confirmed" "$m2w_out"; then
  echo "Mac -> Windows transfer did not receive Windows import confirmation." >&2
  cat "$m2w_out" >&2
  exit 1
fi
if ! wait_for_windows_file "$m2w_collision_name"; then
  echo "Mac -> Windows transfer did not create a collision-safe file in the Windows receive folder." >&2
  exit 1
fi
remove_windows_file "$m2w_name"
remove_windows_file "$m2w_collision_name"
echo "Mac -> Windows ok."

echo "Testing Windows -> Mac file transfer..."
w2m_file="${tmp_dir}/moonlight-companion-transfer-test-windows-to-mac-${stamp}.txt"
w2m_name="$(basename "$w2m_file")"
w2m_collision_name="$(collision_name "$w2m_name")"
printf 'Moonlight Companion Windows -> Mac test %s\n' "$stamp" > "$w2m_file"
printf 'existing Mac receive file %s\n' "$stamp" > "${transfer_mac_dir}/${w2m_name}"
payload_dir="${tmp_dir}/w2m-payload"
zip_path="${tmp_dir}/windows-to-mac.zip"
MOONLIGHT_TRANSFER_MAC_DIR="$transfer_mac_dir" "$helper" export-paths "$payload_dir" "$w2m_file" >/dev/null
zip_payload "$payload_dir" "$zip_path"
MOONLIGHT_TRANSFER_NOTIFY=no MOONLIGHT_TRANSFER_REVEAL_MAC_DIR=no MOONLIGHT_TRANSFER_MAC_DIR="$transfer_mac_dir" \
  "$tcp_helper" send 127.0.0.1 "$MOONLIGHT_CLIPBOARD_WINDOWS_TO_MAC_TCP_LOCAL_PORT" "$zip_path"
if ! wait_for_mac_file "$transfer_mac_dir" "$w2m_collision_name"; then
  echo "Windows -> Mac transfer did not create a collision-safe file in the Mac receive folder." >&2
  exit 1
fi
rm -f "${transfer_mac_dir}/${w2m_name}" "${transfer_mac_dir}/${w2m_collision_name}"
echo "Windows -> Mac ok."

echo "File transfer test passed."
