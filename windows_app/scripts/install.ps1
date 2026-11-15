# First install on the PC: copies the packaged Jarvis/ to %LOCALAPPDATA%\Programs\Jarvis\app,
# installs it like an app (Start Menu shortcut so Windows search finds it, an entry under
# Settings > Apps with Uninstall, open at login) and starts it. Later builds arrive by OTA.
#   pwsh -File windows_app/scripts/install.ps1 [-Zip windows_app\out\JarvisWin.zip]
param([string]$Zip = (Join-Path (Split-Path -Parent $PSScriptRoot) 'out\JarvisWin.zip'))
$ErrorActionPreference = 'Stop'
$programs = Join-Path $env:LOCALAPPDATA 'Programs\Jarvis'
$app = Join-Path $programs 'app'
$tmp = Join-Path $env:TEMP ("jarvis-install-" + [guid]::NewGuid().ToString('N'))

Get-Process -Name Jarvis -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq (Join-Path $app 'Jarvis.exe') } | Stop-Process -Force
Expand-Archive -Path $Zip -DestinationPath $tmp
New-Item -ItemType Directory -Force $programs | Out-Null
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $app
Move-Item (Join-Path $tmp 'Jarvis') $app
Remove-Item -Recurse -Force $tmp

$exe = Join-Path $app 'Jarvis.exe'
$version = (Get-Content (Join-Path $app 'version.json') | ConvertFrom-Json).version

# Start Menu: what Windows search lists. The old jc-client tray shortcut goes (the app owns it now).
$startMenu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $startMenu 'JarvisCopilot Client.lnk')
$shell = New-Object -ComObject WScript.Shell
$lnk = $shell.CreateShortcut((Join-Path $startMenu 'Jarvis.lnk'))
$lnk.TargetPath = $exe
$lnk.WorkingDirectory = $app
$lnk.IconLocation = "$exe,0"
$lnk.Description = 'Jarvis'
$lnk.Save()

# Settings > Apps > Installed apps (per user, no admin): name, icon, version, Uninstall.
$uninstall = Join-Path $app 'uninstall.ps1'
$key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Jarvis'
New-Item -Path $key -Force | Out-Null
$props = @{
    DisplayName     = 'Jarvis'
    DisplayIcon     = "$exe,0"
    DisplayVersion  = $version
    Publisher       = 'Jarvis'
    InstallLocation = $programs
    UninstallString = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$uninstall`""
}
foreach ($k in $props.Keys) { Set-ItemProperty -Path $key -Name $k -Value $props[$k] }
Set-ItemProperty -Path $key -Name NoModify -Value 1 -Type DWord
Set-ItemProperty -Path $key -Name NoRepair -Value 1 -Type DWord

Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'Jarvis' -Value "`"$exe`" --startup"
Start-Process $exe
Write-Output "installed $(Get-Content (Join-Path $app 'version.json'))"
