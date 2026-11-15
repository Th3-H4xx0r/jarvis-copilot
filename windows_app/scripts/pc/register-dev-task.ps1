# Creates the \Jarvis\Dev scheduled task: runs ~/jc-dev/dev-run.ps1 in the logged-on user's
# interactive desktop session, not elevated. pc-desktop.sh triggers it with schtasks /Run.
$ErrorActionPreference = 'Stop'
# DOMAIN\user from the token: over SSH $env:USERDOMAIN is WORKGROUP, which Task Scheduler can't map.
$Me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$dev = Join-Path $env:USERPROFILE 'jc-dev'
New-Item -ItemType Directory -Force $dev | Out-Null
Copy-Item -Force (Join-Path $PSScriptRoot 'dev-run.ps1') (Join-Path $dev 'dev-run.ps1')

$user = $Me
# Full path: Task Scheduler keeps the PATH it started with, so a fresh pwsh install isn't on it.
$pwsh = (Get-Command pwsh -ErrorAction Stop).Source
# conhost --headless: no console window at all (-WindowStyle Hidden still flashes one on his screen).
$action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\conhost.exe" `
  -Argument "--headless `"$pwsh`" -NoProfile -File `"$dev\dev-run.ps1`""
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
  -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskPath '\Jarvis\' -TaskName 'Dev' -Action $action -Principal $principal `
  -Settings $settings -Force | Out-Null
Write-Output "registered \Jarvis\Dev for $user"
