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
$maxBytes = 52428800
$intervalMs = 700

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

Write-AgentLog "started"

try {
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
    try { $mutex.ReleaseMutex() | Out-Null } catch {}
    $mutex.Dispose()
}
