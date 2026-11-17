# ============================================================================
# JarvisCopilot Desktop Client - Windows installer
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
    [string]$Repo   = 'https://github.com/Th3-H4xx0r/jarvis-copilot.git',
    # scripts/windows/setup-pc.ps1: the Mac pairs headlessly over SSH, so no tray/pairing dialog
    [switch]$NoTray
)

$ErrorActionPreference = 'Stop'
# DOMAIN\user from the token: over SSH $env:USERDOMAIN is WORKGROUP, which Task Scheduler can't map.
$Me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
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

# --- Mutagen sync engine (coding-session file sync) -------------------------
# Best-effort: a network hiccup must not fail the install - `jc-client update`
# and the first sync both re-attempt it.
Info "Installing Mutagen sync engine (for coding-session file sync) ..."
$JcExeEarly = Join-Path $VenvDir 'Scripts\jc-client.exe'
try { & $JcExeEarly install-mutagen } catch {
    Warn "Mutagen not installed (no network?) - run 'jc-client install-mutagen' later; coding-session sync needs it."
}
Info "Installing agent-desktop (the accessibility engine for computer control) ..."
try { & $JcExeEarly install-agent-desktop } catch {
    Warn "agent-desktop not installed (no network?) - computer control keeps its built-in engine; run 'jc-client install-agent-desktop' later."
}

# --- PATH shim --------------------------------------------------------------
$JcExe   = Join-Path $VenvDir 'Scripts\jc-client.exe'
$ShimDir = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps'
if (-not (Test-Path $ShimDir)) { $ShimDir = Join-Path $env:USERPROFILE 'bin'; New-Item -ItemType Directory -Force -Path $ShimDir | Out-Null }
$Shim    = Join-Path $ShimDir 'jc-client.cmd'
if (Test-Path $JcExe) {
    Set-Content -Path $Shim -Value "@echo off`r`n`"$JcExe`" %*" -Encoding ASCII
}
Info "CLI shim placed at $Shim"

# --- Start Menu shortcut -> tray (the Jarvis Windows app replaces it once installed) ---
$Shell      = New-Object -ComObject WScript.Shell
$StartMenu  = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\JarvisCopilot Client.lnk'
$Sc = $Shell.CreateShortcut($StartMenu)
$Sc.TargetPath       = $JcExe
$Sc.Arguments        = 'tray'
$Sc.WorkingDirectory = $Dir
$Sc.Description      = 'JarvisCopilot desktop client (system tray)'
$Sc.IconLocation     = "$env:SystemRoot\System32\shell32.dll,167"
$Sc.Save()
Info "Shortcut: $StartMenu"

# --- Supervision: a per-user scheduled task, at logon, restarted on crash -----
# (a Startup shortcut never restarts a crashed client; `jc-client start/stop/restart`
# drive this task, cli.py _SCHTASK). The old Startup shortcut is removed.
$OldStartup = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup\JarvisCopilot Client.lnk'
if (Test-Path $OldStartup) { Remove-Item $OldStartup -Force }
# conhost --headless: no console window, for jc-client or anything it runs (the Jarvis app
# starts / restarts / stops this task; JcClientControl).
$Action   = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\conhost.exe" `
    -Argument "--headless `"$JcExe`" start --no-tray" -WorkingDirectory $Dir
$Trigger  = New-ScheduledTaskTrigger -AtLogOn -User $Me
# Every 5 minutes "start it if it isn't running" (IgnoreNew below): Task Scheduler's own restart
# covers a task that fails to start, not a client that crashes later.
$Watch    = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 5)
$Settings = New-ScheduledTaskSettingsSet -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit (New-TimeSpan -Seconds 0) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -MultipleInstances IgnoreNew
$Principal = New-ScheduledTaskPrincipal -UserId $Me -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskPath '\JarvisCopilot\' -TaskName 'jc-client' -Action $Action -Trigger @($Trigger, $Watch) `
    -Settings $Settings -Principal $Principal -Force | Out-Null
Info "Scheduled task \JarvisCopilot\jc-client registered (logon + restart on crash)"

# Paired already: the task runs the service now, and the tray (started after its pid file
# exists) only shows it - never a second service. Not paired: the tray's pairing dialog runs
# the service itself this time; the task takes over from the next logon.
# 'Continue' locally: jc-client logs to stderr, and in Windows PowerShell 5.1 a redirected
# program's stderr throws under 'Stop'.
$Paired = & { $ErrorActionPreference = 'Continue'; (& $JcExe status 2>$null | Select-String -Pattern 'paired:\s+yes' -Quiet) }
if ($Paired) {
    Start-ScheduledTask -TaskPath '\JarvisCopilot\' -TaskName 'jc-client'
    $PidFile = Join-Path $env:USERPROFILE '.jarviscopilot-client\jc-client.pid'
    for ($i = 0; $i -lt 30 -and -not (Test-Path $PidFile); $i++) { Start-Sleep -Milliseconds 500 }
} else {
    Disable-ScheduledTask -TaskPath '\JarvisCopilot\' -TaskName 'jc-client' | Out-Null
    if (-not $NoTray) { Info "Pair in the dialog; the client starts at your next sign-in (or run: jc-client start)" }
}
if (-not $NoTray) {
    Info "Launching tray ..."
    $null = Start-Process -WindowStyle Hidden -FilePath $JcExe -ArgumentList 'tray'
}

Ok "Installed at $Dir"
Write-Host ""
Write-Host "The tray is now running in your system tray (look for a coloured 'JC' disc)." -ForegroundColor Cyan
Write-Host "If this is the first run, it should have opened a pairing dialog." -ForegroundColor Cyan
Write-Host ""
Write-Host "CLI:"
Write-Host "  jc-client pair               (interactive Tk dialog)"
Write-Host "  jc-client status             (check connection)"
Write-Host "  jc-client logs --follow      (tail log)"
