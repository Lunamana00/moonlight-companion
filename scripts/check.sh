#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"

mkdir -p "${repo_dir}/build"

bash -n \
  "${repo_dir}/scripts/build-mac-app.sh" \
  "${repo_dir}/scripts/open-mac-app-background.sh" \
  "${repo_dir}/scripts/package-release.sh" \
  "${repo_dir}/mac/moonlight-companion-launch.sh" \
  "${repo_dir}/mac/deploy-windows-agent.sh" \
  "${repo_dir}/mac/start-moonlight-clipboard-sync.sh" \
  "${repo_dir}/mac/copy-windows-receive-to-clipboard.sh" \
  "${repo_dir}/mac/open-windows-receive-folder.sh" \
  "${repo_dir}/mac/send-files-to-windows.sh" \
  "${repo_dir}/mac/test-file-transfer.sh" \
  "${repo_dir}/mac/status-moonlight-clipboard-sync.sh" \
  "${repo_dir}/mac/stop-moonlight-clipboard-sync.sh" \
  "${repo_dir}/mac/sync-moonlight-clipboard.sh"

swiftc "${repo_dir}/mac/moonclipctl.swift" -o "${repo_dir}/build/moonclipctl-check"
swiftc "${repo_dir}/mac/mooncliptcp.swift" -o "${repo_dir}/build/mooncliptcp-check"
swiftc "${repo_dir}/mac/mooncapsync.swift" -o "${repo_dir}/build/mooncapsync-check" -framework AppKit -framework ApplicationServices
swiftc "${repo_dir}/mac/MoonlightCompanionApp.swift" -o "${repo_dir}/build/MoonlightCompanionApp-check" -framework AppKit

echo "ok"
