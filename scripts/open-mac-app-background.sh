#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
app_path="${1:-${repo_dir}/dist/Moonlight Companion.app}"
process_name="${MOONLIGHT_COMPANION_PROCESS_NAME:-Moonlight Companion}"

if pgrep -qx "$process_name" >/dev/null 2>&1; then
  exit 0
fi

open -g "$app_path" --args --background
