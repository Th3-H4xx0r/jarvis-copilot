# First install on the PC: copies the packaged Jarvis/ to %LOCALAPPDATA%\Programs\Jarvis\app,
# sets the HKCU Run value (open at login) and starts it. Later builds arrive by OTA.
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
Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'Jarvis' -Value "`"$exe`" --startup"
Start-Process $exe
Write-Output "installed $(Get-Content (Join-Path $app 'version.json'))"
