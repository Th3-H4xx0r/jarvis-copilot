# ============================================================================
# JarvisCopilot Installer (Windows / PowerShell)
# ============================================================================
# Clones the JarvisCopilot fork, creates a local Python venv, installs JarvisCopilot
# core + voice extras + piper-tts + webui deps, and generates a self-signed
# TLS cert so the voice tab works over LAN.
#
# Usage:
#   irm https://raw.githubusercontent.com/Th3-H4xx0r/jarvis-copilot/main/scripts/install-jarviscopilot.ps1 | iex
#
# Re-running this is SAFE and IDEMPOTENT:
#   - Updates code with `git pull --ff-only` (refuses to discard local commits)
#   - Re-creates the venv ONLY if it's missing
#   - pip install is naturally idempotent — already-installed packages skip
#   - TLS cert is regenerated ONLY if missing or expired
#   - NEVER touches ~/.jarviscopilot/ contents — your config.yaml, SOUL.md, skills/,
#     cron jobs, sessions, auth.json, and credential pool are preserved
# ============================================================================

[CmdletBinding()]
param(
    [string]$Dir    = $env:JARVISCOPILOT_DIR,
    [string]$Branch = 'main',
    [string]$Repo   = 'https://github.com/Th3-H4xx0r/jarvis-copilot.git',
    [switch]$SkipPiper
)

$ErrorActionPreference = 'Stop'

function Info($msg) { Write-Host "[install] $msg" -ForegroundColor Cyan }
function Ok($msg)   { Write-Host "[install] $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "[install] $msg" -ForegroundColor Yellow }
function Die($msg)  { Write-Host "[install] $msg" -ForegroundColor Red; throw $msg }

if (-not $Dir -or [string]::IsNullOrWhiteSpace($Dir)) {
    $Dir = Join-Path $env:USERPROFILE 'JarvisCopilot'
}

# ---- Prerequisites ---------------------------------------------------------
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Die "git is not on PATH. Install Git for Windows (https://git-scm.com/download/win), then re-run."
}

# Find a Python 3.11+ on PATH.
$Py = $null
foreach ($cand in @('python', 'py')) {
    $exe = Get-Command $cand -ErrorAction SilentlyContinue
    if (-not $exe) { continue }
    $args = if ($cand -eq 'py') { @('-3') } else { @() }
    try {
        $verOk = & $exe.Source @args -c "import sys; print(1 if sys.version_info >= (3,11) else 0)"
        if ($verOk -eq '1') {
            $Py = $exe.Source
            $script:PyArgs = $args
            break
        }
    } catch { continue }
}
if (-not $Py) { Die "Python 3.11+ not found on PATH. Install from https://python.org/downloads/, then re-run." }
Info "Using Python: $Py $($script:PyArgs -join ' ')"

# ---- Clone or fast-forward update ------------------------------------------
# git pull --ff-only refuses to merge or rebase, so any local commit on this
# branch is preserved. The script halts (rather than overwriting work) if
# local diverges from origin.
if (Test-Path (Join-Path $Dir '.git')) {
    Info "Updating existing checkout at $Dir ..."
    Push-Location $Dir
    try {
        git fetch origin $Branch --quiet
        $localSha  = (git rev-parse HEAD).Trim()
        $remoteSha = (git rev-parse "origin/$Branch").Trim()
        if ($localSha -eq $remoteSha) {
            Info "Already at $remoteSha -- no code changes."
        }
        else {
            Info "Local:  $localSha"
            Info "Remote: $remoteSha"
            $null = git pull --ff-only origin $Branch
            if ($LASTEXITCODE -ne 0) {
                Die "git pull --ff-only failed. Local commits diverge from origin/$Branch. Resolve manually."
            }
        }
    } finally {
        Pop-Location
    }
}
else {
    Info "Cloning $Repo (branch $Branch) -> $Dir"
    $null = git clone --branch $Branch --single-branch $Repo $Dir
    if ($LASTEXITCODE -ne 0) { Die "git clone failed" }
}

Set-Location $Dir

# ---- Stop any running JarvisCopilot / JarvisCopilot instances ---------------------
# Idempotent best-effort shutdown so pip install can replace files the
# venv's python.exe / pyd modules would otherwise have locked, and so the
# tray relaunch later isn't competing with a previous tray.
Info "Stopping any running JarvisCopilot / JarvisCopilot instances ..."

# Anything bound to 8787 = the webui process. Stop it.
try {
    Get-NetTCPConnection -LocalPort 8787 -State Listen -ErrorAction SilentlyContinue |
        ForEach-Object {
            try { Stop-Process -Id $_.OwningProcess -Force -ErrorAction SilentlyContinue } catch {}
        }
} catch {}

# Python gateway loop (`python -m jarviscopilot_cli.main gateway run ...`).
try {
    Get-CimInstance Win32_Process -Filter "Name = 'python.exe' OR Name = 'pythonw.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -match 'jarviscopilot_cli\.main\s+gateway\s+run' } |
        ForEach-Object {
            try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch {}
        }
} catch {}

# Any other JarvisCopilot python (webui via launch script, ad-hoc runs).
try {
    Get-CimInstance Win32_Process -Filter "Name = 'python.exe' OR Name = 'pythonw.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            $_.CommandLine -and (
                $_.CommandLine -match 'webui\\server\.py' -or
                $_.CommandLine -match 'webui/server\.py' -or
                $_.CommandLine -match 'JarvisCopilot\\\.venv' -or
                $_.CommandLine -match 'JarvisCopilot/\.venv'
            )
        } |
        ForEach-Object {
            try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch {}
        }
} catch {}

# Tray icon (so we can rewrite shortcuts and respawn a fresh one).
try {
    Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe' OR Name = 'pwsh.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -match 'tray-jarviscopilot\.ps1' } |
        ForEach-Object {
            try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch {}
        }
} catch {}

Start-Sleep -Seconds 2

# ---- venv ------------------------------------------------------------------
$VenvDir = Join-Path $Dir '.venv'
$VenvPy  = Join-Path $VenvDir 'Scripts/python.exe'
if (-not (Test-Path $VenvPy)) {
    Info "Creating venv at $VenvDir ..."
    if ($script:PyArgs.Count -gt 0) {
        & $Py @script:PyArgs -m venv $VenvDir
    } else {
        & $Py -m venv $VenvDir
    }
    if ($LASTEXITCODE -ne 0) { Die "venv creation failed" }
}

# ---- Install JarvisCopilot core + voice extras + webui deps -----------------------
# `pip install -e .[all,voice,edge-tts]` is idempotent — pip checks each
# dist's installed version against the requirement and skips if satisfied.
# User state under ~/.jarviscopilot/ is never touched by pip.
# Quiet flags: -q hides "Requirement already satisfied" lines; the progress
# bar still shows on actual downloads. --no-input prevents interactive prompts.
$PipQuiet = @('-q', '--progress-bar', 'off', '--no-input')

Info "Installing core + voice extras (this can take a few minutes on first run) ..."
& $VenvPy -m pip install --upgrade pip @PipQuiet 2>&1 | Out-Null
& $VenvPy -m pip install -e ($Dir + '[all,voice,edge-tts]') @PipQuiet
if ($LASTEXITCODE -ne 0) { Die "pip install failed" }

Info "Installing webui dependencies ..."
& $VenvPy -m pip install -r (Join-Path $Dir 'webui/requirements.txt') @PipQuiet
if ($LASTEXITCODE -ne 0) { Die "webui requirements install failed" }

if (-not $SkipPiper) {
    Info "Installing piper-tts (for JARVIS voice) ..."
    & $VenvPy -m pip install piper-tts @PipQuiet
    if ($LASTEXITCODE -ne 0) { Warn "piper-tts install failed -- JARVIS personality will need a manual 'pip install piper-tts' later." }
}

# Touch the install marker so the launch script skips re-install on next launch.
Set-Content -Path (Join-Path $VenvDir '.webui-installed') -Value (Get-Date).ToString('o')

# ---- Merge shipped personalities into ~/.jarviscopilot/config.yaml ---------------
# Idempotent -- adds entries (e.g. jarvis-mcu) only when missing, never
# overwrites the user's existing personalities or other config keys. Writes a
# timestamped backup before any change.
Info "Merging shipped personalities into ~/.jarviscopilot/config.yaml ..."
& $VenvPy (Join-Path $Dir 'installer/merge-personalities.py')
if ($LASTEXITCODE -ne 0) { Warn "personality merge failed (non-fatal)" }

# ---- TLS cert (idempotent — only generates if missing/expired) -------------
Info "Ensuring self-signed TLS cert for the webui ..."
$certScript = @'
import sys
sys.path.insert(0, 'webui')
try:
    from api.tls import ensure_self_signed_cert, cert_fingerprint_sha256
    cert_path, key_path = ensure_self_signed_cert()
    print(f"  cert: {cert_path}")
    print(f"  key:  {key_path}")
    print(f"  fingerprint: {cert_fingerprint_sha256(cert_path)}")
except Exception as e:
    raise SystemExit(f"cert generation failed: {e}")
'@
& $VenvPy -c $certScript
if ($LASTEXITCODE -ne 0) {
    Warn "TLS cert generation failed; you can still run the webui in HTTP mode."
}

# ---- CLI on PATH ------------------------------------------------------------
# WindowsApps is on every user's PATH by default (it's where MS Store
# installs shims). Dropping a .cmd shim there makes `jarviscopilot` work
# from any shell without env edits or restart.
$LaunchPath = Join-Path $Dir 'scripts/launch-webui.ps1'
$HermesPath = Join-Path $VenvDir 'Scripts/hermes.exe'
$JcPath     = Join-Path $VenvDir 'Scripts/jarviscopilot.exe'
$ShimDir    = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps'
if (-not (Test-Path $ShimDir)) {
    $ShimDir = Join-Path $env:USERPROFILE 'bin'
    New-Item -ItemType Directory -Force -Path $ShimDir | Out-Null
}
foreach ($pair in @(@($JcPath, 'jarviscopilot.cmd'), @($HermesPath, 'jarviscopilot.cmd'))) {
    $target = $pair[0]; $shimName = $pair[1]
    $shim = Join-Path $ShimDir $shimName
    if (Test-Path $target) {
        Set-Content -Path $shim -Value "@echo off`r`n`"$target`" %*" -Encoding ASCII
    }
}
Info "CLI shims placed in $ShimDir (jarviscopilot.cmd, jarviscopilot.cmd)"

# ---- System tray shortcuts + auto-launch -----------------------------------
# Create two shortcuts:
#   * Start Menu  — discoverable, can be pinned to taskbar
#   * Startup folder — boots the tray app on login (auto-starts the WebUI)
# Both point at the same tray script. Idempotent: re-running rewrites them
# to match the current install location.
$TrayPath  = Join-Path $Dir 'scripts/tray-jarviscopilot.ps1'
$StartMenu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\JarvisCopilot.lnk'
$StartupLnk = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup\JarvisCopilot.lnk'

function New-TrayShortcut($Path) {
    $shell = New-Object -ComObject WScript.Shell
    $sc = $shell.CreateShortcut($Path)
    $sc.TargetPath = 'powershell.exe'
    $sc.Arguments  = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$TrayPath`" -RepoDir `"$Dir`""
    $sc.WorkingDirectory = $Dir
    $sc.Description = 'JarvisCopilot system tray'
    $sc.IconLocation = "$env:SystemRoot\System32\shell32.dll,167"  # gold globe-y icon
    $sc.Save()
}
try {
    New-TrayShortcut $StartMenu
    New-TrayShortcut $StartupLnk
    Info "Shortcuts placed at:"
    Info "  $StartMenu"
    Info "  $StartupLnk  (auto-starts on next login)"
} catch {
    Warn "Could not create Start Menu / Startup shortcut: $_"
}

# Launch the tray right now so the user sees it immediately. Tray auto-spawns
# the WebUI on init, so port 8787 should bind within a few seconds.
$LanIp = $null
try {
    $LanIp = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object {
            $_.IPAddress -ne '127.0.0.1' -and
            $_.IPAddress -notlike '169.254.*' -and
            $_.PrefixOrigin -in @('Dhcp', 'Manual')
        } |
        Select-Object -First 1).IPAddress
} catch {}
if (-not $LanIp) { $LanIp = '<your-host-ip>' }

Info "Launching the tray app (it will start the WebUI for you) ..."
$null = Start-Process -WindowStyle Hidden -FilePath 'powershell.exe' `
    -ArgumentList @('-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', $TrayPath, '-RepoDir', $Dir)

Start-Sleep -Seconds 8

$portOpen = $false
try {
    $portOpen = (Test-NetConnection -ComputerName 'localhost' -Port 8787 -InformationLevel Quiet -WarningAction SilentlyContinue)
} catch {}

Ok "JarvisCopilot installed at $Dir"
Write-Host ""
Write-Host "Your existing data in ~/.jarviscopilot/ (config, skills, cron jobs, sessions,"
Write-Host "credentials, memory) was NOT touched by this install."
Write-Host ""
if ($portOpen) {
    Write-Host "WebUI is live:" -ForegroundColor Green
    Write-Host "  Local: https://localhost:8787"
    Write-Host "  LAN:   https://${LanIp}:8787"
    Write-Host ""
    Write-Host "A tray icon is now in your system tray (look for 'JC' on a gold disc)."
    Write-Host "Right-click it for Start / Stop / Restart / Open / Exit."
} else {
    Warn "WebUI didn't bind port 8787 within 8 seconds."
    Write-Host "Open the tray app to see logs:  & '$TrayPath'"
}
Write-Host ""
Write-Host "First-time auth (if you haven't already):" -ForegroundColor Cyan
Write-Host "  jarviscopilot auth add openai-codex --type oauth --no-browser"
Write-Host "  jarviscopilot model openai-codex"
Write-Host ""
Write-Host "Browser will warn about the self-signed cert -- tap Advanced -> Proceed."
Write-Host "Tray will auto-start on your next Windows login."
Write-Host ""
Write-Host "Re-run this installer anytime to update code. Your config and data"
Write-Host "stay put."
