$ErrorActionPreference = "SilentlyContinue"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.IO.Compression.FileSystem

$dir = Join-Path $env:USERPROFILE ".moonlight-clipboard-sync"
$macZip = Join-Path $dir "mac-to-windows.zip"
$windowsZip = Join-Path $dir "windows-to-mac.zip"
$windowsTmpZip = Join-Path $dir "windows-to-mac.tmp.zip"
$macImportState = Join-Path $dir "mac-to-windows-import-state.txt"
$exportRoot = Join-Path $dir "windows-payloads"
$importDir = Join-Path $dir "imported-mac-payload"
$normalizedDir = Join-Path $dir "windows-normalized-payload"
$logFile = Join-Path $dir "windows-agent.log"
$settingsPath = Join-Path $dir "windows-agent-settings.ps1"
$capsLockHangulRequest = Join-Path $dir "capslock-hangul-toggle.request"
$maxBytes = 52428800
$intervalMs = 700
$MoonlightClipboardMaxBytes = "52428800"
$MoonlightCapsLockHangul = "yes"
$MoonlightCapsLockHangulTcpPort = "47321"
$MoonlightClipboardTcp = "yes"
$MoonlightClipboardMacToWindowsTcpPort = "47331"
$MoonlightClipboardWindowsToMacTcpPort = "47332"
$MoonlightTransferOversizeDirect = "yes"
$MoonlightTransferWindowsDir = "%USERPROFILE%\Downloads\Moonlight Companion"
$MoonlightMacFallbackMaxFailures = "3"
$agentLoadOnly = "$env:MOONLIGHT_AGENT_LOAD_ONLY".Trim().ToLowerInvariant() -in @("1", "true", "yes", "on")

New-Item -ItemType Directory -Force -Path $dir | Out-Null

$mutex = $null
if (-not $agentLoadOnly) {
    $mutex = New-Object System.Threading.Mutex($false, "Global\MoonlightClipboardSyncAgent")
    if (-not $mutex.WaitOne(0)) {
        exit 0
    }
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

function Get-IntSetting($value, $defaultValue) {
    if ($null -eq $value) { return $defaultValue }
    try {
        $parsed = 0
        if ([int]::TryParse($value.ToString().Trim(), [ref]$parsed)) {
            return $parsed
        }
    } catch {}
    return $defaultValue
}

function Get-PositiveIntSetting($value, $defaultValue) {
    $parsed = Get-IntSetting $value $defaultValue
    if ($parsed -gt 0) { return $parsed }
    return $defaultValue
}

function Get-ExpandedPathSetting($value, $defaultValue) {
    $raw = $defaultValue
    if ($null -ne $value -and -not [string]::IsNullOrWhiteSpace($value.ToString())) {
        $raw = $value.ToString()
    }
    return [Environment]::ExpandEnvironmentVariables($raw)
}

function Install-CapsLockHangulHook {
    $source = @"
using System;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
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
    private static readonly object TcpSyncRoot = new object();
    private static TcpListener tcpListener = null;
    private static Thread tcpThread = null;
    private static ManualResetEventSlim tcpReady = null;
    private static volatile bool tcpRunning = false;
    private static bool tcpStarted = false;
    private static string tcpLogFile = null;

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
        StopTcpListener();

        ApplicationContext currentContext = context;
        if (currentContext != null)
        {
            currentContext.ExitThread();
        }
    }

    public static int Toggle()
    {
        EnsureCapsLockOff();

        if (SendKey(VK_HANGUL))
        {
            return 1;
        }

        if (SendScanCode(HANGUL_SCAN_CODE))
        {
            return 2;
        }

        ToggleForegroundImeWindowConversion();
        return 3;
    }

    public static bool StartTcpListener(int port, string logFile)
    {
        if (port <= 0 || port > 65535)
        {
            return false;
        }

        lock (TcpSyncRoot)
        {
            if (tcpThread != null && tcpThread.IsAlive)
            {
                return true;
            }

            tcpLogFile = logFile;
            tcpRunning = true;
            tcpStarted = false;
            tcpReady = new ManualResetEventSlim(false);
            tcpThread = new Thread(() => TcpListenerThreadMain(port));
            tcpThread.IsBackground = true;
            tcpThread.Start();
        }

        tcpReady.Wait(3000);
        return tcpStarted;
    }

    private static void StopTcpListener()
    {
        lock (TcpSyncRoot)
        {
            tcpRunning = false;
            if (tcpListener != null)
            {
                try { tcpListener.Stop(); } catch {}
            }
        }
    }

    private static void TcpListenerThreadMain(int port)
    {
        TcpListener listener = null;

        try
        {
            listener = new TcpListener(IPAddress.Loopback, port);
            listener.Start();

            lock (TcpSyncRoot)
            {
                tcpListener = listener;
                tcpStarted = true;
            }

            LogTcp("Caps Lock Hangul TCP listener started on 127.0.0.1:" + port);
            tcpReady.Set();

            while (tcpRunning)
            {
                try
                {
                    TcpClient client = listener.AcceptTcpClient();
                    client.NoDelay = true;

                    Thread clientThread = new Thread(() => HandleTcpClient(client));
                    clientThread.IsBackground = true;
                    clientThread.Start();
                }
                catch (ObjectDisposedException)
                {
                    break;
                }
                catch (SocketException ex)
                {
                    if (tcpRunning)
                    {
                        LogTcp("Caps Lock Hangul TCP accept error: " + ex.Message);
                    }
                }
            }
        }
        catch (Exception ex)
        {
            LogTcp("Caps Lock Hangul TCP listener error: " + ex.Message);
            lock (TcpSyncRoot)
            {
                tcpStarted = false;
            }
            tcpReady.Set();
        }
        finally
        {
            try { if (listener != null) { listener.Stop(); } } catch {}
            lock (TcpSyncRoot)
            {
                if (tcpListener == listener)
                {
                    tcpListener = null;
                }
                tcpRunning = false;
            }
        }
    }

    private static void HandleTcpClient(TcpClient client)
    {
        try
        {
            using (client)
            using (NetworkStream stream = client.GetStream())
            using (StreamReader reader = new StreamReader(stream, Encoding.UTF8))
            {
                string line;
                while (tcpRunning && (line = reader.ReadLine()) != null)
                {
                    string command = line.Trim();
                    if (command.Length == 0)
                    {
                        continue;
                    }

                    if (string.Equals(command, "toggle", StringComparison.OrdinalIgnoreCase))
                    {
                        int result = Toggle();
                        LogTcp("Caps Lock Hangul TCP " + ToggleResultMessage(result));
                    }
                    else
                    {
                        LogTcp("Caps Lock Hangul TCP ignored unknown command");
                    }
                }
            }
        }
        catch (IOException)
        {
        }
        catch (ObjectDisposedException)
        {
        }
        catch (Exception ex)
        {
            if (tcpRunning)
            {
                LogTcp("Caps Lock Hangul TCP client error: " + ex.Message);
            }
        }
    }

    private static string ToggleResultMessage(int result)
    {
        if (result == 1)
        {
            return "toggle request virtual-key sent";
        }

        if (result == 2)
        {
            return "toggle request scan-code fallback sent";
        }

        return "toggle request IME fallback sent";
    }

    private static void LogTcp(string message)
    {
        if (string.IsNullOrEmpty(tcpLogFile))
        {
            return;
        }

        try
        {
            File.AppendAllText(
                tcpLogFile,
                DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + " " + message + Environment.NewLine,
                Encoding.UTF8);
        }
        catch
        {
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
                        Toggle();
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

    private static bool SendKey(short virtualKey)
    {
        INPUT[] inputs = new INPUT[2];
        inputs[0].type = INPUT_KEYBOARD;
        inputs[0].u.ki.wVk = virtualKey;
        inputs[1].type = INPUT_KEYBOARD;
        inputs[1].u.ki.wVk = virtualKey;
        inputs[1].u.ki.dwFlags = KEYEVENTF_KEYUP;
        return SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(INPUT))) == inputs.Length;
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
        public MOUSEINPUT mi;
        [FieldOffset(0)]
        public KEYBDINPUT ki;
        [FieldOffset(0)]
        public HARDWAREINPUT hi;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MOUSEINPUT
    {
        public int dx;
        public int dy;
        public int mouseData;
        public int dwFlags;
        public int time;
        public IntPtr dwExtraInfo;
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
    private struct HARDWAREINPUT
    {
        public int uMsg;
        public short wParamL;
        public short wParamH;
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

function Remove-FileIfHashMatches($path, $expectedHash) {
    if ([string]::IsNullOrWhiteSpace($expectedHash)) { return $false }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }

    try {
        if ((Get-FileHashString $path) -ne $expectedHash) { return $false }
        Remove-Item -LiteralPath $path -Force -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
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

function Write-KeyValueState($path, [string[]]$lines) {
    $tmpPath = "$path.tmp"
    Set-Content -LiteralPath $tmpPath -Value $lines -Encoding UTF8
    Move-Item -LiteralPath $tmpPath -Destination $path -Force
}

function Write-MacImportState($manifest, $archiveHash) {
    if ($null -eq $manifest) { return }

    $paths = @()
    if ($null -ne $manifest.importedPaths) {
        $paths = @($manifest.importedPaths)
    }

    $fileCount = 0
    if ($null -ne $manifest.files) {
        $fileCount = @($manifest.files).Count
    }

    $lines = @(
        "archive_hash=$archiveHash",
        "id=$($manifest.id)",
        "kind=$($manifest.kind)",
        "bytes=$($manifest.bytes)",
        "files=$fileCount",
        "imported_paths=$($paths.Count)"
    )

    for ($i = 0; $i -lt $paths.Count; $i++) {
        $lines += "imported_path_$($i + 1)=$($paths[$i])"
    }
    $names = @()
    foreach ($path in $paths) {
        $name = Split-Path -Leaf $path
        if (-not [string]::IsNullOrWhiteSpace($name)) {
            $names += $name
        }
    }
    $namesForState = @($names | Select-Object -First 12)
    if ($namesForState.Count -gt 0) {
        $namesText = [string]::Join([string][char]31, $namesForState)
        $namesB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($namesText))
        $lines += "imported_names_b64=$namesB64"
    }

    Write-KeyValueState $macImportState $lines
}

function Get-FileDropIdFromPaths($paths) {
    $hashLines = New-Object System.Collections.Generic.List[string]

    foreach ($path in @($paths)) {
        try {
            if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path)) {
                return ""
            }

            $item = Get-Item -LiteralPath $path -ErrorAction Stop
            $itemKind = if ($item.PSIsContainer) { "d" } else { "f" }
            $itemHash = Get-PathHash $path
            $hashLines.Add(("{0}:{1}:{2}" -f $itemKind, (Split-Path -Leaf $path), $itemHash))
        } catch {
            return ""
        }
    }

    if ($hashLines.Count -eq 0) { return "" }
    return "files:" + (Get-StringHash (($hashLines | Sort-Object) -join "`n"))
}

function Get-ImportedPayloadNormalizedId($manifest) {
    if ($null -eq $manifest) { return "" }
    if ($manifest.kind -ne "files") { return "" }
    if ($null -eq $manifest.importedPaths) { return "" }
    return Get-FileDropIdFromPaths @($manifest.importedPaths)
}

function Read-JsonManifest($payloadDir) {
    $manifestPath = Join-Path $payloadDir "manifest.json"
    if (-not (Test-Path -LiteralPath $manifestPath)) { return $null }
    return Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Get-NormalizedFileName($name) {
    if ([string]::IsNullOrWhiteSpace($name)) { return "file" }
    $safeName = $name.Normalize([System.Text.NormalizationForm]::FormC)
    foreach ($invalidChar in [System.IO.Path]::GetInvalidFileNameChars()) {
        $safeName = $safeName.Replace([string]$invalidChar, "_")
    }
    $safeName = $safeName.TrimEnd([char[]]@(" ", "."))
    if ([string]::IsNullOrWhiteSpace($safeName) -or $safeName -eq "." -or $safeName -eq "..") {
        $safeName = "file"
    }

    $reservedNames = @(
        "CON", "PRN", "AUX", "NUL",
        "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
        "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9"
    )
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($safeName)
    if ($reservedNames -contains $stem.ToUpperInvariant()) {
        $safeName = "_$safeName"
    }

    return $safeName
}

function Normalize-PathTreeNames($path) {
    if (-not (Test-Path -LiteralPath $path)) { return $path }

    $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
    if ($item.PSIsContainer) {
        Get-ChildItem -LiteralPath $item.FullName -Force | ForEach-Object {
            Normalize-PathTreeNames $_.FullName | Out-Null
        }
    }

    $name = Split-Path -Leaf $item.FullName
    $normalizedName = Get-NormalizedFileName $name
    if ($name -eq $normalizedName) { return $item.FullName }

    $parent = Split-Path -Parent $item.FullName
    $candidate = $normalizedName
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($normalizedName)
    $ext = [System.IO.Path]::GetExtension($normalizedName)
    $index = 2
    while (Test-Path -LiteralPath (Join-Path $parent $candidate)) {
        $candidate = if ([string]::IsNullOrEmpty($ext)) { "$stem-$index" } else { "$stem-$index$ext" }
        $index++
    }

    $dest = Join-Path $parent $candidate
    Move-Item -LiteralPath $item.FullName -Destination $dest -Force -ErrorAction Stop
    return $dest
}

function Copy-ItemUniqueNamed($source, $destDir, $name) {
    New-Item -ItemType Directory -Force -Path $destDir -ErrorAction Stop | Out-Null
    $normalizedName = Get-NormalizedFileName $name
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($normalizedName)
    $ext = [System.IO.Path]::GetExtension($normalizedName)
    $candidate = $normalizedName
    $index = 2
    while (Test-Path -LiteralPath (Join-Path $destDir $candidate)) {
        $candidate = if ([string]::IsNullOrEmpty($ext)) { "$stem-$index" } else { "$stem-$index$ext" }
        $index++
    }
    $dest = Join-Path $destDir $candidate
    Copy-Item -LiteralPath $source -Destination $dest -Recurse -Force -ErrorAction Stop
    if (-not (Test-Path -LiteralPath $dest)) {
        throw "copy did not create destination: $dest"
    }
    return Normalize-PathTreeNames $dest
}

function Copy-ItemUnique($source, $destDir) {
    return Copy-ItemUniqueNamed $source $destDir (Split-Path -Leaf $source)
}

function Get-UniqueDestinationPath($destDir, $name, $usedNames) {
    $normalizedName = Get-NormalizedFileName $name
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($normalizedName)
    $ext = [System.IO.Path]::GetExtension($normalizedName)
    $candidate = $normalizedName
    $index = 2
    while ((Test-Path -LiteralPath (Join-Path $destDir $candidate)) -or $usedNames.Contains($candidate.ToLowerInvariant())) {
        $candidate = if ([string]::IsNullOrEmpty($ext)) { "$stem-$index" } else { "$stem-$index$ext" }
        $index++
    }
    [void]$usedNames.Add($candidate.ToLowerInvariant())
    return Join-Path $destDir $candidate
}

function Copy-PayloadFilesAtomically($payloadDir, $items, $destDir) {
    New-Item -ItemType Directory -Force -Path $destDir -ErrorAction Stop | Out-Null
    if (-not (Test-Path -LiteralPath $destDir -PathType Container)) {
        throw "receive folder path is not a directory: $destDir"
    }
    $usedNames = New-Object 'System.Collections.Generic.HashSet[string]'
    $planned = @()
    foreach ($item in $items) {
        $sourcePath = Join-Path $payloadDir $item.path
        $targetPath = Get-UniqueDestinationPath $destDir $item.name $usedNames
        $planned += [pscustomobject]@{
            Source = $sourcePath
            Target = $targetPath
            Name = Split-Path -Leaf $targetPath
        }
    }

    $stagingDir = Join-Path $destDir (".moonlight-companion-import-" + [guid]::NewGuid().ToString("N"))
    $staged = @()
    $moved = @()
    $stagingItem = New-Item -ItemType Directory -Path $stagingDir -ErrorAction Stop
    if ($null -eq $stagingItem -or -not (Test-Path -LiteralPath $stagingDir -PathType Container)) {
        throw "could not create staging directory: $stagingDir"
    }
    $stagingItem.Attributes = $stagingItem.Attributes -bor [System.IO.FileAttributes]::Hidden
    try {
        foreach ($entry in $planned) {
            $stagedPath = Join-Path $stagingDir $entry.Name
            Copy-Item -LiteralPath $entry.Source -Destination $stagedPath -Recurse -Force -ErrorAction Stop
            if (-not (Test-Path -LiteralPath $stagedPath)) {
                throw "copy did not create staging destination: $stagedPath"
            }
            $stagedPath = Normalize-PathTreeNames $stagedPath
            $staged += [pscustomobject]@{
                Path = $stagedPath
                Target = $entry.Target
            }
        }

        foreach ($entry in $staged) {
            Move-Item -LiteralPath $entry.Path -Destination $entry.Target -ErrorAction Stop
            $moved += $entry.Target
        }

        Remove-Item -LiteralPath $stagingDir -Recurse -Force -ErrorAction SilentlyContinue
        return $moved
    } catch {
        foreach ($path in $moved) {
            Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
        }
        Remove-Item -LiteralPath $stagingDir -Recurse -Force -ErrorAction SilentlyContinue
        throw
    }
}

function Export-FileDropPathsPayload($payloadDir, $fileDropPaths) {
    $fileDropPaths = @($fileDropPaths)
    $filesDir = Join-Path $payloadDir "files"
    New-Item -ItemType Directory -Force -Path $filesDir | Out-Null
    $items = @()
    $hashLines = New-Object System.Collections.Generic.List[string]
    $bytes = 0L
    $completeFileDrop = $true
    $failedFileDropPath = ""
    $failedFileDropReason = ""

    foreach ($path in $fileDropPaths) {
        try {
            if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path)) {
                $completeFileDrop = $false
                $failedFileDropPath = $path
                $failedFileDropReason = "source path is missing"
                break
            }
            $dest = Copy-ItemUnique $path $filesDir
            $item = Get-Item -LiteralPath $dest -ErrorAction Stop
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
        } catch {
            $completeFileDrop = $false
            $failedFileDropPath = $path
            $failedFileDropReason = $_.Exception.Message
            break
        }
    }

    if ($completeFileDrop -and $items.Count -eq $fileDropPaths.Count -and $items.Count -gt 0) {
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

    if ([string]::IsNullOrWhiteSpace($failedFileDropPath)) {
        Write-AgentLog "skip Windows -> Mac file clipboard; no readable file-drop items were available"
    } else {
        Write-AgentLog ("skip Windows -> Mac file clipboard; source unavailable '{0}': {1}" -f $failedFileDropPath, $failedFileDropReason)
    }
    Remove-Item -LiteralPath $filesDir -Recurse -Force -ErrorAction SilentlyContinue
    return $null
}

function Export-ClipboardPayload($payloadDir) {
    Clear-Directory $payloadDir

    if ([System.Windows.Forms.Clipboard]::ContainsFileDropList()) {
        $fileDropPaths = @([System.Windows.Forms.Clipboard]::GetFileDropList())
        return Export-FileDropPathsPayload $payloadDir $fileDropPaths
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
            $useTransferDir = -not [string]::IsNullOrWhiteSpace($script:transferWindowsDir)
            $targetPaths = @()
            if ($useTransferDir) {
                $targetPaths = @(Copy-PayloadFilesAtomically $payloadDir @($manifest.files) $script:transferWindowsDir)
            } else {
                foreach ($item in $manifest.files) {
                    $targetPaths += (Join-Path $payloadDir $item.path)
                }
            }
            foreach ($targetPath in $targetPaths) {
                [void]$collection.Add($targetPath)
            }
            [System.Windows.Forms.Clipboard]::SetFileDropList($collection)
            $manifest | Add-Member -NotePropertyName importedPaths -NotePropertyValue $targetPaths -Force
        }
        default {
            return $null
        }
    }

    return $manifest
}

function Compress-Payload($payloadDir, $zipPath, $tmpZipPath) {
    Remove-Item -LiteralPath $tmpZipPath -Force -ErrorAction SilentlyContinue
    try {
        [System.IO.Compression.ZipFile]::CreateFromDirectory(
            $payloadDir,
            $tmpZipPath,
            [System.IO.Compression.CompressionLevel]::Optimal,
            $false
        )
        Move-Item -LiteralPath $tmpZipPath -Destination $zipPath -Force -ErrorAction Stop
    } catch {
        Remove-Item -LiteralPath $tmpZipPath -Force -ErrorAction SilentlyContinue
        throw
    }
}

function Expand-Payload($zipPath, $payloadDir) {
    Clear-Directory $payloadDir
    [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $payloadDir)
}

function Start-ClipboardTcpListener($port) {
    if ($port -le 0 -or $port -gt 65535) { return $null }

    try {
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $port)
        $listener.Server.SetSocketOption(
            [System.Net.Sockets.SocketOptionLevel]::Socket,
            [System.Net.Sockets.SocketOptionName]::ReuseAddress,
            $true
        )
        $listener.Start(16)
        Write-AgentLog ("Clipboard TCP listener enabled on 127.0.0.1:{0}" -f $port)
        return $listener
    } catch {
        Write-AgentLog ("Clipboard TCP listener unavailable on 127.0.0.1:{0}: {1}" -f $port, $_.Exception.Message)
        return $null
    }
}

function Read-TcpLine($stream) {
    $bytes = New-Object System.Collections.Generic.List[byte]
    $buffer = New-Object byte[] 1

    while ($bytes.Count -lt 256) {
        $read = $stream.Read($buffer, 0, 1)
        if ($read -le 0) {
            throw "unexpected eof while reading TCP header"
        }

        if ($buffer[0] -eq 10) {
            return ([System.Text.Encoding]::UTF8.GetString($bytes.ToArray())).TrimEnd("`r")
        }

        $bytes.Add($buffer[0])
    }

    throw "TCP header too long"
}

function Read-OptionalTcpLine($stream, [int]$timeoutMs) {
    $previousTimeout = $stream.ReadTimeout
    try {
        $stream.ReadTimeout = $timeoutMs
        return Read-TcpLine $stream
    } catch {
        return ""
    } finally {
        try { $stream.ReadTimeout = $previousTimeout } catch {}
    }
}

function Parse-TcpAckLine([string]$line) {
    if ([string]::IsNullOrWhiteSpace($line)) { return $null }
    $parts = $line.Trim().Split(" ", [System.StringSplitOptions]::RemoveEmptyEntries)
    if ($parts.Count -lt 2 -or $parts[0] -ne "MOONCLIPACK" -or $parts[1] -ne "1") {
        return $null
    }

    $ack = @{}
    foreach ($part in $parts | Select-Object -Skip 2) {
        $fields = $part.Split("=", 2)
        if ($fields.Count -eq 2) {
            $ack[$fields[0]] = $fields[1]
        }
    }
    return $ack
}

function Write-TcpLine($stream, [string]$line) {
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes(("{0}`n" -f $line))
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush()
        return $true
    } catch {
        Write-AgentLog ("TCP response write error: {0}" -f $_.Exception.Message)
        return $false
    }
}

function Write-MacImportTcpAck($stream, $manifest) {
    if ($null -eq $manifest) { return }

    $paths = @()
    if ($null -ne $manifest.importedPaths) {
        $paths = @($manifest.importedPaths)
    }
    $names = @()
    foreach ($path in $paths) {
        $name = Split-Path -Leaf $path
        if (-not [string]::IsNullOrWhiteSpace($name)) {
            $names += $name
        }
    }

    $fileCount = 0
    if ($null -ne $manifest.files) {
        $fileCount = @($manifest.files).Count
    }

    $ackLine = "MOONCLIPACK 1 id={0} kind={1} bytes={2} files={3} imported_paths={4}" -f $manifest.id, $manifest.kind, $manifest.bytes, $fileCount, $paths.Count
    $namesForAck = @($names | Select-Object -First 12)
    if ($namesForAck.Count -gt 0) {
        $namesText = [string]::Join([string][char]31, $namesForAck)
        $namesB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($namesText))
        $ackLine = "$ackLine imported_names_b64=$namesB64"
    }

    if (Write-TcpLine $stream $ackLine) {
        Write-AgentLog ("Mac -> Windows TCP ack {0} ({1} imported)" -f $manifest.id, $paths.Count)
    }
}

function Receive-TcpPayloadToFile($stream, $path, [long]$byteCount) {
    Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    $fileStream = [System.IO.File]::Open($path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try {
        $buffer = New-Object byte[] 65536
        $remaining = $byteCount

        while ($remaining -gt 0) {
            $wanted = [Math]::Min($buffer.Length, $remaining)
            $read = $stream.Read($buffer, 0, [int]$wanted)
            if ($read -le 0) {
                throw "payload ended early"
            }
            $fileStream.Write($buffer, 0, $read)
            $remaining -= $read
        }
    } finally {
        $fileStream.Dispose()
    }
}

function Receive-ClipboardTcpPayload($client) {
    $client.NoDelay = $true
    $stream = $client.GetStream()
    $tmpZip = "$macZip.tcp.tmp"

    try {
        $header = Read-TcpLine $stream
        if ($header -notmatch '^MOONCLIP 1 ([0-9]+)$') {
            throw "invalid TCP clipboard header"
        }

        $byteCount = [long]$Matches[1]
        if ($byteCount -gt $maxBytes) {
            throw ("payload too large: {0} > {1}" -f $byteCount, $maxBytes)
        }

        Receive-TcpPayloadToFile $stream $tmpZip $byteCount
        Move-Item -LiteralPath $tmpZip -Destination $macZip -Force

        $macArchiveHash = Get-FileHashString $macZip
        Expand-Payload $macZip $importDir
        $imported = Import-ClipboardPayload $importDir
        if ($null -ne $imported) {
            $normalizedId = Get-ImportedPayloadNormalizedId $imported
            if ([string]::IsNullOrWhiteSpace($normalizedId)) {
                $normalized = Export-ClipboardPayload $normalizedDir
                $normalizedId = if ($null -ne $normalized) { $normalized.id } else { $imported.id }
            }
            $script:lastMacArchiveHash = $macArchiveHash
            $script:lastMacId = $imported.id
            $script:lastWindowsId = $normalizedId
            $script:lastMacFailedArchiveHash = ""
            $script:lastMacFailedArchiveFailures = 0
            Write-MacImportState $imported $macArchiveHash
            Remove-FileIfHashMatches $macZip $macArchiveHash | Out-Null
            Write-MacImportTcpAck $stream $imported
            Write-AgentLog ("Mac -> Windows TCP {0} ({1}B)" -f $imported.kind, $imported.bytes)
        }
    } finally {
        Remove-Item -LiteralPath $tmpZip -Force -ErrorAction SilentlyContinue
        try { $stream.Dispose() } catch {}
    }
}

function Receive-ClipboardTcpClients($listener) {
    if ($null -eq $listener) { return }

    $handled = 0
    while ($listener.Pending()) {
        $client = $null
        try {
            $client = $listener.AcceptTcpClient()
            Receive-ClipboardTcpPayload $client
        } catch {
            if ($_.Exception.Message -notlike "*unexpected eof while reading TCP header*") {
                Write-AgentLog ("Clipboard TCP receive error: {0}" -f $_.Exception.Message)
            }
        } finally {
            if ($null -ne $client) {
                try { $client.Dispose() } catch {}
            }
        }

        $handled++
        if ($handled -ge 8) {
            break
        }
    }
}

function Send-ClipboardTcpPayload($zipPath, $port, [string]$expectedId) {
    if ($port -le 0 -or $port -gt 65535) { return $false }
    if (-not (Test-Path -LiteralPath $zipPath)) { return $false }

    $client = [System.Net.Sockets.TcpClient]::new()
    $connectHandle = $null
    try {
        $client.NoDelay = $true
        $connectHandle = $client.BeginConnect([System.Net.IPAddress]::Loopback, $port, $null, $null)
        if (-not $connectHandle.AsyncWaitHandle.WaitOne(500)) {
            return $false
        }
        $client.EndConnect($connectHandle)

        $stream = $client.GetStream()
        $fileInfo = Get-Item -LiteralPath $zipPath
        $header = [System.Text.Encoding]::UTF8.GetBytes(("MOONCLIP 1 {0}`n" -f $fileInfo.Length))
        $stream.Write($header, 0, $header.Length)

        $fileStream = [System.IO.File]::OpenRead($zipPath)
        try {
            $buffer = New-Object byte[] 65536
            while (($read = $fileStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                $stream.Write($buffer, 0, $read)
            }
        } finally {
            $fileStream.Dispose()
        }

        $stream.Flush()
        $ackLine = Read-OptionalTcpLine $stream 8000
        $ack = Parse-TcpAckLine $ackLine
        if ($null -ne $ack -and $ack["id"] -eq $expectedId) {
            $ackId = $ack["id"]
            $ackImportedPaths = $ack["imported_paths"]
            Write-AgentLog ("Windows -> Mac TCP ack {0} ({1} imported)" -f $ackId, $ackImportedPaths)
            return $true
        }

        if ([string]::IsNullOrWhiteSpace($ackLine)) {
            Write-AgentLog ("Windows -> Mac TCP sent without import ack for {0}; keeping SSH fallback ZIP" -f $expectedId)
        } else {
            Write-AgentLog ("Windows -> Mac TCP unexpected ack '{0}' for {1}; keeping SSH fallback ZIP" -f $ackLine, $expectedId)
        }
        return $false
    } catch {
        Write-AgentLog ("Windows -> Mac TCP send error: {0}" -f $_.Exception.Message)
        return $false
    } finally {
        if ($null -ne $connectHandle) {
            try { $connectHandle.AsyncWaitHandle.Close() } catch {}
        }
        try { $client.Dispose() } catch {}
    }
}

function Get-CapsLockHangulRequestId {
    if (-not (Test-Path -LiteralPath $capsLockHangulRequest)) { return "" }
    try {
        return (Get-Content -LiteralPath $capsLockHangulRequest -Raw -Encoding UTF8).Trim()
    } catch {
        return ""
    }
}

function Invoke-CapsLockHangulRequest($requestId) {
    if ([string]::IsNullOrWhiteSpace($requestId)) { return }
    if (-not $enableCapsLockHangul -or -not $capsLockHangulHookInstalled) { return }

    try {
        $toggleResult = [MoonlightCapsLockHangulHook]::Toggle()
        if ($toggleResult -eq 1) {
            Write-AgentLog "Caps Lock Hangul toggle request virtual-key sent"
        } elseif ($toggleResult -eq 2) {
            Write-AgentLog "Caps Lock Hangul toggle request scan-code fallback sent"
        } else {
            Write-AgentLog "Caps Lock Hangul toggle request IME fallback sent"
        }
    } catch {
        Write-AgentLog ("Caps Lock Hangul toggle request error: {0}" -f $_.Exception.Message)
    }
}

if ($agentLoadOnly) {
    return
}

$lastMacArchiveHash = ""
$lastMacId = ""
$lastWindowsId = ""
$lastMacFailedArchiveHash = ""
$lastMacFailedArchiveFailures = 0
$lastCapsLockHangulRequestId = ""
$lastWindowsExportAt = [DateTime]::MinValue
$maxBytes = Get-PositiveIntSetting $MoonlightClipboardMaxBytes 52428800
$macFallbackMaxFailures = Get-PositiveIntSetting $MoonlightMacFallbackMaxFailures 3
$enableCapsLockHangul = Test-SettingEnabled $MoonlightCapsLockHangul $true
$capsLockHangulTcpPort = Get-IntSetting $MoonlightCapsLockHangulTcpPort 47321
$capsLockHangulHookInstalled = $false
$enableClipboardTcp = Test-SettingEnabled $MoonlightClipboardTcp $true
$clipboardMacToWindowsTcpPort = Get-IntSetting $MoonlightClipboardMacToWindowsTcpPort 47331
$clipboardWindowsToMacTcpPort = Get-IntSetting $MoonlightClipboardWindowsToMacTcpPort 47332
$enableTransferOversizeDirect = Test-SettingEnabled $MoonlightTransferOversizeDirect $true
$transferWindowsDir = Get-ExpandedPathSetting $MoonlightTransferWindowsDir "%USERPROFILE%\Downloads\Moonlight Companion"
$clipboardTcpListener = $null
$loopSleepMs = if ($enableClipboardTcp) { 50 } else { $intervalMs }

Write-AgentLog "started"

try {
    if ($enableClipboardTcp) {
        $clipboardTcpListener = Start-ClipboardTcpListener $clipboardMacToWindowsTcpPort
    } else {
        Write-AgentLog "Clipboard TCP disabled"
    }

    if ($enableCapsLockHangul) {
        $capsLockHangulHookInstalled = Install-CapsLockHangulHook
        if ($capsLockHangulHookInstalled) {
            Write-AgentLog "Caps Lock Hangul toggle enabled"
            if ([MoonlightCapsLockHangulHook]::StartTcpListener($capsLockHangulTcpPort, $logFile)) {
                Write-AgentLog ("Caps Lock Hangul TCP listener enabled on 127.0.0.1:{0}" -f $capsLockHangulTcpPort)
            } else {
                Write-AgentLog ("Caps Lock Hangul TCP listener unavailable on 127.0.0.1:{0}" -f $capsLockHangulTcpPort)
            }
        } else {
            Write-AgentLog "Caps Lock Hangul toggle unavailable"
        }
    } else {
        Write-AgentLog "Caps Lock Hangul toggle disabled"
    }

    $lastCapsLockHangulRequestId = Get-CapsLockHangulRequestId

    while ($true) {
        try {
            if ($enableClipboardTcp -and $null -ne $clipboardTcpListener) {
                Receive-ClipboardTcpClients $clipboardTcpListener
            }

            if ($enableCapsLockHangul -and $capsLockHangulHookInstalled) {
                $capsLockHangulRequestId = Get-CapsLockHangulRequestId
                if (-not [string]::IsNullOrWhiteSpace($capsLockHangulRequestId) -and
                    $capsLockHangulRequestId -ne $lastCapsLockHangulRequestId) {
                    $lastCapsLockHangulRequestId = $capsLockHangulRequestId
                    Invoke-CapsLockHangulRequest $capsLockHangulRequestId
                }
            }

            $now = Get-Date
            if (Test-Path -LiteralPath $macZip) {
                $macArchiveHash = Get-FileHashString $macZip
                if ($macArchiveHash -ne $lastMacArchiveHash) {
                    $imported = $null
                    try {
                        Expand-Payload $macZip $importDir
                        $imported = Import-ClipboardPayload $importDir
                    } catch {
                        if ($macArchiveHash -eq $lastMacFailedArchiveHash) {
                            $lastMacFailedArchiveFailures += 1
                        } else {
                            $lastMacFailedArchiveHash = $macArchiveHash
                            $lastMacFailedArchiveFailures = 1
                        }

                        if ($lastMacFailedArchiveFailures -ge $macFallbackMaxFailures) {
                            if (Remove-FileIfHashMatches $macZip $macArchiveHash) {
                                $lastMacArchiveHash = $macArchiveHash
                                $lastMacFailedArchiveHash = ""
                                $lastMacFailedArchiveFailures = 0
                                Write-AgentLog ("Mac -> Windows fallback import failed {0} times; removed stale fallback ZIP" -f $macFallbackMaxFailures)
                            } else {
                                Write-AgentLog ("Mac -> Windows fallback import failed {0} times; stale fallback ZIP removal deferred" -f $lastMacFailedArchiveFailures)
                            }
                        } else {
                            Write-AgentLog ("Mac -> Windows fallback import failed; will retry ({0}/{1}): {2}" -f $lastMacFailedArchiveFailures, $macFallbackMaxFailures, $_.Exception.Message)
                        }
                    }

                    if ($null -ne $imported) {
                        $normalizedId = Get-ImportedPayloadNormalizedId $imported
                        if ([string]::IsNullOrWhiteSpace($normalizedId)) {
                            $normalized = Export-ClipboardPayload $normalizedDir
                            $normalizedId = if ($null -ne $normalized) { $normalized.id } else { $imported.id }
                        }
                        $lastMacArchiveHash = $macArchiveHash
                        $lastMacId = $imported.id
                        $lastWindowsId = $normalizedId
                        $lastMacFailedArchiveHash = ""
                        $lastMacFailedArchiveFailures = 0
                        Write-MacImportState $imported $macArchiveHash
                        Remove-FileIfHashMatches $macZip $macArchiveHash | Out-Null
                        Write-AgentLog ("Mac -> Windows {0} ({1}B)" -f $imported.kind, $imported.bytes)
                    }
                }
            }

            if (($now - $lastWindowsExportAt).TotalMilliseconds -ge $intervalMs) {
                $lastWindowsExportAt = $now
                $exportDir = New-TemporaryPayloadDirectory $exportRoot
                try {
                    $exported = Export-ClipboardPayload $exportDir
                    if ($null -ne $exported -and $exported.id -ne $lastWindowsId) {
                        if ($exported.id -eq $lastMacId) {
                            $lastWindowsId = $exported.id
                        } elseif ($exported.bytes -gt $maxBytes) {
                            $lastWindowsId = $exported.id
                            if ($enableTransferOversizeDirect -and $exported.kind -eq "files") {
                                Compress-Payload $exportDir $windowsZip $windowsTmpZip
                                Write-AgentLog ("Windows -> Mac oversized files ({0}B); SSH fallback ZIP ready beyond {1}B clipboard limit" -f $exported.bytes, $maxBytes)
                            } else {
                                Write-AgentLog ("skip Windows -> Mac {0} ({1}B); limit is {2}B" -f $exported.kind, $exported.bytes, $maxBytes)
                            }
                        } else {
                            Compress-Payload $exportDir $windowsZip $windowsTmpZip
                            $lastWindowsId = $exported.id
                            if ($enableClipboardTcp -and (Send-ClipboardTcpPayload $windowsZip $clipboardWindowsToMacTcpPort $exported.id)) {
                                Remove-Item -LiteralPath $windowsZip -Force -ErrorAction SilentlyContinue
                                Write-AgentLog ("Windows -> Mac TCP {0} ({1}B)" -f $exported.kind, $exported.bytes)
                            } else {
                                if ($enableClipboardTcp) {
                                    Write-AgentLog ("Windows -> Mac {0} ({1}B); TCP fallback ZIP ready" -f $exported.kind, $exported.bytes)
                                } else {
                                    Write-AgentLog ("Windows -> Mac {0} ({1}B)" -f $exported.kind, $exported.bytes)
                                }
                            }
                        }
                    }
                } finally {
                    Remove-Item -LiteralPath $exportDir -Recurse -Force
                }
                Remove-OldPayloadDirectories $exportRoot
            }
        } catch {
            Write-AgentLog ("error: {0}" -f $_.Exception.Message)
        }

        Start-Sleep -Milliseconds $loopSleepMs
    }
}
finally {
    if ($null -ne $clipboardTcpListener) {
        try { $clipboardTcpListener.Stop() } catch {}
    }
    if ($capsLockHangulHookInstalled) {
        try { [MoonlightCapsLockHangulHook]::Uninstall() } catch {}
    }
    try { $mutex.ReleaseMutex() | Out-Null } catch {}
    $mutex.Dispose()
}
