# Changelog

All notable changes to Moonlight Companion are tracked here and mirrored to GitHub Releases.

## Unreleased

### Changed

- The Moonlight file drop overlay now briefly latches ray-hits on the stream window and stays magnetically captured for the active file drag, reducing missed drops and flicker while dragging across or just past Moonlight.
- Moonlight window, strip, Companion drops, and the macOS clipboard helper now accept broader file URL pasteboard variants such as `public.url`, making file drags and file clipboards from more macOS sources arrive as transfers.
- Moonlight window, strip, and Companion drops now accept plain-text file URL or absolute-path lists when every non-comment line is a file reference, making file drags from more Mac apps behave like ordinary file drops without changing text clipboard sync.
- Plain-text file-reference drops now require every referenced local path to exist before the GUI accepts the drag, avoiding misleading file transfer attempts from stale path text.
- Plain-text file-reference drops now require referenced local items to be readable, and folders to be openable, before the GUI accepts the drag.
- File URL pasteboard strings can now contain multiple newline-separated file URLs or paths, so multi-file drags and file clipboards from more macOS apps are preserved as multi-item transfers.
- Moonlight window, strip, and Companion drop targets now accept macOS file promises, materializing promised files into a temporary staging folder before sending them through the normal Mac-to-Windows transfer pipeline.
- Promised file drops can now be cancelled while the source app is still materializing files, and their temporary staging folders are cleaned up with other queued transfer work.
- Promised file drops now fail as a whole if the source app cannot provide every promised item, avoiding surprising partial Mac-to-Windows transfers.
- Companion now removes stale promised-file drop staging folders on launch, cleaning up leftovers from interrupted drags or app exits.
- Queued file drops now preserve the current operation status while adding a queue note to the detail text, so active sends, reveals, and tests stay understandable.
- Queued promised-file drop failures no longer overwrite the status of the transfer, reveal, or test that is already running.
- Mac clipboard helper import/export calls now have a bounded timeout in both the polling sync loop and TCP receiver, so a stuck clipboard or file operation cannot wedge later transfers.
- Windows clipboard TCP receive sockets now use bounded read/write timeouts, preventing half-open Mac-to-Windows TCP sends from blocking later transfers.
- Latest receive path state now includes base64 path fields on both Mac and Windows, making reveal/copy actions more resilient while staying compatible with older plain-path state files.
- Mac receive state readers now prefer base64 file path/name fields and keep plain state lines single-line, preserving exact paths for unusual macOS file names without corrupting later reveal/copy actions.
- Mac-to-Windows TCP acknowledgements now carry base64 Windows receive-folder paths, so latest-receive reveal state remains available even if the follow-up SSH state read is slow.
- Windows-to-Mac TCP acknowledgement reads now allow longer response lines while keeping incoming TCP headers tightly bounded, avoiding unnecessary SSH fallback retention for long received file names.
- Mac-to-Windows file clipboard exports now validate every source path before packaging and clean partial payloads after copy failures, avoiding broken or partial sends from stale Mac file clipboards.
- Background Mac-to-Windows clipboard sync now logs stale Mac file clipboard source failures once per distinct failure, making missing or unreadable Finder clipboard paths easier to diagnose without flooding the log.
- The Companion GUI now watches stale Mac file clipboard export state and surfaces missing or unreadable Mac clipboard file paths in the status line while it is open.
- Stale Mac file clipboard export failures now also use the existing transfer notification setting, so missing or unreadable copied files are visible even when the Companion window is closed.
- Stale Windows-to-Mac file clipboard export failures are now mirrored back to macOS notifications and the Companion status line, making missing or unreadable Windows copied files visible from the Mac side.
- The Companion status line now clears stale Mac and Windows file clipboard failure notices after the underlying clipboard issue is resolved, avoiding lingering false failure states.
- Background Mac-to-Windows file clipboard sync now records confirmed TCP receive paths for the GUI's latest Windows receive action, and the open GUI watches that state so files copied from Finder are easier to reveal later.
- The GUI status line now reports background Mac-to-Windows file clipboard receives while Companion is open, including receives that finish while another GUI operation is busy.
- Oversized background Mac-to-Windows file clipboards now use the same direct Windows receive-folder transfer as oversized GUI drops instead of being silently skipped at the clipboard payload limit.
- Oversized direct Mac-to-Windows transfers now ask the Windows GUI agent to put the received file paths onto the Windows clipboard after the receive-folder copy, so large drops can still be pasted when clipboard handoff succeeds.
- Oversized direct Mac-to-Windows clipboard handoff now updates the Windows agent's echo-prevention state, so received large files are not immediately exported back to Mac as a new Windows-to-Mac copy.
- Oversized background direct Mac-to-Windows file clipboard sends now leave the clipboard item retryable after a transient direct-transfer failure, so a temporary SSH/SCP hiccup does not require copying the file again.
- The file transfer self-test now verifies the background Mac-to-Windows file clipboard path, including the Windows receive-folder copy and latest Windows receive state written from the TCP acknowledgement.
- The file transfer self-test now verifies oversized direct Mac-to-Windows multi-item drops, including folder contents, empty nested folders, GUI receive state, and reveal behavior.
- The file transfer self-test now verifies that multi-item Windows receive clipboard restore puts all latest Mac-to-Windows received paths back onto the Windows clipboard.
- The file transfer self-test now verifies Windows-to-Mac SSH fallback multi-item pulls, including folder contents, empty nested folders, latest receive state, and loop-prevention.
- The file transfer self-test now verifies stale Windows file clipboard failure state, including base64 state fields, duplicate suppression, and clearing after a valid file export.
- Oversized direct Mac-to-Windows sends now clean stale direct-transfer artifacts before upload and after upload/setup failures, making immediate retry safer after an interrupted SSH/SCP step.
- The file transfer self-test now verifies that multi-item Windows-to-Mac receives can be restored to the Mac clipboard without copying received files into temporary payloads or echoing them back to Windows.
- Windows-to-Mac file clipboard exports now fail as a whole when any source path is missing or unreadable, instead of falling through to another clipboard format or leaving partial payload files behind.
- Windows-to-Mac Mac receive-folder imports now stage received files before moving them into place, so a broken payload cannot leave only some files in the receive folder.
- Windows-to-Mac Mac receive-folder imports now remove stale hidden staging folders left by interrupted older receives when the next Mac receive-folder import begins.
- Mac-to-Windows Windows receive-folder imports now stage received files before moving them into place, preventing broken payloads from leaving partial files on Windows.
- Windows receive-folder imports now remove stale hidden staging folders left by interrupted older transfers when the Windows agent starts or the next receive-folder import begins.
- Oversized Mac-to-Windows direct receive-folder transfers now stage payloads in a hidden Windows folder before moving them into place, so large direct copies do not expose partial results.
- Failed oversized Mac-to-Windows direct transfers now clean up their temporary Windows payload directory and direct ZIP files.
- Oversized Mac-to-Windows direct transfers now remove their temporary Windows helper script after success or failure.
- Mac-to-Windows SSH fallback uploads now clear stale temporary ZIPs before retrying and after failed upload/move steps.
- Windows now removes hash-verified consumed Mac-to-Windows fallback ZIPs after import, preventing duplicate receives after the Windows agent restarts.
- Windows now removes repeatedly failing stale Mac-to-Windows fallback ZIPs instead of retrying a broken archive forever.
- Windows treats a reappeared Mac-to-Windows fallback ZIP as fresh work after the previous archive has been consumed or cleaned up, even when the archive hash is unchanged.
- Windows-to-Mac fallback ZIP compression now removes stale or failed temporary ZIPs without deleting the last complete fallback ZIP.
- The automatic Moonlight screen drop overlay now detects file-promise drags too, so source apps that create files on drop can still use the whole stream window as the drop target.
- Mac-to-Windows sends now reject missing or unreadable dropped items before packaging or opening network transfer paths, with clearer permission guidance in the GUI output.
- The GUI no longer recursively measures dropped folders on the main thread before sending; folder sizes are measured by the background transfer path so large folder drops stay responsive.
- The GUI now offers a Cancel action for in-progress file sends, transfer tests, and Windows receive-folder reveal requests.
- Transfer cancellation now terminates the whole cancellable script job so stuck SSH/SCP child commands stop with the GUI action instead of lingering behind the cancelled request.
- Existing user settings now keep the Companion control window hidden on launch unless `MOONLIGHT_COMPANION_SHOW_WINDOW_ON_LAUNCH` is enabled, and background failures no longer raise modal alerts over the current workspace.
- The GUI now has a `Status` action that runs the bundled service status check and shows clipboard sync, TCP tunnel, Caps Lock helper, and recent log output without opening Terminal.
- Launching the wrapper with `--background`, `--quiet-launch`, or `--no-window` now suppresses the Companion control window even when saved settings would normally show it.
- Added `scripts/open-mac-app-background.sh` so rebuild workflows can start Companion quietly and skip macOS reopen events when the app is already running.
- Automatic Moonlight drop overlays now avoid forced frontmost ordering, while manually shown overlays can still be brought above the stream when requested.
- Automatic paste after Moonlight window or strip drops no longer brings Moonlight forward by default; `MOONLIGHT_TRANSFER_ACTIVATE_MOONLIGHT_FOR_PASTE` can opt back into the old focus-changing paste behavior.
- The GUI now revalidates the latest Windows-to-Mac received file paths while it is open, disabling reveal/copy actions when those files have been moved or deleted.
- `Reveal Last Mac Receive` and `Copy Last Mac Receive` now report when only some remembered received items are still available, while keeping the remaining usable items revealable or copyable.
- `Copy Last Mac Receive` now uses item-count-aware ready-to-paste status text, so single and multi-item restores read naturally.
- Oversized Mac-to-Windows drops can now bypass the ZIP clipboard payload limit and copy directly into the Windows receive folder over SSH, with GUI state reporting whether the Windows agent put the received paths back onto the Windows clipboard.
- Oversized Windows-to-Mac file clipboards now prepare an SSH fallback ZIP instead of being silently skipped, so the Mac sync agent can still pull large received files into the Mac receive folder.
- Windows-to-Mac SSH fallback imports now retry transient ZIP/import failures and remove repeatedly failing stale fallback ZIPs instead of letting them stop or wedge the Mac sync loop.
- macOS fallback polling now removes hash-verified consumed or stale Windows-to-Mac fallback ZIPs from the Windows sync folder, preventing duplicate receives after the Mac sync service restarts.
- The file transfer self-test now uploads a Windows-to-Mac fallback ZIP to the remote sync folder and verifies that the Mac sync loop pulls, imports, records, and cleans up that SSH fallback path.
- When direct oversized transfer is disabled, oversized Mac-to-Windows file drops are rejected before temporary payload export, avoiding unnecessary copy and hash work for files over the configured clipboard limit.
- When direct oversized transfer is disabled, oversized Mac-to-Windows file drops report human-readable sizes and suggest splitting the transfer or using a file sync tool.
- Mac-to-Windows GUI sends now show live transfer phases such as metadata collection, packaging, TCP/SSH send, and Windows receive confirmation.
- Moonlight window and strip drops now send automatic `Ctrl+V` only after Windows import confirmation, avoiding stale pastes when a fallback transfer is still pending.
- Windows-to-Mac receives now record the latest imported Mac file paths, and the GUI can reveal the last received Mac files directly in Finder.
- The GUI can now ask Windows to reveal the latest received Windows item on demand, mirroring the Mac-side latest receive reveal action.
- Latest Windows receive state now keeps a short received-name summary so later reveal actions show what will be selected.
- Latest Windows receive state now keeps the confirmed Windows receive paths too, so later reveal actions can select the exact received item without depending on the current remote import state.
- `Reveal Last Windows Receive` now keeps that received-name summary visible after the reveal/open action completes.
- `Reveal Last Windows Receive` now opens the common containing folder for multi-item Windows receives when exact single-item selection is not available.
- `Reveal Last Windows Receive` now clearly reports when the remembered Windows item is no longer available and clears the stale reveal state instead of presenting it as a normal folder open.
- The GUI can now copy the latest Mac-to-Windows received files back onto the Windows clipboard, making overwritten or missed Windows file clipboards recoverable without resending the files.
- `Copy Last Windows Receive` now restores the remaining available paths to the Windows clipboard when only some remembered receive items are missing, and reports the partial availability instead of failing the whole action.
- After a partial `Copy Last Windows Receive`, the GUI now trims the remembered latest Windows receive state to the remaining available paths so follow-up copy/reveal actions stop retrying missing items.
- Windows receive-folder reveal now clears stale remote opener scripts from interrupted previous reveal attempts.
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
- The Mac clipboard sync service now removes stale local `moonlight-clipboard-sync.*` work folders on startup, cleaning up leftovers from interrupted sync runs.
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
