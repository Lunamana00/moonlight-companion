#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
dist_dir="${repo_dir}/dist"
release_dir="${dist_dir}/release"
app_path="${dist_dir}/Moonlight Companion.app"

MOONLIGHT_COMPANION_INCLUDE_LOCAL_CONFIG=no "${repo_dir}/scripts/build-mac-app.sh" >/dev/null

if [[ -f "${app_path}/Contents/Resources/config/moonlight-companion.conf" ]]; then
  echo "release app unexpectedly contains local config/moonlight-companion.conf" >&2
  exit 1
fi

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${app_path}/Contents/Info.plist")"
artifact_name="Moonlight-Companion-v${version}.zip"
zip_path="${release_dir}/${artifact_name}"
checksum_name="${artifact_name}.sha256"

mkdir -p "$release_dir"
rm -f "$zip_path" "${release_dir}/${checksum_name}"

ditto -c -k --norsrc --noextattr --keepParent "$app_path" "$zip_path"

(
  cd "$release_dir"
  shasum -a 256 "$artifact_name" > "$checksum_name"
)

printf '%s\n' "$zip_path"
printf '%s\n' "${release_dir}/${checksum_name}"
