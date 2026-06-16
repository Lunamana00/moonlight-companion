#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_dir="$(cd "${script_dir}/.." && pwd)"
source_sync_script="${script_dir}/sync-moonlight-clipboard.sh"
source_helper="${script_dir}/moonclipctl.swift"
runtime_dir="${HOME}/Library/Application Support/MoonlightClipboardSync"
sync_script="${runtime_dir}/sync-moonlight-clipboard.sh"
helper="${runtime_dir}/moonclipctl"
label="com.lunamana.moonlight-clipboard-sync"
plist="${HOME}/Library/LaunchAgents/${label}.plist"
log_dir="${HOME}/Library/Logs"
config="${MOONLIGHT_COMPANION_CONFIG:-${repo_dir}/config/moonlight-companion.conf}"

if [[ ! -f "$config" ]]; then
  config="${repo_dir}/config/moonlight-companion.conf.example"
fi

if [[ -f "$config" ]]; then
  # shellcheck source=/dev/null
  source "$config"
fi

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

mkdir -p "${HOME}/Library/LaunchAgents" "$log_dir" "$runtime_dir"
cp "$source_sync_script" "$sync_script"
chmod 700 "$sync_script"

if [[ ! -x "$helper" || "$source_helper" -nt "$helper" ]]; then
  if ! command -v swiftc >/dev/null 2>&1; then
    echo "swiftc is required to build the macOS clipboard helper." >&2
    exit 1
  fi
  swiftc "$source_helper" -o "$helper"
fi
chmod 700 "$helper"

if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "$remote" "powershell.exe -NoProfile -Command \"Write-Output ok\"" >/dev/null 2>&1; then
  cat >&2 <<EOF
Passwordless SSH is not ready.

Run this first:
  ${script_dir}/setup-moonlight-clipboard-key.sh

Then start clipboard sync again.
EOF
  exit 1
fi

cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${label}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${sync_script}</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${log_dir}/moonlight-clipboard-sync.out.log</string>
  <key>StandardErrorPath</key>
  <string>${log_dir}/moonlight-clipboard-sync.err.log</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>MOONLIGHT_CLIPBOARD_RUNTIME_DIR</key>
    <string>${runtime_dir}</string>
    <key>MOONLIGHT_CLIPBOARD_HELPER</key>
    <string>${helper}</string>
    <key>WINDOWS_SSH</key>
    <string>${remote}</string>
    <key>MOONLIGHT_CLIPBOARD_MAX_BYTES</key>
    <string>${MOONLIGHT_CLIPBOARD_MAX_BYTES:-52428800}</string>
  </dict>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)" "$plist" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$(id -u)" "$plist"
launchctl enable "gui/$(id -u)/${label}"
launchctl kickstart -k "gui/$(id -u)/${label}"

echo "Moonlight clipboard sync started."
echo "Log: ${log_dir}/moonlight-clipboard-sync.log"
