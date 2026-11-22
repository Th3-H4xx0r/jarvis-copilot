# The Jarvis Glasses camera's admin step, run elevated from Settings > Glasses camera (Face ID on his
# iPhone, then Windows' Yes). Copies the camera into Program Files (where Windows' camera service can
# read it: a folder under his profile gets "access denied"), registers its media source, makes the
# frame file the app and the camera share, and creates the "Jarvis Glasses" virtual camera for good.
# -Remove undoes all of it. What happened goes to %ProgramData%\Jarvis\GlassesCamera\install-result.json
# (Settings reads it: the admin launch doesn't report back).
#   powershell -File glasses-camera.ps1 -From <app>\GlassesCamera [-Remove]
param([string]$From = $PSScriptRoot, [switch]$Remove)
$ErrorActionPreference = 'Stop'
$dest = Join-Path $env:ProgramFiles 'Jarvis\GlassesCamera'
$data = Join-Path $env:ProgramData 'Jarvis\GlassesCamera'
$frames = Join-Path $data 'frames.bin'
$result = Join-Path $data 'install-result.json'
$action = if ($Remove) { 'remove' } else { 'install' }
$frameBytes = 64 + 2 * (32 + 720 * 1280 * 4)   # GlassesCamFrameFile.FileSize
$step = 'copy'

function Finish([bool]$ok, [string]$failedStep = '', $hr = $null, [string]$err = '') {
    New-Item -ItemType Directory -Force $data | Out-Null
    $o = [ordered]@{ ok = $ok; action = $action; step = $failedStep; at = (Get-Date).ToUniversalTime().ToString('o') }
    if ($null -ne $hr) { $o.hr = [int]$hr }
    if ($err) { $o.error = $err }
    [IO.File]::WriteAllText($result, ($o | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
    Write-Output ($o | ConvertTo-Json -Compress)
    if ($ok) { exit 0 } else { exit 1 }
}

# JarvisGlassesCamTool's one JSON line (null when the tool isn't there).
function Tool([string]$verb) {
    $exe = Join-Path $dest 'JarvisGlassesCamTool.exe'
    if (-not (Test-Path $exe)) { return $null }
    $out = (& $exe $verb 2>&1 | Out-String).Trim()
    try { return ($out -split "`n")[-1] | ConvertFrom-Json }
    catch { return [pscustomobject]@{ ok = $false; step = $verb; error = $out } }
}

# Windows' camera service keeps the old copy loaded while it runs: stop it (it starts again on demand).
function Stop-CameraService {
    foreach ($s in 'FrameServer', 'FrameServerMonitor') { Stop-Service -Name $s -Force -ErrorAction SilentlyContinue }
}

function Register([string]$how) {
    $comhost = Join-Path $dest 'JarvisGlassesCam.comhost.dll'
    if (-not (Test-Path $comhost)) { return 0 }
    $argList = if ($how -eq 'u') { @('/u', '/s', "`"$comhost`"") } else { @('/s', "`"$comhost`"") }
    return (Start-Process -FilePath (Join-Path $env:WINDIR 'System32\regsvr32.exe') -ArgumentList $argList -Wait -PassThru).ExitCode
}

try {
    if ($Remove) {
        $step = 'remove'
        $r = Tool 'remove'
        Register 'u' | Out-Null
        Stop-CameraService
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $dest
        Remove-Item -Force -ErrorAction SilentlyContinue $frames
        if ($r -and -not $r.ok) { Finish $false 'remove' $r.hr $r.error }
        Finish $true
    }

    $step = 'copy'
    if (-not (Test-Path (Join-Path $From 'JarvisGlassesCam.comhost.dll'))) { throw "The camera's files aren't in $From." }
    Stop-CameraService
    New-Item -ItemType Directory -Force $dest | Out-Null
    Copy-Item -Path (Join-Path $From '*') -Destination $dest -Recurse -Force

    $step = 'register'
    $code = Register 'r'
    if ($code -ne 0) { Finish $false 'register' $null "regsvr32 exited $code" }

    # The frame file: his account writes the frames (the Jarvis app); the camera service (LOCAL SERVICE)
    # reads them, counts the apps using the camera and keeps a short log; store apps can read too.
    $step = 'frames'
    New-Item -ItemType Directory -Force $data | Out-Null
    $acl = New-Object System.Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    $inherit = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    foreach ($pair in @(@('S-1-5-18', 'FullControl'), @('S-1-5-32-544', 'FullControl'), @('S-1-5-32-545', 'Modify'),
                        @('S-1-5-19', 'Modify'), @('S-1-15-2-1', 'Modify'))) {
        $sid = New-Object System.Security.Principal.SecurityIdentifier($pair[0])
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($sid, $pair[1], $inherit, 'None', 'Allow')))
    }
    Set-Acl -Path $data -AclObject $acl
    if (-not (Test-Path $frames) -or (Get-Item $frames).Length -ne $frameBytes) {
        $fs = [IO.File]::Open($frames, 'Create', 'ReadWrite', 'ReadWrite')
        $fs.SetLength($frameBytes)
        $fs.Close()
    }
    & icacls.exe $frames /reset /q | Out-Null

    $step = 'create'
    $r = Tool 'create'
    if ($null -eq $r) { Finish $false 'create' $null 'JarvisGlassesCamTool.exe is missing' }
    if (-not $r.ok) { Finish $false ([string]$r.step) $r.hr ([string]$r.error) }
    Finish $true
}
catch {
    Finish $false $step $_.Exception.HResult $_.Exception.Message
}
