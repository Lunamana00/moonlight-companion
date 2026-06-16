@echo off
set "SCRIPT=%USERPROFILE%\.moonlight-clipboard-sync\windows-clipboard-agent.ps1"
start "" /min "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -Sta -ExecutionPolicy Bypass -WindowStyle Hidden -File "%SCRIPT%"
