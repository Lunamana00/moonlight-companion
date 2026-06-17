$ErrorActionPreference = "SilentlyContinue"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.IO.Compression.FileSystem

$dir = Join-Path $env:USERPROFILE ".moonlight-clipboard-sync"
$macZip = Join-Path $dir "mac-to-windows.zip"
$windowsZip = Join-Path $dir "windows-to-mac.zip"
$windowsTmpZip = Join-Path $dir "windows-to-mac.tmp.zip"
$exportRoot = Join-Path $dir "windows-payloads"
$importDir = Join-Path $dir "imported-mac-payload"
$normalizedDir = Join-Path $dir "windows-normalized-payload"
$logFile = Join-Path $dir "windows-agent.log"
$settingsPath = Join-Path $dir "windows-agent-settings.ps1"
$maxBytes = 52428800
$intervalMs = 700
$MoonlightCapsLockHangul = "yes"

New-Item -ItemType Directory -Force -Path $dir | Out-Null

$mutex = New-Object System.Threading.Mutex($false, "Global\MoonlightClipboardSyncAgent")
if (-not $mutex.WaitOne(0)) {
    exit 0
}

function Write-AgentLog($message) {
    try {
        Add-Content -Path $logFile -Value ("{0} {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $message) -Encoding UTF8
    } catch {}
}

if (Test-Path -LiteralPath $settingsPath) {
    try {
        . $settingsPath
    } catch {}
}

function Test-SettingEnabled($value, $defaultValue) {
    if ($null -eq $value) { return $defaultValue }
    switch ($value.ToString().Trim().ToLowerInvariant()) {
        "1" { return $true }
        "true" { return $true }
        "yes" { return $true }
        "on" { return $true }
        "0" { return $false }
        "false" { return $false }
        "no" { return $false }
        "off" { return $false }
        default { return $defaultValue }
    }
}

function Install-CapsLockHangulHook {
    $source = @"
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;

public static class MoonlightCapsLockHangulHook
{
    private const int WH_KEYBOARD_LL = 13;
    private const int WM_KEYDOWN = 0x0100;
    private const int WM_KEYUP = 0x0101;
    private const int WM_SYSKEYDOWN = 0x0104;
    private const int WM_SYSKEYUP = 0x0105;
    private const int WM_IME_CONTROL = 0x0283;
    private const short VK_CAPITAL = 0x14;
    private const short VK_HANGUL = 0x15;
    private const short HANGUL_SCAN_CODE = 0x72;
    private const int IMC_GETCONVERSIONMODE = 0x0001;
    private const int IMC_SETCONVERSIONMODE = 0x0002;
    private const int IME_CMODE_NATIVE = 0x0001;
    private const int INPUT_KEYBOARD = 1;
    private const int KEYEVENTF_KEYUP = 0x0002;
    private const int KEYEVENTF_SCANCODE = 0x0008;

    private static readonly object SyncRoot = new object();
    private static readonly LowLevelKeyboardProc Proc = HookCallback;
    private static IntPtr hookId = IntPtr.Zero;
    private static Thread hookThread = null;
    private static ApplicationContext context = null;
    private static ManualResetEventSlim ready = null;
    private static bool capsDown = false;

    public static bool Install()
    {
        lock (SyncRoot)
        {
            if (hookThread != null && hookThread.IsAlive)
            {
                return hookId != IntPtr.Zero;
            }

            ready = new ManualResetEventSlim(false);
            hookThread = new Thread(HookThreadMain);
            hookThread.IsBackground = true;
            hookThread.SetApartmentState(ApartmentState.STA);
            hookThread.Start();
        }

        ready.Wait(3000);
        return hookId != IntPtr.Zero;
    }

    public static void Uninstall()
    {
        ApplicationContext currentContext = context;
        if (currentContext != null)
        {
            currentContext.ExitThread();
        }
    }

    private static void HookThreadMain()
    {
        EnsureCapsLockOff();
        hookId = SetHook(Proc);
        context = new ApplicationContext();
        ready.Set();

        if (hookId != IntPtr.Zero)
        {
            Application.Run(context);
            UnhookWindowsHookEx(hookId);
            hookId = IntPtr.Zero;
        }
    }

    private static IntPtr SetHook(LowLevelKeyboardProc proc)
    {
        using (Process currentProcess = Process.GetCurrentProcess())
        using (ProcessModule currentModule = currentProcess.MainModule)
        {
            return SetWindowsHookEx(WH_KEYBOARD_LL, proc, GetModuleHandle(currentModule.ModuleName), 0);
        }
    }

    private static IntPtr HookCallback(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0)
        {
            int vkCode = Marshal.ReadInt32(lParam);
            if (vkCode == VK_CAPITAL)
            {
                int message = wParam.ToInt32();
                bool isDown = message == WM_KEYDOWN || message == WM_SYSKEYDOWN;
                bool isUp = message == WM_KEYUP || message == WM_SYSKEYUP;

                if (isDown)
                {
                    if (!capsDown)
                    {
                        capsDown = true;
                        if (!ToggleForegroundImeWindowConversion() && !SendScanCode(HANGUL_SCAN_CODE))
                        {
                            SendKey(VK_HANGUL);
                        }
                    }
                    return new IntPtr(1);
                }

                if (isUp)
                {
                    capsDown = false;
                    return new IntPtr(1);
                }
            }
        }

        return CallNextHookEx(hookId, nCode, wParam, lParam);
    }

    private static bool ToggleForegroundImeWindowConversion()
    {
        IntPtr foregroundWindow = GetForegroundWindow();
        if (foregroundWindow == IntPtr.Zero)
        {
            return false;
        }

        IntPtr focusedWindow = GetFocusedWindow(foregroundWindow);
        if (ToggleImeWindowConversion(focusedWindow))
        {
            return true;
        }

        return focusedWindow != foregroundWindow && ToggleImeWindowConversion(foregroundWindow);
    }

    private static bool ToggleImeWindowConversion(IntPtr window)
    {
        if (window == IntPtr.Zero)
        {
            return false;
        }

        IntPtr imeWindow = ImmGetDefaultIMEWnd(window);
        if (imeWindow == IntPtr.Zero)
        {
            return false;
        }

        int conversion = SendMessage(imeWindow, WM_IME_CONTROL, new IntPtr(IMC_GETCONVERSIONMODE), IntPtr.Zero).ToInt32();
        int nextConversion = conversion ^ IME_CMODE_NATIVE;
        SendMessage(imeWindow, WM_IME_CONTROL, new IntPtr(IMC_SETCONVERSIONMODE), new IntPtr(nextConversion));

        int verifiedConversion = SendMessage(imeWindow, WM_IME_CONTROL, new IntPtr(IMC_GETCONVERSIONMODE), IntPtr.Zero).ToInt32();
        return (verifiedConversion & IME_CMODE_NATIVE) != (conversion & IME_CMODE_NATIVE);
    }

    private static IntPtr GetFocusedWindow(IntPtr foregroundWindow)
    {
        uint threadId = GetWindowThreadProcessId(foregroundWindow, IntPtr.Zero);
        if (threadId == 0)
        {
            return foregroundWindow;
        }

        GUITHREADINFO threadInfo = new GUITHREADINFO();
        threadInfo.cbSize = Marshal.SizeOf(typeof(GUITHREADINFO));
        if (GetGUIThreadInfo(threadId, ref threadInfo))
        {
            if (threadInfo.hwndFocus != IntPtr.Zero)
            {
                return threadInfo.hwndFocus;
            }

            if (threadInfo.hwndActive != IntPtr.Zero)
            {
                return threadInfo.hwndActive;
            }
        }

        return foregroundWindow;
    }

    private static void EnsureCapsLockOff()
    {
        if ((GetKeyState(VK_CAPITAL) & 1) != 0)
        {
            SendKey(VK_CAPITAL);
        }
    }

    private static void SendKey(short virtualKey)
    {
        INPUT[] inputs = new INPUT[2];
        inputs[0].type = INPUT_KEYBOARD;
        inputs[0].u.ki.wVk = virtualKey;
        inputs[1].type = INPUT_KEYBOARD;
        inputs[1].u.ki.wVk = virtualKey;
        inputs[1].u.ki.dwFlags = KEYEVENTF_KEYUP;
        SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(INPUT)));
    }

    private static bool SendScanCode(short scanCode)
    {
        INPUT[] inputs = new INPUT[2];
        inputs[0].type = INPUT_KEYBOARD;
        inputs[0].u.ki.wScan = scanCode;
        inputs[0].u.ki.dwFlags = KEYEVENTF_SCANCODE;
        inputs[1].type = INPUT_KEYBOARD;
        inputs[1].u.ki.wScan = scanCode;
        inputs[1].u.ki.dwFlags = KEYEVENTF_SCANCODE | KEYEVENTF_KEYUP;
        return SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(INPUT))) == inputs.Length;
    }

    private delegate IntPtr LowLevelKeyboardProc(int nCode, IntPtr wParam, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential)]
    private struct INPUT
    {
        public int type;
        public InputUnion u;
    }

    [StructLayout(LayoutKind.Explicit)]
    private struct InputUnion
    {
        [FieldOffset(0)]
        public KEYBDINPUT ki;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct KEYBDINPUT
    {
        public short wVk;
        public short wScan;
        public int dwFlags;
        public int time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct GUITHREADINFO
    {
        public int cbSize;
        public int flags;
        public IntPtr hwndActive;
        public IntPtr hwndFocus;
        public IntPtr hwndCapture;
        public IntPtr hwndMenuOwner;
        public IntPtr hwndMoveSize;
        public IntPtr hwndCaret;
        public RECT rcCaret;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct RECT
    {
        public int left;
        public int top;
        public int right;
        public int bottom;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr SetWindowsHookEx(int idHook, LowLevelKeyboardProc lpfn, IntPtr hMod, uint dwThreadId);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool UnhookWindowsHookEx(IntPtr hhk);

    [DllImport("user32.dll")]
    private static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);

    [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    private static extern IntPtr GetModuleHandle(string lpModuleName);

    [DllImport("user32.dll")]
    private static extern short GetKeyState(short nVirtKey);

    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, IntPtr lpdwProcessId);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetGUIThreadInfo(uint idThread, ref GUITHREADINFO lpgui);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    private static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);

    [DllImport("imm32.dll")]
    private static extern IntPtr ImmGetDefaultIMEWnd(IntPtr hWnd);
}
"@

    try {
        Add-Type -TypeDefinition $source -ReferencedAssemblies "System.Windows.Forms.dll" -ErrorAction Stop
        return [MoonlightCapsLockHangulHook]::Install()
    } catch {
        Write-AgentLog ("Caps Lock Hangul hook error: {0}" -f $_.Exception.Message)
        return $false
    }
}

function Get-TextBytes($text) {
    if ($null -eq $text) { return 0 }
    return [System.Text.Encoding]::UTF8.GetByteCount($text)
}

function Get-StringHash($text) {
    if ($null -eq $text) { $text = "" }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($text)
        return ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace("-", "").ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Get-FileHashString($path) {
    if (-not (Test-Path -LiteralPath $path)) { return "" }
    return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-DirectoryBytes($path) {
    if (-not (Test-Path -LiteralPath $path)) { return 0 }
    $total = 0L
    Get-ChildItem -LiteralPath $path -Recurse -Force -File | ForEach-Object { $total += $_.Length }
    return $total
}

function Get-PathHash($path) {
    if ((Get-Item -LiteralPath $path).PSIsContainer) {
        $base = (Resolve-Path -LiteralPath $path).Path
        $lines = New-Object System.Collections.Generic.List[string]
        Get-ChildItem -LiteralPath $path -Recurse -Force | Sort-Object FullName | ForEach-Object {
            $relative = $_.FullName.Substring($base.Length).TrimStart("\")
            if ($_.PSIsContainer) {
                $lines.Add("d:${relative}")
            } else {
                $lines.Add("f:${relative}:$((Get-FileHashString $_.FullName))")
            }
        }
        return Get-StringHash ($lines -join "`n")
    }

    return Get-FileHashString $path
}

function Clear-Directory($path) {
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $path | Out-Null
}

function New-TemporaryPayloadDirectory($root) {
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    return Join-Path $root ([guid]::NewGuid().ToString("N"))
}

function Remove-OldPayloadDirectories($root) {
    if (-not (Test-Path -LiteralPath $root)) { return }
    $cutoff = (Get-Date).AddMinutes(-5)
    Get-ChildItem -LiteralPath $root -Directory -Force | Where-Object {
        $_.LastWriteTime -lt $cutoff
    } | ForEach-Object {
        Remove-Item -LiteralPath $_.FullName -Recurse -Force
    }
}

function Write-JsonManifest($manifest, $payloadDir) {
    $json = $manifest | ConvertTo-Json -Depth 8
    [System.IO.File]::WriteAllText(
        (Join-Path $payloadDir "manifest.json"),
        $json,
        [System.Text.UTF8Encoding]::new($false)
    )
}

function Read-JsonManifest($payloadDir) {
    $manifestPath = Join-Path $payloadDir "manifest.json"
    if (-not (Test-Path -LiteralPath $manifestPath)) { return $null }
    return Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Copy-ItemUnique($source, $destDir) {
    $name = Split-Path -Leaf $source
    if ([string]::IsNullOrWhiteSpace($name)) { $name = "file" }
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($name)
    $ext = [System.IO.Path]::GetExtension($name)
    $candidate = $name
    $index = 2
    while (Test-Path -LiteralPath (Join-Path $destDir $candidate)) {
        $candidate = if ([string]::IsNullOrEmpty($ext)) { "$stem-$index" } else { "$stem-$index$ext" }
        $index++
    }
    $dest = Join-Path $destDir $candidate
    Copy-Item -LiteralPath $source -Destination $dest -Recurse -Force
    return $dest
}

function Export-ClipboardPayload($payloadDir) {
    Clear-Directory $payloadDir

    if ([System.Windows.Forms.Clipboard]::ContainsFileDropList()) {
        $filesDir = Join-Path $payloadDir "files"
        New-Item -ItemType Directory -Force -Path $filesDir | Out-Null
        $items = @()
        $hashLines = New-Object System.Collections.Generic.List[string]
        $bytes = 0L

        foreach ($path in [System.Windows.Forms.Clipboard]::GetFileDropList()) {
            if (-not (Test-Path -LiteralPath $path)) { continue }
            $dest = Copy-ItemUnique $path $filesDir
            $item = Get-Item -LiteralPath $dest
            $isDirectory = [bool]$item.PSIsContainer
            $itemBytes = if ($isDirectory) { Get-DirectoryBytes $dest } else { $item.Length }
            $itemHash = Get-PathHash $dest
            $bytes += $itemBytes
            $relativePath = "files/" + (Split-Path -Leaf $dest)
            $items += [pscustomobject]@{
                name = Split-Path -Leaf $dest
                path = $relativePath
                isDirectory = $isDirectory
                bytes = $itemBytes
            }
            $itemKind = if ($isDirectory) { "d" } else { "f" }
            $hashLines.Add(("{0}:{1}:{2}" -f $itemKind, (Split-Path -Leaf $dest), $itemHash))
        }

        if ($items.Count -gt 0) {
            $id = "files:" + (Get-StringHash (($hashLines | Sort-Object) -join "`n"))
            $manifest = [pscustomobject]@{
                version = 2
                origin = "windows"
                kind = "files"
                id = $id
                bytes = $bytes
                textFile = $null
                imageFile = $null
                files = $items
            }
            Write-JsonManifest $manifest $payloadDir
            return $manifest
        }
    }

    if ([System.Windows.Forms.Clipboard]::ContainsImage()) {
        $imagePath = Join-Path $payloadDir "image.png"
        $image = [System.Windows.Forms.Clipboard]::GetImage()
        if ($null -ne $image) {
            $image.Save($imagePath, [System.Drawing.Imaging.ImageFormat]::Png)
            $bytes = (Get-Item -LiteralPath $imagePath).Length
            $id = "image:" + (Get-FileHashString $imagePath)
            $manifest = [pscustomobject]@{
                version = 2
                origin = "windows"
                kind = "image"
                id = $id
                bytes = $bytes
                textFile = $null
                imageFile = "image.png"
                files = $null
            }
            Write-JsonManifest $manifest $payloadDir
            return $manifest
        }
    }

    if ([System.Windows.Forms.Clipboard]::ContainsText()) {
        $text = [System.Windows.Forms.Clipboard]::GetText()
        if (-not [string]::IsNullOrEmpty($text)) {
            $textPath = Join-Path $payloadDir "text.txt"
            [System.IO.File]::WriteAllText($textPath, $text, [System.Text.UTF8Encoding]::new($false))
            $bytes = Get-TextBytes $text
            $id = "text:" + (Get-StringHash $text)
            $manifest = [pscustomobject]@{
                version = 2
                origin = "windows"
                kind = "text"
                id = $id
                bytes = $bytes
                textFile = "text.txt"
                imageFile = $null
                files = $null
            }
            Write-JsonManifest $manifest $payloadDir
            return $manifest
        }
    }

    return $null
}

function Import-ClipboardPayload($payloadDir) {
    $manifest = Read-JsonManifest $payloadDir
    if ($null -eq $manifest) { return $null }

    switch ($manifest.kind) {
        "text" {
            $text = [System.IO.File]::ReadAllText((Join-Path $payloadDir $manifest.textFile), [System.Text.UTF8Encoding]::new($false))
            [System.Windows.Forms.Clipboard]::SetText($text)
        }
        "image" {
            $imagePath = Join-Path $payloadDir $manifest.imageFile
            $sourceImage = [System.Drawing.Image]::FromFile($imagePath)
            try {
                $bitmap = New-Object System.Drawing.Bitmap($sourceImage)
                [System.Windows.Forms.Clipboard]::SetImage($bitmap)
            }
            finally {
                $sourceImage.Dispose()
            }
        }
        "files" {
            $collection = New-Object System.Collections.Specialized.StringCollection
            foreach ($item in $manifest.files) {
                [void]$collection.Add((Join-Path $payloadDir $item.path))
            }
            [System.Windows.Forms.Clipboard]::SetFileDropList($collection)
        }
        default {
            return $null
        }
    }

    return $manifest
}

function Compress-Payload($payloadDir, $zipPath, $tmpZipPath) {
    Remove-Item -LiteralPath $tmpZipPath -Force -ErrorAction SilentlyContinue
    [System.IO.Compression.ZipFile]::CreateFromDirectory(
        $payloadDir,
        $tmpZipPath,
        [System.IO.Compression.CompressionLevel]::Optimal,
        $false
    )
    Move-Item -LiteralPath $tmpZipPath -Destination $zipPath -Force
}

function Expand-Payload($zipPath, $payloadDir) {
    Clear-Directory $payloadDir
    [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $payloadDir)
}

$lastMacArchiveHash = ""
$lastMacId = ""
$lastWindowsId = ""
$enableCapsLockHangul = Test-SettingEnabled $MoonlightCapsLockHangul $true
$capsLockHangulHookInstalled = $false

Write-AgentLog "started"

try {
    if ($enableCapsLockHangul) {
        $capsLockHangulHookInstalled = Install-CapsLockHangulHook
        if ($capsLockHangulHookInstalled) {
            Write-AgentLog "Caps Lock Hangul toggle enabled"
        } else {
            Write-AgentLog "Caps Lock Hangul toggle unavailable"
        }
    } else {
        Write-AgentLog "Caps Lock Hangul toggle disabled"
    }

    while ($true) {
        try {
            if (Test-Path -LiteralPath $macZip) {
                $macArchiveHash = Get-FileHashString $macZip
                if ($macArchiveHash -ne $lastMacArchiveHash) {
                    Expand-Payload $macZip $importDir
                    $imported = Import-ClipboardPayload $importDir
                    if ($null -ne $imported) {
                        $normalized = Export-ClipboardPayload $normalizedDir
                        $lastMacArchiveHash = $macArchiveHash
                        $lastMacId = $imported.id
                        $lastWindowsId = if ($null -ne $normalized) { $normalized.id } else { $imported.id }
                        Write-AgentLog ("Mac -> Windows {0} ({1}B)" -f $imported.kind, $imported.bytes)
                    }
                }
            }

            $exportDir = New-TemporaryPayloadDirectory $exportRoot
            try {
                $exported = Export-ClipboardPayload $exportDir
                if ($null -ne $exported -and $exported.id -ne $lastWindowsId) {
                    if ($exported.id -eq $lastMacId) {
                        $lastWindowsId = $exported.id
                    } elseif ($exported.bytes -gt $maxBytes) {
                        $lastWindowsId = $exported.id
                        Write-AgentLog ("skip Windows -> Mac {0} ({1}B); limit is {2}B" -f $exported.kind, $exported.bytes, $maxBytes)
                    } else {
                        Compress-Payload $exportDir $windowsZip $windowsTmpZip
                        $lastWindowsId = $exported.id
                        Write-AgentLog ("Windows -> Mac {0} ({1}B)" -f $exported.kind, $exported.bytes)
                    }
                }
            } finally {
                Remove-Item -LiteralPath $exportDir -Recurse -Force
            }
            Remove-OldPayloadDirectories $exportRoot
        } catch {
            Write-AgentLog ("error: {0}" -f $_.Exception.Message)
        }

        Start-Sleep -Milliseconds $intervalMs
    }
}
finally {
    if ($capsLockHangulHookInstalled) {
        try { [MoonlightCapsLockHangulHook]::Uninstall() } catch {}
    }
    try { $mutex.ReleaseMutex() | Out-Null } catch {}
    $mutex.Dispose()
}
