# ============================================================================
# JarvisCopilot Installer (Windows / PowerShell)
# ============================================================================
# Clones the JarvisCopilot fork, creates a local Python venv, installs Hermes
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
#   - NEVER touches ~/.hermes/ contents — your config.yaml, SOUL.md, skills/,
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

# ---- Install Hermes core + voice extras + webui deps -----------------------
# `pip install -e .[all,voice,edge-tts]` is idempotent — pip checks each
# dist's installed version against the requirement and skips if satisfied.
# User state under ~/.hermes/ is never touched by pip.
Info "Installing Hermes core (this may take a few minutes on first run) ..."
& $VenvPy -m pip install --upgrade pip 2>&1 | Out-Null
& $VenvPy -m pip install -e ($Dir + '[all,voice,edge-tts]')
if ($LASTEXITCODE -ne 0) { Die "pip install failed" }

Info "Installing webui dependencies ..."
& $VenvPy -m pip install -r (Join-Path $Dir 'webui/requirements.txt')
if ($LASTEXITCODE -ne 0) { Die "webui requirements install failed" }

if (-not $SkipPiper) {
    Info "Installing piper-tts (for JARVIS voice) ..."
    & $VenvPy -m pip install piper-tts
    if ($LASTEXITCODE -ne 0) { Warn "piper-tts install failed -- JARVIS personality will need a manual 'pip install piper-tts' later." }
}

# Touch the install marker so the launch script skips re-install on next launch.
Set-Content -Path (Join-Path $VenvDir '.webui-installed') -Value (Get-Date).ToString('o')

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

# ---- Next steps -------------------------------------------------------------
$LaunchPath = Join-Path $Dir 'scripts/launch-webui.ps1'
$HermesPath = Join-Path $VenvDir 'Scripts/hermes.exe'

Ok "JarvisCopilot installed at $Dir"
Write-Host ""
Write-Host "Your existing data in ~/.hermes/ (config, skills, cron jobs, sessions,"
Write-Host "credentials, memory) was NOT touched by this install."
Write-Host ""
Write-Host "Next steps:"
Write-Host ""
Write-Host "  1) Authenticate with ChatGPT Codex (one-time, browser device-code flow):"
Write-Host "     & '$HermesPath' auth add openai-codex --type oauth --no-browser"
Write-Host ""
Write-Host "  2) Pick the active model (one-time):"
Write-Host "     & '$HermesPath' model openai-codex"
Write-Host "       (or use any other provider; see hermes model --help)"
Write-Host ""
Write-Host "  3) Launch the webui (binds 0.0.0.0:8787 with HTTPS):"
Write-Host "     & '$LaunchPath'"
Write-Host ""
Write-Host "  4) Open https://localhost:8787 in your browser. Brave/Chrome will warn"
Write-Host "     about the self-signed cert -- tap Advanced -> Proceed once and the"
Write-Host "     mic/voice features will work."
Write-Host ""
Write-Host "Re-run this installer anytime to update code. Your config and data"
Write-Host "stay put."
