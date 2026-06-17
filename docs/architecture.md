# Architecture

Moonlight Companion does not modify Moonlight or Sunshine. It runs beside them.

## Runtime Architecture

```mermaid
flowchart LR
  subgraph Mac["Mac client"]
    Wrapper["Moonlight Companion.app"]
    Config["Config file"]
    Moonlight["Moonlight.app"]
    Launchd["macOS launchd sync agent"]
    ClipTcp["macOS clipboard TCP receiver"]
    CapsAgent["macOS Caps Lock agent"]
    Helper["moonclipctl Swift helper"]
    MacClipboard["macOS clipboard"]
  end

  subgraph Network["Tailscale private network"]
    SSH["SSH/SCP"]
    ClipTunnel["SSH clipboard TCP tunnel"]
    CapsTunnel["SSH Caps Lock TCP tunnel"]
    Stream["Moonlight video/input stream"]
  end

  subgraph Windows["Windows Sunshine host"]
    Sunshine["Sunshine"]
    PayloadDir["%USERPROFILE%/.moonlight-clipboard-sync"]
    WinAgent["Windows GUI clipboard agent"]
    WinClipboard["Windows clipboard"]
    Startup["User Startup folder"]
  end

  Wrapper --> Config
  Wrapper -->|"deploy agent files"| SSH
  Wrapper -->|"start/restart"| Launchd
  Wrapper -->|"launch stream"| Moonlight
  Moonlight <-->|"stream"| Stream
  Stream <-->|"Sunshine protocol"| Sunshine

  Launchd <-->|"export/import"| Helper
  Helper <-->|"read/write"| MacClipboard
  Launchd -->|"Mac -> Windows ZIP frame"| ClipTunnel
  ClipTcp -->|"import Windows -> Mac ZIP frame"| Helper
  ClipTunnel <-->|"loopback TCP"| WinAgent
  Launchd <-->|"fallback ZIP payloads"| SSH
  SSH <-->|"copy payload archives"| PayloadDir
  CapsAgent -->|"Caps Lock toggle request"| CapsTunnel
  CapsTunnel -->|"loopback TCP"| WinAgent

  WinAgent <-->|"watch/import/export"| PayloadDir
  WinAgent -->|"toggle Korean IME mode"| WinAgent
  WinAgent <-->|"read/write"| WinClipboard
  Wrapper -->|"install Startup entry"| Startup
  Startup -->|"starts in GUI session"| WinAgent
```

## Launch Sequence

```mermaid
sequenceDiagram
  participant User
  participant Wrapper as Moonlight Companion.app
  participant SSH as SSH over Tailscale
  participant WinHost as Windows host
  participant Launchd as macOS launchd agent
  participant Moonlight as Moonlight.app
  participant Sunshine

  User->>Wrapper: Open app
  Wrapper->>SSH: Verify passwordless SSH
  Wrapper->>WinHost: Deploy clipboard agent files
  Wrapper->>WinHost: Install Startup entry for GUI session
  Wrapper->>Launchd: Start clipboard sync and Caps Lock agents
  Wrapper->>Moonlight: Launch configured stream
  Moonlight->>Sunshine: Connect over Tailscale
  Wrapper-->>User: Close when ready
```

## Clipboard Sync Flow

```mermaid
sequenceDiagram
  participant MacClip as macOS clipboard
  participant Helper as moonclipctl
  participant Sync as macOS sync loop
  participant Tunnel as SSH clipboard TCP tunnel
  participant RemoteDir as Windows payload folder
  participant Agent as Windows GUI agent
  participant Receiver as macOS TCP receiver
  participant WinClip as Windows clipboard

  MacClip->>Helper: Export current clipboard
  Helper->>Sync: manifest.json plus payload files
  Sync->>Tunnel: Send ZIP frame
  Tunnel->>Agent: Forward to loopback TCP listener
  Agent->>WinClip: Import text, image, or files

  WinClip->>Agent: Export changed clipboard
  Agent->>Tunnel: Send ZIP frame
  Tunnel->>Receiver: Forward to macOS loopback listener
  Receiver->>Helper: Import payload
  Helper->>MacClip: Write text, image, or files

  Sync-->>RemoteDir: Fallback upload if TCP send fails
  Agent-->>RemoteDir: Fallback write if TCP send fails
  Sync-->>RemoteDir: Poll fallback archive
```

## Caps Lock Han/Eng Flow

```mermaid
sequenceDiagram
  participant User
  participant Moonlight as Moonlight.app
  participant Caps as macOS Caps Lock agent
  participant Tunnel as SSH local tunnel
  participant Agent as Windows GUI agent
  participant IME as Windows Korean IME

  User->>Moonlight: Press Caps Lock
  Caps->>Caps: Detect Moonlight as frontmost app
  Caps->>Tunnel: Send toggle command over local TCP
  Tunnel->>Agent: Forward to loopback TCP listener
  Agent->>IME: Toggle active conversion mode
```

## Clipboard Payloads

Clipboard contents are exported into a payload directory:

```text
manifest.json
text.txt
image.png
files/
```

Only one primary clipboard kind is synced at a time:

- `files`
- `image`
- `text`

That priority is deliberate. File clipboard entries often also expose text paths or thumbnails, and those should not override the actual file-drop intent.

## Loop Prevention

Each payload has a deterministic `id` based on kind and content hash. Agents remember the last imported ID so the same payload is not immediately mirrored back.

## Windows Session Caveat

Windows clipboard APIs are tied to the interactive GUI session. Reading or writing the clipboard from an SSH service session is not reliable for GUI clipboard data, so the Windows agent must run in the logged-in desktop session.

macOS Caps Lock detection uses a local event tap. If macOS blocks the event tap, grant Accessibility permission to the helper process and restart Moonlight Companion. Caps Lock and clipboard TCP commands use SSH tunnels to reach loopback-only listeners in the Windows GUI session; if a tunnel disconnects, launchd closes the forwarding process and restarts it.
