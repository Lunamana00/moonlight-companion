Set shell = CreateObject("WScript.Shell")
profile = shell.ExpandEnvironmentStrings("%USERPROFILE%")
powershell = shell.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"
script = profile & "\.moonlight-clipboard-sync\windows-clipboard-agent.ps1"
shell.Run """" & powershell & """ -NoProfile -Sta -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & script & """", 0, False
