# Changelog

All notable changes to Moonlight Companion are tracked here and mirrored to GitHub Releases.

## Unreleased

### Added

- Added a GUI file drop target for sending Mac files and folders to Windows over the existing clipboard TCP channel.
- Added a floating Moonlight drop strip for Mac-to-Windows file drops without aiming at the main Companion window.
- Added an optional post-drop `Ctrl+V` action for pasting transferred files into the focused Windows app inside Moonlight.
- Added durable Mac and Windows receive folders for imported file payloads.
- Added `MOONLIGHT_TRANSFER_MAC_DIR`, `MOONLIGHT_TRANSFER_WINDOWS_DIR`, and `MOONLIGHT_TRANSFER_AUTO_PASTE` settings.
- Added Moonlight-focused Command-to-Control shortcut remapping for Mac-style shortcuts.
- Added `MOONLIGHT_SHORTCUT_REMAP` to enable or disable local shortcut remapping.
- Added a settings GUI for editing launch, keyboard, and clipboard options before starting Moonlight.
- Added GUI controls to stop Moonlight without stopping sidecar services.
- Added `MOONLIGHT_DISPLAY_INDEX` and a GUI launch-display picker for best-effort Moonlight window placement.

### Changed

- The Caps Lock keyboard helper is now signed with a stable ad-hoc requirement so macOS Accessibility permission survives helper rebuilds more reliably.
- The GUI `Permissions` button now starts the keyboard helper permission request before opening macOS Accessibility settings.
- The macOS Caps Lock helper now also acts as the Moonlight keyboard helper.
- Moonlight-focused `Command` shortcuts for letters, numbers, punctuation, tab, and delete are remapped to their Windows `Control` equivalents.
- Moonlight Companion now stays open as a control panel instead of immediately launching and quitting.
- Moonlight launch now waits longer for the stream window, logs display placement diagnostics, and attempts to place the window on the selected Mac display after startup.

## v0.2.0 - 2026-06-17

### Added

- Added persistent clipboard TCP channels over SSH forwarding:
  - Mac to Windows payload push on loopback port `47331`.
  - Windows to Mac payload push on loopback port `47332`.
- Added the `mooncliptcp` macOS helper for framed clipboard ZIP payload transfer.
- Added launchd services for the clipboard TCP receiver and SSH clipboard tunnel.
- Added config options for enabling clipboard TCP and overriding local/remote clipboard TCP ports.
- Added release history documentation and an architecture diagram to the README.

### Changed

- Clipboard sync now prefers TCP push delivery and falls back to the previous ZIP/SCP polling path when TCP is unavailable.
- Windows clipboard polling work stays on the existing interval while the TCP listener checks more frequently for lower inbound latency.
- Status and stop scripts now include the clipboard TCP receiver and tunnel services.
- Release packaging now produces `Moonlight-Companion-v0.2.0.zip`.

### Verified

- `./scripts/check.sh`
- `git diff --check`
- `scripts/build-mac-app.sh`
- Runtime launch with all clipboard/Caps Lock launchd services running.
- Mac to Windows clipboard transfer via TCP.
- Windows to Mac clipboard transfer via TCP reverse tunnel.

## v0.1.0 - 2026-06-16

### Added

- Initial Moonlight Companion wrapper app.
- macOS and Windows clipboard sync for text, image, and file/folder payloads.
- SSH/Tailscale-based deployment and fallback payload transport.
- Caps Lock to Windows Korean IME Han/Eng toggle support.
- Release packaging with local config excluded from public artifacts.
