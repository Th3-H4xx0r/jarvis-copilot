# Uninstall Jarvis (Settings > Apps > Jarvis > Uninstall runs this from the app folder): quits the
# app, stops jc-client and removes its task, then removes the app, shortcuts and registry entries.
# jc-client's own files (%LOCALAPPDATA%\Programs\jc-client) and its pairing are left in place.
$ErrorActionPreference = 'Continue'
$programs = Join-Path $env:LOCALAPPDATA 'Programs\Jarvis'

Get-Process -Name Jarvis, JarvisUpdater -ErrorAction SilentlyContinue | Stop-Process -Force
$jc = Join-Path $env:LOCALAPPDATA 'Programs\jc-client\.venv\Scripts\jc-client.exe'
if (Test-Path $jc) { & $jc stop 2>$null | Out-Null }
Unregister-ScheduledTask -TaskPath '\JarvisCopilot\' -TaskName 'jc-client' -Confirm:$false -ErrorAction SilentlyContinue

Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Jarvis.lnk')
Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'Jarvis' -ErrorAction SilentlyContinue
Remove-Item -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Jarvis' -Recurse -Force -ErrorAction SilentlyContinue

# This script lives inside the folder it removes: finish from cmd once this process has exited.
Start-Process cmd.exe -WindowStyle Hidden -ArgumentList "/c timeout /t 2 /nobreak >nul & rmdir /s /q `"$programs`""
