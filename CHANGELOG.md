# Changelog

All notable changes to Moonlight Companion are tracked here and mirrored to GitHub Releases.

## Unreleased

### Changed

- The Moonlight file drop overlay now briefly latches ray-hits on the stream window and stays magnetically captured for the active file drag, reducing missed drops and flicker while dragging across or just past Moonlight.
- Moonlight window, strip, Companion drops, and the macOS clipboard helper now accept broader file URL pasteboard variants such as `public.url`, making file drags and file clipboards from more macOS sources arrive as transfers.
- File URL pasteboard strings can now contain multiple newline-separated file URLs or paths, so multi-file drags and file clipboards from more macOS apps are preserved as multi-item transfers.
- The GUI now offers a Cancel action for in-progress file sends, transfer tests, and Windows receive-folder reveal requests.
- Transfer cancellation now terminates the whole cancellable script job so stuck SSH/SCP child commands stop with the GUI action instead of lingering behind the cancelled request.
- Existing user settings now keep the Companion control window hidden on launch unless `MOONLIGHT_COMPANION_SHOW_WINDOW_ON_LAUNCH` is enabled, and background failures no longer raise modal alerts over the current workspace.
- Automatic Moonlight drop overlays now avoid forced frontmost ordering, while manually shown overlays can still be brought above the stream when requested.
- Automatic paste after Moonlight window or strip drops no longer brings Moonlight forward by default; `MOONLIGHT_TRANSFER_ACTIVATE_MOONLIGHT_FOR_PASTE` can opt back into the old focus-changing paste behavior.
- The GUI now revalidates the latest Windows-to-Mac received file paths while it is open, disabling reveal/copy actions when those files have been moved or deleted.
- Oversized Mac-to-Windows drops can now bypass the clipboard and copy directly into the Windows receive folder over SSH, with GUI state marking that auto-paste is unavailable for that direct path.
- Oversized Windows-to-Mac file clipboards now prepare an SSH fallback ZIP instead of being silently skipped, so the Mac sync agent can still pull large received files into the Mac receive folder.
- macOS fallback polling now removes hash-verified consumed or stale Windows-to-Mac fallback ZIPs from the Windows sync folder, preventing duplicate receives after the Mac sync service restarts.
- The file transfer self-test now uploads a Windows-to-Mac fallback ZIP to the remote sync folder and verifies that the Mac sync loop pulls, imports, records, and cleans up that SSH fallback path.
- When direct oversized transfer is disabled, oversized Mac-to-Windows file drops are rejected before temporary payload export, avoiding unnecessary copy and hash work for files over the configured clipboard limit.
- When direct oversized transfer is disabled, oversized Mac-to-Windows file drops report human-readable sizes and suggest splitting the transfer or using a file sync tool.
- Mac-to-Windows GUI sends now show live transfer phases such as metadata collection, packaging, TCP/SSH send, and Windows receive confirmation.
- Moonlight window and strip drops now send automatic `Ctrl+V` only after Windows import confirmation, avoiding stale pastes when a fallback transfer is still pending.
- Windows-to-Mac receives now record the latest imported Mac file paths, and the GUI can reveal the last received Mac files directly in Finder.
- The GUI can now ask Windows to reveal the latest received Windows item on demand, mirroring the Mac-side latest receive reveal action.
- Latest Windows receive state now keeps a short received-name summary so later reveal actions show what will be selected.
- `Reveal Last Windows Receive` now keeps that received-name summary visible after the reveal/open action completes.
- Automatic Windows receive-result reveal now waits for Windows import confirmation instead of opening Explorer while a fallback transfer is still pending.
- GUI sends that need automatic paste or reveal now wait longer for fallback Windows import confirmation before declaring the result pending.
- The GUI now watches the latest Windows-to-Mac receive state and updates its status line when new Mac files arrive while Companion is open.
- The GUI file transfer test now streams its current step into the status line, so long end-to-end checks no longer look idle.
- File drops made while a transfer, reveal, or transfer test is already running are now queued and sent after the current operation instead of starting overlapping transfer scripts.
- Cancelling or failing a busy transfer operation now clears pending queued drops instead of starting them after the cancelled or failed operation exits.
- Windows-to-Mac receives that arrive while the GUI is busy are now remembered and shown after the current operation finishes instead of being lost from the status line.
- Pending Windows-to-Mac receive notices are now shown after cancelled or failed operations too, while queued Mac-to-Windows drops still stay cleared.
- The GUI now disables `Reveal Last Mac Receive` until a latest Windows-to-Mac receive state is available, so stale empty actions are less tempting.
- The GUI now records the last confirmed Mac-to-Windows receive id locally and disables `Reveal Last Windows Receive` until that confirmed Windows receive can be targeted.
- The Companion window no longer force-activates itself on launch by default; `MOONLIGHT_COMPANION_ACTIVATE_ON_LAUNCH` can opt back into the old foreground behavior.
- The default Windows-to-Mac receive behavior no longer opens Finder automatically; received files stay in the receive folder, on the Mac clipboard, and available through `Reveal Last Mac Receive`.
- Existing user settings from before the quiet defaults are migrated so the old Finder reveal default does not keep stealing focus after upgrade.
- The GUI can now copy the latest Windows-to-Mac received files back onto the Mac clipboard without opening Finder, making missed or overwritten receive clipboards recoverable without echoing the restore back to Windows.
- The macOS clipboard helper now has a reusable `set-files` command, and the file transfer self-test verifies that restoring the latest Mac receive to the clipboard does not send it back to Windows.
- Latest Mac receive clipboard restores now use that single helper operation to set the file clipboard and return the restored payload id, avoiding an extra large-file export pass in the GUI path.
- `set-files` now uses metadata-only payload id calculation for already Windows-safe file trees, avoiding temporary file copies when restoring received files to the Mac clipboard.
- Folder payload hashing now resolves source-relative paths, so `/var` and `/private/var` aliases do not leak into payload ids or make metadata-only restores diverge from normal exports.
- The file transfer self-test now compares metadata-only `set-files` payload ids against normal `export-paths` ids for duplicate file names and folders, keeping the fast path byte-compatible with existing sends.
- The file transfer self-test now snapshots supported Mac clipboard contents before it runs, pauses background Mac-to-Windows clipboard polling while the test is active, and restores the original clipboard during cleanup without resending that restore to Windows.
- Clipboard snapshots used by the file transfer self-test now avoid copying Windows-safe file clipboards into temporary payload directories, making tests lighter when the current Mac clipboard already contains large files.
- Empty Mac clipboards are now snapshotted and restored as empty during file transfer self-tests instead of leaving a test file clipboard behind.
- GUI `Copy Last Mac Receive` restores now also write a one-shot Mac clipboard ignore marker, matching the self-test restore path and further reducing accidental resend windows.
- Moonlight launch and display placement no longer force Moonlight to the foreground by default; `MOONLIGHT_ACTIVATE_ON_LAUNCH` can opt back into the old behavior.
- The file transfer self-test now writes a temporary quiet-state marker so Windows-to-Mac receive notifications and Finder reveal actions do not interrupt the current Mac workspace while tests run.
- The Mac clipboard sync loop now rechecks for in-flight TCP receives after exporting the local clipboard, closing a race that could echo a just-received Windows file back to Windows.
- Windows-to-Mac TCP receives now keep their receive lock alive through reading, expanding, importing, normalizing, and notification phases, preventing slow receives from being mistaken for stale work and echoed back.
- Windows-to-Mac receive loop prevention now also compares the normalized Mac clipboard id after refreshing TCP receive state, avoiding Unicode-sensitive file echo-backs.
- Moonlight window, strip, and Companion file drops now read both modern file URL drag items and legacy Finder filename pasteboard entries, making drag detection more tolerant across macOS sources.
- Moonlight window, strip, and Companion file drops now show active drag feedback with the item count and dropped file names before release.
- Active file-drop feedback now shortens long file names and keeps drop labels to one line so compact drop targets stay stable.
- The GUI now has an `Open Windows Folder` action that asks the logged-in Windows session to open the configured receive folder in Explorer.
- Added `MOONLIGHT_TRANSFER_REVEAL_WINDOWS_DIR` for optionally opening the Windows receive result after successful Mac-to-Windows sends, selecting the single received item when possible.
- Windows receive-result reveal now verifies the just-sent transfer id before selecting a single received item, avoiding stale receive-state selections.
- Mac-to-Windows send results now show the actual Windows receive-folder file names, including names sanitized for Windows.
- Mac-to-Windows TCP file drops now receive the Windows import acknowledgement on the same TCP connection, avoiding the extra SSH confirmation round trip when both sides are current.
- Windows-to-Mac TCP file transfers now require a Mac import acknowledgement before the Windows agent considers TCP delivery complete; otherwise the existing SSH fallback ZIP stays available.
- The file transfer self-test now requires the same-connection TCP acknowledgement when TCP clipboard transfer is enabled, while normal sends still keep the SSH state fallback.
- Windows-to-Mac file arrival notifications and TCP logs now include received file names and total size.
- The file transfer self-test now refreshes the Mac TCP receiver when its helper was rebuilt, so tests exercise the current receiver binary instead of an already-running older one.
- The file transfer self-test now verifies that repeated same-name transfers create collision-safe `-2` files on both Mac and Windows instead of overwriting existing receive-folder files.
- The file transfer self-test now verifies nested folder transfers in both directions.
- Windows-to-Mac TCP receives now write the final normalized clipboard state before notifications, preventing received files from being echoed back to Windows as new Mac-to-Windows sends.
- The file transfer self-test now waits for Windows-to-Mac file and folder receives long enough to catch accidental echo-back uploads.
- Windows-to-Mac fallback polling notifications and logs now use the same received file name and total size summary as the TCP receiver.
- The file transfer self-test now verifies that empty nested folders survive Mac-to-Windows and Windows-to-Mac folder transfers.
- The file transfer self-test now verifies that file names with spaces and parentheses survive in both directions.
- The file transfer self-test now escapes PowerShell string literals and verifies apostrophe file names in both directions.
- The file transfer self-test now verifies Korean file names in both directions.
- The file transfer self-test now verifies PNG image files in both directions with SHA-256 byte checks.
- Mac-origin file and folder names that contain Windows-invalid characters are now converted to safe receive-folder names without changing file bytes.
- The file transfer self-test now verifies empty files plus nested Windows-reserved and trailing-dot Mac names.
- Windows-to-Mac TCP receive details now show zero-byte files as `0 bytes` instead of a rounded file-size label.
- The file transfer self-test now verifies multi-item file-plus-folder selections in both directions.
- Windows receive-folder imports now normalize incoming Mac file and folder names to composed Unicode so Korean names arrive naturally.
- macOS receive notifications and logs now use composed display names from the import helper for Korean file names.
- Windows file-drop export now skips stale or partially missing clipboard file lists instead of producing broken or partial transfer payloads.
- macOS fallback polling now tracks remote ZIP hashes separately from TCP receive state to avoid retrying stale fallback payloads after TCP transfers.

## v0.3.0 - 2026-06-24

### Added

- Added a GUI file drop target for sending Mac files and folders to Windows over the existing clipboard TCP channel.
- Added a temporary full-window Moonlight drop overlay that appears during Finder file drags near Moonlight.
- Added a floating Moonlight drop strip for Mac-to-Windows file drops without aiming at the main Companion window.
- Added a GUI file transfer test that validates and cleans up Mac-to-Windows and Windows-to-Mac test files.
- Added separate post-drop `Ctrl+V` controls so Moonlight window/strip drops can paste by default while the Companion fallback drop target stays opt-in.
- Added Mac notifications for Moonlight screen-drop send results and Windows-to-Mac file arrivals, plus an optional Finder reveal action for received files.
- Added durable Mac and Windows receive folders for imported file payloads.
- Added `MOONLIGHT_TRANSFER_MAC_DIR`, `MOONLIGHT_TRANSFER_WINDOWS_DIR`, `MOONLIGHT_TRANSFER_DROP_OVERLAY`, `MOONLIGHT_TRANSFER_SCREEN_DROP_AUTO_PASTE`, `MOONLIGHT_TRANSFER_AUTO_PASTE`, `MOONLIGHT_TRANSFER_NOTIFY`, `MOONLIGHT_TRANSFER_REVEAL_MAC_DIR`, and `MOONLIGHT_TRANSFER_REVEAL_WINDOWS_DIR` settings.
- Added Moonlight-focused Command-to-Control shortcut remapping for Mac-style shortcuts.
- Added `MOONLIGHT_SHORTCUT_REMAP` to enable or disable local shortcut remapping.
- Added a settings GUI for editing launch, keyboard, and clipboard options before starting Moonlight.
- Added GUI controls to stop Moonlight without stopping sidecar services.
- Added `MOONLIGHT_DISPLAY_INDEX` and a GUI launch-display picker for best-effort Moonlight window placement.

### Changed

- The Caps Lock keyboard helper is now signed with a stable ad-hoc requirement so macOS Accessibility permission survives helper rebuilds more reliably.
- The GUI `Permissions` button now starts the keyboard helper permission request before opening macOS Accessibility settings.
- The macOS Caps Lock helper now also acts as the Moonlight keyboard helper.
- The Moonlight file drop overlay now samples drag movement faster and uses pointer-path hit testing so fast drags across the stream window are caught more reliably.
- Windows-to-Mac file arrivals now reveal the newly received files in Finder when receive-folder reveal is enabled, instead of only opening the folder.
- Finder reveal is now enabled by default for newly received Windows files, and file-arrival notifications say whether Finder will reveal the files or leave them ready to paste.
- Mac-to-Windows file drop status and notifications now include the dropped item names and total source size.
- Mac-to-Windows sends now look for a Windows-side import confirmation from the agent so the GUI can distinguish confirmed receive-folder imports from pending confirmation.
- The GUI file transfer test now refreshes the Windows agent, starts the Mac transfer services, and fails if Mac-to-Windows import confirmation is missing.
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
