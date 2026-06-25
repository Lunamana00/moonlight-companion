#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
dist_dir="${repo_dir}/dist"
app_path="${dist_dir}/Moonlight Companion.app"
contents_dir="${app_path}/Contents"
macos_dir="${contents_dir}/MacOS"
resources_dir="${contents_dir}/Resources"
executable_name="Moonlight Companion"
include_local_config="${MOONLIGHT_COMPANION_INCLUDE_LOCAL_CONFIG:-yes}"

mkdir -p "$dist_dir"
rm -rf "$app_path"
mkdir -p "$macos_dir" "$resources_dir/mac" "$resources_dir/windows" "$resources_dir/config"

swiftc \
  "${repo_dir}/mac/MoonlightCompanionApp.swift" \
  -o "${macos_dir}/${executable_name}" \
  -framework AppKit

cp \
  "${repo_dir}/mac/moonlight-companion-launch.sh" \
  "${repo_dir}/mac/deploy-windows-agent.sh" \
  "${repo_dir}/mac/start-moonlight-clipboard-sync.sh" \
  "${repo_dir}/mac/copy-windows-receive-to-clipboard.sh" \
  "${repo_dir}/mac/open-windows-receive-folder.sh" \
  "${repo_dir}/mac/send-files-to-windows.sh" \
  "${repo_dir}/mac/test-file-transfer.sh" \
  "${repo_dir}/mac/status-moonlight-clipboard-sync.sh" \
  "${repo_dir}/mac/stop-moonlight-clipboard-sync.sh" \
  "${repo_dir}/mac/sync-moonlight-clipboard.sh" \
  "${repo_dir}/mac/moonclipctl.swift" \
  "${repo_dir}/mac/mooncliptcp.swift" \
  "${repo_dir}/mac/mooncapsync.swift" \
  "${resources_dir}/mac/"
chmod 755 "${resources_dir}/mac/"*.sh

cp \
  "${repo_dir}/windows/windows-clipboard-agent.ps1" \
  "${repo_dir}/windows/start-windows-clipboard-agent.cmd" \
  "${repo_dir}/windows/start-windows-clipboard-agent.vbs" \
  "${resources_dir}/windows/"

cp "${repo_dir}/config/moonlight-companion.conf.example" "${resources_dir}/config/"
if [[ "$include_local_config" == "yes" && -f "${repo_dir}/config/moonlight-companion.conf" ]]; then
  cp "${repo_dir}/config/moonlight-companion.conf" "${resources_dir}/config/"
fi

cat > "${contents_dir}/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>${executable_name}</string>
  <key>CFBundleIdentifier</key>
  <string>com.lunamana.moonlight-companion</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>Moonlight Companion</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.3.0</string>
  <key>CFBundleVersion</key>
  <string>3</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
EOF

echo "$app_path"
