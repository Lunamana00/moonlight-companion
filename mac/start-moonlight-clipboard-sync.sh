#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_dir="$(cd "${script_dir}/.." && pwd)"
source_sync_script="${script_dir}/sync-moonlight-clipboard.sh"
source_helper="${script_dir}/moonclipctl.swift"
source_clip_tcp_helper="${script_dir}/mooncliptcp.swift"
source_caps_helper="${script_dir}/mooncapsync.swift"
runtime_dir="${HOME}/Library/Application Support/MoonlightClipboardSync"
sync_script="${runtime_dir}/sync-moonlight-clipboard.sh"
helper="${runtime_dir}/moonclipctl"
clip_tcp_helper="${runtime_dir}/mooncliptcp"
caps_app="${HOME}/Applications/Moonlight Caps Lock Hangul.app"
legacy_caps_app="${runtime_dir}/Moonlight Caps Lock Hangul.app"
caps_app_contents="${caps_app}/Contents"
caps_app_macos="${caps_app_contents}/MacOS"
caps_helper="${caps_app_macos}/mooncapsync"
label="com.lunamana.moonlight-clipboard-sync"
clip_tcp_label="com.lunamana.moonlight-clipboard-tcp-receiver"
clip_tunnel_label="com.lunamana.moonlight-clipboard-tunnel"
caps_label="com.lunamana.moonlight-capslock-hangul"
caps_tunnel_label="com.lunamana.moonlight-capslock-tunnel"
plist="${HOME}/Library/LaunchAgents/${label}.plist"
clip_tcp_plist="${HOME}/Library/LaunchAgents/${clip_tcp_label}.plist"
clip_tunnel_plist="${HOME}/Library/LaunchAgents/${clip_tunnel_label}.plist"
caps_plist="${HOME}/Library/LaunchAgents/${caps_label}.plist"
caps_tunnel_plist="${HOME}/Library/LaunchAgents/${caps_tunnel_label}.plist"
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

clip_tcp_enabled="$(normalize_yes_no "${MOONLIGHT_CLIPBOARD_TCP:-yes}")"
clip_m2w_remote_port="${MOONLIGHT_CLIPBOARD_MAC_TO_WINDOWS_TCP_PORT:-47331}"
clip_m2w_local_port="${MOONLIGHT_CLIPBOARD_MAC_TO_WINDOWS_TCP_LOCAL_PORT:-$clip_m2w_remote_port}"
clip_w2m_remote_port="${MOONLIGHT_CLIPBOARD_WINDOWS_TO_MAC_TCP_PORT:-47332}"
clip_w2m_local_port="${MOONLIGHT_CLIPBOARD_WINDOWS_TO_MAC_TCP_LOCAL_PORT:-$clip_w2m_remote_port}"
caps_tcp_remote_port="${MOONLIGHT_CAPSLOCK_HANGUL_TCP_PORT:-47321}"
caps_tcp_local_port="${MOONLIGHT_CAPSLOCK_HANGUL_TCP_LOCAL_PORT:-$caps_tcp_remote_port}"
transfer_mac_dir="${MOONLIGHT_TRANSFER_MAC_DIR:-${HOME}/Downloads/Moonlight Companion}"
transfer_notify="$(normalize_yes_no "${MOONLIGHT_TRANSFER_NOTIFY:-yes}")"
transfer_reveal_mac_dir="$(normalize_yes_no "${MOONLIGHT_TRANSFER_REVEAL_MAC_DIR:-no}")"

if [[ ! -x "$helper" || "$source_helper" -nt "$helper" ]]; then
  if ! command -v swiftc >/dev/null 2>&1; then
    echo "swiftc is required to build the macOS clipboard helper." >&2
    exit 1
  fi
  swiftc "$source_helper" -o "$helper"
fi
chmod 700 "$helper"

if [[ "$clip_tcp_enabled" == "yes" ]]; then
  if [[ ! -x "$clip_tcp_helper" || "$source_clip_tcp_helper" -nt "$clip_tcp_helper" ]]; then
    if ! command -v swiftc >/dev/null 2>&1; then
      echo "swiftc is required to build the macOS clipboard TCP helper." >&2
      exit 1
    fi
    swiftc "$source_clip_tcp_helper" -o "$clip_tcp_helper"
  fi
  chmod 700 "$clip_tcp_helper"
fi

capslock_hangul="$(normalize_yes_no "${MOONLIGHT_CAPSLOCK_HANGUL:-yes}")"
shortcut_remap="$(normalize_yes_no "${MOONLIGHT_SHORTCUT_REMAP:-yes}")"
keyboard_helper_enabled="no"
if [[ "$capslock_hangul" == "yes" || "$shortcut_remap" == "yes" ]]; then
  keyboard_helper_enabled="yes"
fi

if [[ "$keyboard_helper_enabled" == "yes" ]]; then
  if [[ "$legacy_caps_app" != "$caps_app" && -d "$legacy_caps_app" ]]; then
    rm -rf "$legacy_caps_app"
  fi

  mkdir -p "$caps_app_macos"
  if [[ ! -x "$caps_helper" || "$source_caps_helper" -nt "$caps_helper" ]]; then
    if ! command -v swiftc >/dev/null 2>&1; then
      echo "swiftc is required to build the macOS Caps Lock helper." >&2
      exit 1
    fi
    swiftc "$source_caps_helper" -o "$caps_helper" -framework AppKit -framework ApplicationServices
  fi
  chmod 700 "$caps_helper"

  cat > "${caps_app_contents}/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>mooncapsync</string>
  <key>CFBundleIdentifier</key>
  <string>${caps_label}</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>Moonlight Caps Lock Hangul</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.3.0</string>
  <key>CFBundleVersion</key>
  <string>3</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSAccessibilityUsageDescription</key>
  <string>Detect Moonlight keyboard shortcuts so Caps Lock and Command shortcuts can be translated for Windows.</string>
</dict>
</plist>
EOF

  if command -v codesign >/dev/null 2>&1; then
    # Keep the ad-hoc designated requirement stable across helper rebuilds so TCC
    # does not bind Accessibility permission to a stale cdhash after updates.
    codesign \
      --force \
      --deep \
      --sign - \
      --identifier "$caps_label" \
      --requirements "=designated => identifier \"${caps_label}\"" \
      "$caps_app" >/dev/null 2>&1 || true
  fi
fi

if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "$remote" "powershell.exe -NoProfile -Command \"Write-Output ok\"" >/dev/null 2>&1; then
  cat >&2 <<EOF
Passwordless SSH is not ready.

Run this first:
  ${script_dir}/setup-moonlight-clipboard-key.sh

Then start clipboard sync again.
EOF
  exit 1
fi

if [[ "$clip_tcp_enabled" == "yes" ]]; then
  cat > "$clip_tcp_plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${clip_tcp_label}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${clip_tcp_helper}</string>
    <string>listen</string>
    <string>127.0.0.1</string>
    <string>${clip_w2m_local_port}</string>
    <string>${runtime_dir}</string>
    <string>${helper}</string>
    <string>${MOONLIGHT_CLIPBOARD_MAX_BYTES:-52428800}</string>
    <string>${log_dir}/moonlight-clipboard-sync.log</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${log_dir}/moonlight-clipboard-tcp.out.log</string>
  <key>StandardErrorPath</key>
  <string>${log_dir}/moonlight-clipboard-tcp.err.log</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>MOONLIGHT_TRANSFER_MAC_DIR</key>
    <string>${transfer_mac_dir}</string>
    <key>MOONLIGHT_TRANSFER_NOTIFY</key>
    <string>${transfer_notify}</string>
    <key>MOONLIGHT_TRANSFER_REVEAL_MAC_DIR</key>
    <string>${transfer_reveal_mac_dir}</string>
  </dict>
</dict>
</plist>
EOF

  launchctl bootout "gui/$(id -u)" "$clip_tcp_plist" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$(id -u)" "$clip_tcp_plist"
  launchctl enable "gui/$(id -u)/${clip_tcp_label}"
  launchctl kickstart -k "gui/$(id -u)/${clip_tcp_label}"

  cat > "$clip_tunnel_plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${clip_tunnel_label}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/ssh</string>
    <string>-N</string>
    <string>-T</string>
    <string>-o</string>
    <string>ExitOnForwardFailure=yes</string>
    <string>-o</string>
    <string>ServerAliveInterval=15</string>
    <string>-o</string>
    <string>ServerAliveCountMax=2</string>
    <string>-o</string>
    <string>BatchMode=yes</string>
    <string>-o</string>
    <string>ConnectTimeout=7</string>
    <string>-o</string>
    <string>LogLevel=ERROR</string>
    <string>-o</string>
    <string>StrictHostKeyChecking=accept-new</string>
    <string>-L</string>
    <string>127.0.0.1:${clip_m2w_local_port}:127.0.0.1:${clip_m2w_remote_port}</string>
    <string>-R</string>
    <string>127.0.0.1:${clip_w2m_remote_port}:127.0.0.1:${clip_w2m_local_port}</string>
    <string>${remote}</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${log_dir}/moonlight-clipboard-tunnel.out.log</string>
  <key>StandardErrorPath</key>
  <string>${log_dir}/moonlight-clipboard-tunnel.err.log</string>
</dict>
</plist>
EOF

  launchctl bootout "gui/$(id -u)" "$clip_tunnel_plist" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$(id -u)" "$clip_tunnel_plist"
  launchctl enable "gui/$(id -u)/${clip_tunnel_label}"
  launchctl kickstart -k "gui/$(id -u)/${clip_tunnel_label}"
else
  launchctl bootout "gui/$(id -u)" "$clip_tunnel_plist" >/dev/null 2>&1 || true
  launchctl bootout "gui/$(id -u)" "$clip_tcp_plist" >/dev/null 2>&1 || true
  rm -f "$clip_tunnel_plist"
  rm -f "$clip_tcp_plist"
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
    <key>MOONLIGHT_CLIPBOARD_TCP_ENABLED</key>
    <string>${clip_tcp_enabled}</string>
    <key>MOONLIGHT_CLIPBOARD_TCP_HELPER</key>
    <string>${clip_tcp_helper}</string>
    <key>MOONLIGHT_CLIPBOARD_TCP_SEND_HOST</key>
    <string>127.0.0.1</string>
    <key>MOONLIGHT_CLIPBOARD_TCP_SEND_PORT</key>
    <string>${clip_m2w_local_port}</string>
    <key>MOONLIGHT_CLIPBOARD_TCP_STATE</key>
    <string>${runtime_dir}/clipboard-tcp-windows-state.txt</string>
    <key>MOONLIGHT_TRANSFER_MAC_DIR</key>
    <string>${transfer_mac_dir}</string>
    <key>MOONLIGHT_TRANSFER_NOTIFY</key>
    <string>${transfer_notify}</string>
    <key>MOONLIGHT_TRANSFER_REVEAL_MAC_DIR</key>
    <string>${transfer_reveal_mac_dir}</string>
  </dict>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)" "$plist" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$(id -u)" "$plist"
launchctl enable "gui/$(id -u)/${label}"
launchctl kickstart -k "gui/$(id -u)/${label}"

if [[ "$capslock_hangul" == "yes" ]]; then
  cat > "$caps_tunnel_plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${caps_tunnel_label}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/ssh</string>
    <string>-N</string>
    <string>-T</string>
    <string>-o</string>
    <string>ExitOnForwardFailure=yes</string>
    <string>-o</string>
    <string>ServerAliveInterval=15</string>
    <string>-o</string>
    <string>ServerAliveCountMax=2</string>
    <string>-o</string>
    <string>BatchMode=yes</string>
    <string>-o</string>
    <string>ConnectTimeout=7</string>
    <string>-o</string>
    <string>LogLevel=ERROR</string>
    <string>-o</string>
    <string>StrictHostKeyChecking=accept-new</string>
    <string>-L</string>
    <string>127.0.0.1:${caps_tcp_local_port}:127.0.0.1:${caps_tcp_remote_port}</string>
    <string>${remote}</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${log_dir}/moonlight-capslock-tunnel.out.log</string>
  <key>StandardErrorPath</key>
  <string>${log_dir}/moonlight-capslock-tunnel.err.log</string>
</dict>
</plist>
EOF

  launchctl bootout "gui/$(id -u)" "$caps_tunnel_plist" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$(id -u)" "$caps_tunnel_plist"
  launchctl enable "gui/$(id -u)/${caps_tunnel_label}"
  launchctl kickstart -k "gui/$(id -u)/${caps_tunnel_label}"
else
  launchctl bootout "gui/$(id -u)" "$caps_tunnel_plist" >/dev/null 2>&1 || true
  rm -f "$caps_tunnel_plist"
fi

if [[ "$keyboard_helper_enabled" == "yes" ]]; then
  cat > "$caps_plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${caps_label}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${caps_helper}</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${log_dir}/moonlight-capslock-hangul.out.log</string>
  <key>StandardErrorPath</key>
  <string>${log_dir}/moonlight-capslock-hangul.log</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>WINDOWS_SSH</key>
    <string>${remote}</string>
    <key>MOONLIGHT_CAPSLOCK_HANGUL_HOST</key>
    <string>127.0.0.1</string>
    <key>MOONLIGHT_CAPSLOCK_HANGUL_PORT</key>
    <string>${caps_tcp_local_port}</string>
    <key>MOONLIGHT_CAPSLOCK_HANGUL</key>
    <string>${capslock_hangul}</string>
    <key>MOONLIGHT_SHORTCUT_REMAP</key>
    <string>${shortcut_remap}</string>
  </dict>
</dict>
</plist>
EOF

  launchctl bootout "gui/$(id -u)" "$caps_plist" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$(id -u)" "$caps_plist"
  launchctl enable "gui/$(id -u)/${caps_label}"
  launchctl kickstart -k "gui/$(id -u)/${caps_label}"
else
  launchctl bootout "gui/$(id -u)" "$caps_plist" >/dev/null 2>&1 || true
  rm -f "$caps_plist"
fi

echo "Moonlight clipboard sync started."
echo "Log: ${log_dir}/moonlight-clipboard-sync.log"
if [[ "$clip_tcp_enabled" == "yes" ]]; then
  echo "Clipboard TCP channels started."
fi
if [[ "$capslock_hangul" == "yes" ]]; then
  echo "Caps Lock Hangul sync started."
  echo "Caps Lock log: ${log_dir}/moonlight-capslock-hangul.log"
fi
if [[ "$shortcut_remap" == "yes" ]]; then
  echo "Moonlight Command-to-Control shortcut remap started."
  echo "Shortcut remap log: ${log_dir}/moonlight-capslock-hangul.log"
fi
