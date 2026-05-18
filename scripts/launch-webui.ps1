# Launch the JarvisCopilot WebUI bound to 0.0.0.0 so other machines on your network
# can reach it. First run installs JarvisCopilot core + webui dependencies into a
# local .venv at the repo root; later runs are fast (skip the install step).
#
# Usage (PowerShell):
#   .\scripts\launch-webui.ps1                  # default port 8787
#   $env:HERMES_WEBUI_PORT=9001; .\scripts\launch-webui.ps1
#
# Stop the server with Ctrl+C.

$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path "$PSScriptRoot\..").Path
$VenvDir = Join-Path $RepoRoot '.venv'
$VenvPython = Join-Path $VenvDir 'Scripts/python.exe'
$WebuiDir = Join-Path $RepoRoot 'webui'

function Info($msg)  { Write-Host "[launch-webui] $msg" -ForegroundColor Cyan }
function Ok($msg)    { Write-Host "[launch-webui] $msg" -ForegroundColor Green }
function Warn($msg)  { Write-Host "[launch-webui] $msg" -ForegroundColor Yellow }

# ---- venv ------------------------------------------------------------
if (-not (Test-Path $VenvPython)) {
    Info "Creating Python venv at $VenvDir ..."
    python -m venv $VenvDir
    if ($LASTEXITCODE -ne 0) { throw "Failed to create venv. Is Python 3.11+ on PATH?" }
}

# ---- install (idempotent — pip is fast on no-op) ---------------------
# The marker file is touched after a successful install so subsequent runs
# skip the slow pip step. Delete `.venv\.webui-installed` to force a refresh.
#
# `pip install -e <path>[extras]` ALWAYS installs from the local path (the
# leading `-e` and the path argument both force pip to skip PyPI for this
# project — only its transitive deps come from PyPI). We additionally
# verify that jarviscopilot's resolved install location is this repo root
# before launching the server, so a stale PyPI install in this venv (or a
# typo'd path) can't silently take over.
$Marker = Join-Path $VenvDir '.webui-installed'
if (-not (Test-Path $Marker)) {
    Info "Installing JarvisCopilot core from LOCAL path: $RepoRoot"
    Info ('  (pip flag: -e ' + $RepoRoot + '[all,voice,edge-tts] -- editable, no PyPI lookup for jarviscopilot)')
    # [voice] = faster-whisper + sounddevice + numpy (STT)
    # [edge-tts] = Microsoft Edge neural TTS (default JarvisCopilot TTS provider)
    # Both are intentionally excluded from [all] by JarvisCopilot (lazy-install
    # design); the webui needs them up-front so the voice tab works on
    # first boot without a runtime dependency download.
    & $VenvPython -m pip install --upgrade pip 2>&1 | Out-Null
    & $VenvPython -m pip install -e ($RepoRoot + '[all,voice,edge-tts]')
    if ($LASTEXITCODE -ne 0) { throw "Failed to install JarvisCopilot core" }

    Info "Installing webui dependencies ..."
    & $VenvPython -m pip install -r (Join-Path $WebuiDir 'requirements.txt')
    if ($LASTEXITCODE -ne 0) { throw "Failed to install webui requirements" }

    # piper-tts powers the JARVIS personality's neural TTS voice. Pull it in
    # up-front so users picking JARVIS in Settings dont have to wait for a
    # runtime pip install (JarvisCopilot has a lazy-install path but its slow).
    Info "Installing piper-tts (for JARVIS voice) ..."
    & $VenvPython -m pip install piper-tts
    if ($LASTEXITCODE -ne 0) { Warn "piper-tts install failed -- JARVIS voice will require a manual install" }

    Set-Content -Path $Marker -Value (Get-Date).ToString('o')
    Ok "Install complete. Delete $Marker to force a refresh next run."
} else {
    Info "Skipping install (marker present). Delete $Marker to force a refresh."
}

# ---- VERIFY jarviscopilot is the LOCAL editable install --------------
# Run on every launch -- catches the case where the marker exists but the
# venv has somehow ended up with a PyPI-installed jarviscopilot instead.
$ShowOutput = & $VenvPython -m pip show jarviscopilot 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "jarviscopilot is not installed in $VenvDir. Delete $Marker and rerun."
}
# Parse pip-show output line-by-line. The default Select-String behavior on a
# joined multi-line string only anchors at the start of the WHOLE string, so
# the previous one-liner returned null and downstream .Matches.Groups[1].Value
# threw. Splitting first is the boring-but-correct approach.
$ShowLines = (($ShowOutput | Out-String) -split "`r?`n") | ForEach-Object { $_.TrimEnd() }
$ResolvedLocation = ''
$ResolvedEditable = ''
foreach ($line in $ShowLines) {
    if ($line -match '^Editable project location:\s+(.+)$') { $ResolvedEditable = $Matches[1] }
    elseif ($line -match '^Location:\s+(.+)$')              { $ResolvedLocation = $Matches[1] }
}
# Modern pip (>= 21.3) reports "Editable project location" for `-e` installs;
# fall back to Location for older pip versions, where the egg-link points to
# the source dir.
$Resolved = if ($ResolvedEditable) { $ResolvedEditable } else { $ResolvedLocation }
if (-not $Resolved) {
    throw "Could not parse pip show output. Delete $Marker and rerun. Raw:`n$ShowOutput"
}
$ResolvedNorm = (Resolve-Path $Resolved -ErrorAction SilentlyContinue)
if (-not $ResolvedNorm -or $ResolvedNorm.Path -ne (Resolve-Path $RepoRoot).Path) {
    Write-Host ""
    Write-Host "[launch-webui] FATAL: jarviscopilot in the venv is NOT this monorepo." -ForegroundColor Red
    Write-Host "  Expected: $RepoRoot" -ForegroundColor Red
    Write-Host "  Found:    $Resolved" -ForegroundColor Red
    Write-Host "  Delete   $VenvDir   and rerun this script." -ForegroundColor Red
    throw "Refusing to launch with non-local jarviscopilot."
}
Ok "Verified: jarviscopilot resolves to LOCAL path $Resolved"

# ---- TLS cert (self-signed; required so browsers allow getUserMedia) -
# Browsers refuse mic / camera / clipboard / WebRTC on plain HTTP for any
# origin that isn't localhost. We generate a self-signed cert with SANs
# covering all local IPv4 addresses so the voice tab works from a phone or
# any device on the LAN. First boot tap "Advanced -> Proceed" once; the
# cert is stable across restarts.
Info "Ensuring TLS cert in ~/.jarviscopilot/webui-tls/ ..."
$TlsPair = & $VenvPython -c "import sys; sys.path.insert(0, r'$WebuiDir'); from api.tls import ensure_self_signed_cert, cert_fingerprint_sha256; cp, kp = ensure_self_signed_cert(); print(cp); print(kp); print(cert_fingerprint_sha256(cp))"
if ($LASTEXITCODE -ne 0) { throw "Failed to ensure TLS cert" }
$TlsLines = $TlsPair -split "`r?`n" | Where-Object { $_ -ne '' }
$env:HERMES_WEBUI_TLS_CERT = $TlsLines[0]
$env:HERMES_WEBUI_TLS_KEY  = $TlsLines[1]
$TlsFingerprint            = $TlsLines[2]
Ok ("Using cert " + $env:HERMES_WEBUI_TLS_CERT)
Info ("Cert SHA-256: " + $TlsFingerprint)

# ---- port + LAN IP detection -----------------------------------------
$Port = if ($env:HERMES_WEBUI_PORT) { $env:HERMES_WEBUI_PORT } else { '8787' }
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

# ---- env for the server ---------------------------------------------
$env:HERMES_WEBUI_HOST = '0.0.0.0'
$env:HERMES_WEBUI_PORT = $Port
# Pairing-required: every non-public request needs a valid session.
# Devices join by running `jarviscopilot pair` and entering the code.
# Override by setting JARVISCOPILOT_PAIRING_REQUIRED=0 before launch.
if (-not $env:JARVISCOPILOT_PAIRING_REQUIRED) {
    $env:JARVISCOPILOT_PAIRING_REQUIRED = '1'
}
# Tell the webui's voice routes (api/voice.py) and bootstrap discovery
# where to find JarvisCopilot core. The voice module's own _ensure_hermes_on_path()
# adds this too, but setting PYTHONPATH up front avoids relying on import
# order side-effects.
$env:PYTHONPATH = $RepoRoot
$env:HERMES_WEBUI_AGENT_DIR = $RepoRoot

# ---- banner ---------------------------------------------------------
Write-Host ""
Write-Host "================================================================" -ForegroundColor Green
Write-Host " JarvisCopilot WebUI starting on 0.0.0.0:$Port  (TLS)" -ForegroundColor Green
Write-Host " Local:   https://localhost:$Port" -ForegroundColor Green
Write-Host " LAN:     https://${LanIp}:$Port" -ForegroundColor Green
Write-Host "================================================================" -ForegroundColor Green
Write-Host ""
Warn "First connection: browser shows 'Not Private' -- tap Advanced -> Proceed."
Warn "First Python listen on this port may trigger a Windows Firewall prompt."
Warn "Choose 'Allow access' for Private (and Public if you want LAN reach)."
Write-Host ""

# ---- run -----------------------------------------------------------
Set-Location $WebuiDir
& $VenvPython server.py
