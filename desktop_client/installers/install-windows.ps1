# ============================================================================
# JarvisCopilot Desktop Client — Windows installer
# ============================================================================
# Installs the client under %LOCALAPPDATA%\Programs\jc-client, drops a
# jc-client.cmd shim on PATH (WindowsApps), creates Start Menu +
# Startup shortcuts pointing at the tray, then launches the tray which
# kicks off the pairing dialog.
#
# Usage:
#   irm https://raw.githubusercontent.com/Th3-H4xx0r/jarvis-copilot/main/desktop_client/installers/install-windows.ps1 | iex
# ============================================================================
[CmdletBinding()]
param(
    [string]$Dir    = $env:JC_CLIENT_DIR,
    [string]$Branch = 'main',
    [string]$Repo   = 'https://github.com/Th3-H4xx0r/jarvis-copilot.git'
)

$ErrorActionPreference = 'Stop'
function Info($m) { Write-Host "[jc-client install] $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "[jc-client install] $m" -ForegroundColor Green }
function Warn($m) { Write-Host "[jc-client install] $m" -ForegroundColor Yellow }
function Die($m)  { Write-Host "[jc-client install] $m" -ForegroundColor Red; throw $m }

if (-not $Dir -or [string]::IsNullOrWhiteSpace($Dir)) {
    $Dir = Join-Path $env:LOCALAPPDATA 'Programs\jc-client'
}

# --- prereqs ----------------------------------------------------------------
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Die "git is not on PATH. Install Git for Windows (https://git-scm.com/download/win), then re-run."
}
$Py = $null
foreach ($cand in @('python', 'py')) {
    $exe = Get-Command $cand -ErrorAction SilentlyContinue
    if (-not $exe) { continue }
    $args = if ($cand -eq 'py') { @('-3') } else { @() }
    try {
        $ok = & $exe.Source @args -c "import sys; print(1 if sys.version_info >= (3,11) else 0)"
        if ($ok -eq '1') { $Py = $exe.Source; $script:PyArgs = $args; break }
    } catch {}
}
if (-not $Py) { Die "Python 3.11+ required. Install from https://python.org/downloads/, tick 'Add to PATH'." }
Info "Using Python: $Py $($script:PyArgs -join ' ')"

# --- source -----------------------------------------------------------------
$SrcDir = Join-Path $Dir 'src'
if (Test-Path (Join-Path $SrcDir '.git')) {
    Info "Updating $SrcDir (syncing to origin/$Branch)"
    # Hard-sync to origin: this is an auto-managed mirror, so any local drift in
    # the checkout is discarded rather than merged. (A plain `git pull --ff-only`
    # aborts with "local changes would be overwritten" the moment a tracked file
    # differs, which broke re-running the installer.)
    Push-Location $SrcDir
    try {
        git fetch origin $Branch --quiet
        git reset --hard --quiet
        git checkout -q -B $Branch "origin/$Branch"
    } finally { Pop-Location }
} else {
    Info "Cloning $Repo -> $SrcDir"
    New-Item -ItemType Directory -Force -Path $Dir | Out-Null
    git clone --branch $Branch --single-branch $Repo $SrcDir | Out-Null
}

# --- venv -------------------------------------------------------------------
$VenvDir = Join-Path $Dir '.venv'
$VenvPy  = Join-Path $VenvDir 'Scripts\python.exe'
if (-not (Test-Path $VenvPy)) {
    Info "Creating venv"
    if ($script:PyArgs.Count -gt 0) { & $Py @script:PyArgs -m venv $VenvDir }
    else                            { & $Py -m venv $VenvDir }
}
& $VenvPy -m pip install --upgrade pip -q --progress-bar off | Out-Null
Info "Installing jarviscopilot-client ..."
& $VenvPy -m pip install -e (Join-Path $SrcDir 'desktop_client') -q --progress-bar off

# --- PATH shim --------------------------------------------------------------
$JcExe   = Join-Path $VenvDir 'Scripts\jc-client.exe'
$ShimDir = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps'
if (-not (Test-Path $ShimDir)) { $ShimDir = Join-Path $env:USERPROFILE 'bin'; New-Item -ItemType Directory -Force -Path $ShimDir | Out-Null }
$Shim    = Join-Path $ShimDir 'jc-client.cmd'
if (Test-Path $JcExe) {
    Set-Content -Path $Shim -Value "@echo off`r`n`"$JcExe`" %*" -Encoding ASCII
}
Info "CLI shim placed at $Shim"

# --- Start Menu + Startup shortcut → tray ----------------------------------
$Shell      = New-Object -ComObject WScript.Shell
$StartMenu  = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\JarvisCopilot Client.lnk'
$Startup    = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup\JarvisCopilot Client.lnk'
foreach ($Path in @($StartMenu, $Startup)) {
    $Sc = $Shell.CreateShortcut($Path)
    $Sc.TargetPath       = $JcExe
    $Sc.Arguments        = 'tray'
    $Sc.WorkingDirectory = $Dir
    $Sc.Description      = 'JarvisCopilot desktop client (system tray)'
    $Sc.IconLocation     = "$env:SystemRoot\System32\shell32.dll,167"
    $Sc.Save()
}
Info "Shortcuts: $StartMenu / $Startup"

# Launch the tray immediately so the user can pair without opening a shell.
Info "Launching tray ..."
$null = Start-Process -WindowStyle Hidden -FilePath $JcExe -ArgumentList 'tray'

Ok "Installed at $Dir"
Write-Host ""
Write-Host "The tray is now running in your system tray (look for a coloured 'JC' disc)." -ForegroundColor Cyan
Write-Host "If this is the first run, it should have opened a pairing dialog." -ForegroundColor Cyan
Write-Host ""
Write-Host "CLI:"
Write-Host "  jc-client pair               (interactive Tk dialog)"
Write-Host "  jc-client status             (check connection)"
Write-Host "  jc-client logs --follow      (tail log)"
