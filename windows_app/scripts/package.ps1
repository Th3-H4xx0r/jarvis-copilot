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

@{ version = $Version; build = $build } | ConvertTo-Json -Compress | Set-Content -Encoding utf8NoBOM (Join-Path $stage 'version.json')

$zip = Join-Path $out 'JarvisWin.zip'
Remove-Item -Force -ErrorAction SilentlyContinue $zip
Compress-Archive -Path $stage -DestinationPath $zip
$sha = (Get-FileHash -Algorithm SHA256 $zip).Hash.ToLowerInvariant()
Write-Output "JarvisWin.zip build $build version $Version sha256 $sha"
