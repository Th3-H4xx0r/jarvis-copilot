# Builds JarvisWin.zip (C5): root Jarvis/ with Jarvis.exe, JarvisUpdater.exe and version.json.
#   pwsh -File windows_app/scripts/package.ps1 [-Version 1.0.0]
param([string]$Version = '1.0.0')
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$out = Join-Path $root 'out'
$stage = Join-Path $out 'package\Jarvis'
$now = (Get-Date).ToUniversalTime()
$build = [long]('{0:yy}{1:000}{0:HHmm}' -f $now, $now.DayOfYear)

Remove-Item -Recurse -Force -ErrorAction SilentlyContinue (Join-Path $out 'package')
New-Item -ItemType Directory -Force $stage | Out-Null

dotnet publish (Join-Path $root 'Jarvis\Jarvis.csproj') -c Release -r win-x64 --self-contained true -o $stage --nologo
if ($LASTEXITCODE -ne 0) { throw 'Jarvis publish failed' }
$upd = Join-Path $out 'package\updater'
dotnet publish (Join-Path $root 'JarvisUpdater\JarvisUpdater.csproj') -c Release -r win-x64 --self-contained true `
  -p:PublishSingleFile=true -o $upd --nologo
if ($LASTEXITCODE -ne 0) { throw 'JarvisUpdater publish failed' }
Copy-Item -Force (Join-Path $upd 'JarvisUpdater.exe') $stage
# The PC-unlock helper (installed as a service from Settings with Face ID + UAC).
$unl = Join-Path $out 'package\unlock'
dotnet publish (Join-Path $root 'JarvisUnlock\JarvisUnlock.csproj') -c Release -r win-x64 --self-contained true `
  -p:PublishSingleFile=true -o $unl --nologo
if ($LASTEXITCODE -ne 0) { throw 'JarvisUnlock publish failed' }
Copy-Item -Force (Join-Path $unl 'JarvisUnlock.exe') $stage
# The PC Stats sensor helper (a service, installed from Settings with Face ID + UAC). Not trimmed:
# LibreHardwareMonitor and TraceEvent use reflection.
$sen = Join-Path $out 'package\sensors'
dotnet publish (Join-Path $root 'JarvisSensors\JarvisSensors.csproj') -c Release -r win-x64 --self-contained true `
  -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -o $sen --nologo
if ($LASTEXITCODE -ne 0) { throw 'JarvisSensors publish failed' }
Copy-Item -Force (Join-Path $sen 'JarvisSensors.exe') $stage
# The Jarvis Glasses camera (Settings > Glasses camera copies it to Program Files with Face ID + UAC):
# its media source (a COM server Windows' camera service loads), the setup tool and the admin script.
# Framework-dependent: they run on the machine-wide .NET 8 runtime, as the camera service must.
$cam = Join-Path $stage 'GlassesCamera'
dotnet publish (Join-Path $root 'JarvisGlassesCam\JarvisGlassesCam.csproj') -c Release -r win-x64 --self-contained false -o $cam --nologo
if ($LASTEXITCODE -ne 0) { throw 'JarvisGlassesCam publish failed' }
dotnet publish (Join-Path $root 'JarvisGlassesCamTool\JarvisGlassesCamTool.csproj') -c Release -r win-x64 --self-contained false -o $cam --nologo
if ($LASTEXITCODE -ne 0) { throw 'JarvisGlassesCamTool publish failed' }
Copy-Item -Force (Join-Path $PSScriptRoot 'glasses-camera.ps1') $cam
Copy-Item -Force (Join-Path $root 'THIRD_PARTY_NOTICES.md') $cam
Get-ChildItem $cam -Filter *.pdb | Remove-Item -Force
Copy-Item -Force (Join-Path $PSScriptRoot 'uninstall.ps1') $stage   # Settings > Apps > Uninstall runs it

@{ version = $Version; build = $build } | ConvertTo-Json -Compress | Set-Content -Encoding utf8NoBOM (Join-Path $stage 'version.json')

$zip = Join-Path $out 'JarvisWin.zip'
Remove-Item -Force -ErrorAction SilentlyContinue $zip
Compress-Archive -Path $stage -DestinationPath $zip
$sha = (Get-FileHash -Algorithm SHA256 $zip).Hash.ToLowerInvariant()
Write-Output "JarvisWin.zip build $build version $Version sha256 $sha"
