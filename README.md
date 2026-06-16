# Moonlight Companion

Moonlight Companion is a wrapper around Moonlight for Mac clients connecting to Windows Sunshine hosts. It launches Moonlight and runs a sidecar clipboard bridge over SSH/Tailscale.

The bridge is designed for remote GUI work where Moonlight provides excellent video latency but does not behave like a full remote desktop clipboard.

## Version

Current MVP version: `v0.1.0`

## Features

- Launches Moonlight with a configurable profile.
- Builds a native macOS wrapper app bundle.
- Starts a macOS `launchd` clipboard sync agent.
- Deploys a Windows clipboard agent over SSH.
- Syncs clipboard payloads as shared ZIP payloads.
- Supports text, images, and file/folder clipboard payloads.
- Uses SSH over Tailscale; no public port forwarding is required.

## Current Assumptions

- Mac client, Windows Sunshine host.
- Passwordless SSH from Mac to Windows is already configured.
- Moonlight is installed at `/Applications/Moonlight.app`.
- The Windows agent runs inside the logged-in Windows GUI session. It is installed into the user's Startup folder.

## Daily Use

Build the wrapper app:

```bash
scripts/build-mac-app.sh
```

Run it from the build output:

```bash
open "dist/Moonlight Companion.app"
```

Or install it into `/Applications`:

```bash
rm -rf "/Applications/Moonlight Companion.app"
ditto "dist/Moonlight Companion.app" "/Applications/Moonlight Companion.app"
open "/Applications/Moonlight Companion.app"
```

When the app opens, it:

1. Verifies SSH access to the Windows host.
2. Deploys or updates the Windows clipboard agent.
3. Starts the macOS clipboard sync agent.
4. Launches Moonlight with the configured stream settings.

Inside the Moonlight session, use Windows shortcuts:

- Mac side copy: `Cmd+C`
- Paste into Windows/Moonlight: `Ctrl+V`
- Copy inside Windows/Moonlight: `Ctrl+C`
- Paste back on Mac: `Cmd+V`

## Zero-Base Setup

These steps assume a fresh Mac client and a fresh Windows Sunshine host.

### 1. Prepare The Windows Host

Install and configure:

- Tailscale, logged into the same tailnet as the Mac.
- Sunshine, configured to stream the Windows desktop.
- OpenSSH Server for Windows.

Enable SSH from an elevated PowerShell window:

```powershell
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
Set-Service sshd -StartupType Automatic
Start-Service sshd
```

Get the Windows Tailscale IP:

```powershell
tailscale ip -4
```

Keep the Windows user logged into the GUI desktop. The clipboard agent must run in the interactive desktop session, not only in a service session.

### 2. Prepare The Mac Client

Install and configure:

- Tailscale, logged into the same tailnet as the Windows host.
- Moonlight at `/Applications/Moonlight.app`.
- Xcode Command Line Tools for `swiftc`.

Install Xcode Command Line Tools if needed:

```bash
xcode-select --install
```

Generate a dedicated SSH key:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_moonlight_windows -C "moonlight-companion"
```

Add the public key to the Windows user's SSH authorized keys:

```bash
pbcopy < ~/.ssh/id_ed25519_moonlight_windows.pub
```

On Windows, paste that public key into:

```text
%USERPROFILE%\.ssh\authorized_keys
```

Create or update the Mac SSH config:

```sshconfig
Host moonlight-windows
  HostName 100.x.y.z
  User windows-user
  IdentityFile ~/.ssh/id_ed25519_moonlight_windows
  IdentitiesOnly yes
  StrictHostKeyChecking accept-new
```

Test passwordless SSH:

```bash
ssh moonlight-windows "cmd.exe /c echo ssh-ok"
```

### 3. Configure Moonlight Companion

1. Copy `config/moonlight-companion.conf.example` to `config/moonlight-companion.conf`.
2. Edit `MOONLIGHT_HOST`, `WINDOWS_SSH`, resolution, bitrate, and display mode.

Example:

```bash
cp config/moonlight-companion.conf.example config/moonlight-companion.conf
```

```bash
WINDOWS_SSH="moonlight-windows"
MOONLIGHT_HOST="100.x.y.z"
MOONLIGHT_STREAM_APP="Desktop"
MOONLIGHT_RESOLUTION="3456x2234"
MOONLIGHT_FPS="60"
MOONLIGHT_BITRATE="60000"
MOONLIGHT_DISPLAY_MODE="windowed"
MOONLIGHT_VIDEO_CODEC="HEVC"
```

Build the wrapper app:

```bash
scripts/build-mac-app.sh
```

Open it:

```bash
open "dist/Moonlight Companion.app"
```

The app bundle includes the Mac scripts, Windows agent scripts, and config files needed by the launcher. If `config/moonlight-companion.conf` exists when the app is built, it is copied into the local `dist/` app bundle.

### Optional: Force Moonlight To Start On A Target Display

If Moonlight keeps opening fullscreen on an external monitor instead of the MacBook Retina display, Moonlight Companion can temporarily make the target display the macOS main display before launch and then restore the original layout.

Install `displayplacer`:

```bash
brew install displayplacer
```

Print the current layout:

```bash
displayplacer list
```

Copy the final `displayplacer ...` command as your restore reference, then create a launch layout where the target display has `origin:(0,0)` and the other displays keep the same relative positions around it.

Enable it in `config/moonlight-companion.conf`:

```bash
MOONLIGHT_TEMP_MAIN_DISPLAY="yes"
MOONLIGHT_DISPLAYPLACER_LAUNCH_COMMAND='displayplacer "id:TARGET_DISPLAY_ID res:1728x1117 hz:120 color_depth:8 enabled:true scaling:on origin:(0,0) degree:0" "id:OTHER_DISPLAY_ID res:2560x1440 hz:60 color_depth:8 enabled:true scaling:off origin:(-2560,-323) degree:0"'
MOONLIGHT_DISPLAY_RESTORE_AFTER_LAUNCH="yes"
MOONLIGHT_DISPLAY_RESTORE_DELAY_SECONDS="7"
```

The launcher captures the real current layout at runtime, applies the launch layout, starts Moonlight, waits for `MOONLIGHT_DISPLAY_RESTORE_DELAY_SECONDS`, and restores the captured layout. Keep this setting in local config only because display IDs and coordinates are machine-specific.

## Architecture

See [docs/architecture.md](docs/architecture.md) for runtime and clipboard sync diagrams.

## Notes

The clipboard bridge stores transient payloads under:

- macOS: `~/Library/Application Support/MoonlightClipboardSync`
- Windows: `%USERPROFILE%\.moonlight-clipboard-sync`

The default payload limit is 50 MiB. This is intentional; very large file clipboard payloads are better moved with a file sync tool.
