# Creates the \Jarvis\Dev scheduled task: runs ~/jc-dev/dev-run.ps1 in the logged-on user's
# interactive desktop session, not elevated. pc-desktop.sh triggers it with schtasks /Run.
$ErrorActionPreference = 'Stop'
$dev = Join-Path $env:USERPROFILE 'jc-dev'
New-Item -ItemType Directory -Force $dev | Out-Null
Copy-Item -Force (Join-Path $PSScriptRoot 'dev-run.ps1') (Join-Path $dev 'dev-run.ps1')

$user = "$env:USERDOMAIN\$env:USERNAME"
$action = New-ScheduledTaskAction -Execute 'pwsh.exe' `
  -Argument "-NoProfile -WindowStyle Hidden -File `"$dev\dev-run.ps1`""
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
  -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskPath '\Jarvis\' -TaskName 'Dev' -Action $action -Principal $principal `
  -Settings $settings -Force | Out-Null
Write-Output "registered \Jarvis\Dev for $user"
