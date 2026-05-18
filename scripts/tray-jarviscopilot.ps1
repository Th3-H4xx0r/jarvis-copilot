# ============================================================================
# JarvisCopilot System Tray (Windows)
# ============================================================================
# Lives in the system tray and controls the WebUI subprocess. Spawns the
# WebUI on launch, exposes Start / Stop / Restart / Open WebUI / View logs /
# Exit via right-click. Closing the WebUI window from the menu also tears
# down the spawned PowerShell host so port 8787 frees up cleanly.
#
# Usage (manual):
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/tray-jarviscopilot.ps1
#
# Auto-start on login: place a shortcut to this file in
#   %APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup
# The installer can do that for you (see install-jarviscopilot.ps1).
# ============================================================================

[CmdletBinding()]
param(
    [string]$RepoDir
)

$ErrorActionPreference = 'Stop'

if (-not $RepoDir -or [string]::IsNullOrWhiteSpace($RepoDir)) {
    # Default: assume the tray script lives in <repo>/scripts/
    $RepoDir = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
}
$LaunchScript = Join-Path $RepoDir 'scripts/launch-webui.ps1'
$LogPath      = Join-Path $env:TEMP 'jarviscopilot-tray.log'

if (-not (Test-Path $LaunchScript)) {
    [System.Windows.Forms.MessageBox]::Show(
        "Launcher not found at:`n$LaunchScript`n`nRun install-jarviscopilot.ps1 first.",
        "JarvisCopilot Tray", 'OK', 'Error') | Out-Null
    exit 1
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# --- Single-instance guard ---------------------------------------------------
# Two trays controlling one WebUI would race on Start/Stop. A named mutex
# fails to acquire if another tray instance is already running.
$mutex = New-Object System.Threading.Mutex($false, 'Global\JarvisCopilotTray')
if (-not $mutex.WaitOne(0, $false)) {
    [System.Windows.Forms.MessageBox]::Show(
        "JarvisCopilot tray is already running. Check your system tray.",
        "JarvisCopilot Tray", 'OK', 'Information') | Out-Null
    exit 0
}

# --- State ------------------------------------------------------------------
$script:WebProc = $null

function Get-PortBound {
    try {
        $bound = Get-NetTCPConnection -LocalPort 8787 -ErrorAction SilentlyContinue
        return ($null -ne $bound -and $bound.Count -gt 0)
    } catch { return $false }
}

function Write-TrayLog {
    param([string]$Msg)
    "$([DateTime]::Now.ToString('s'))  $Msg" | Out-File -FilePath $LogPath -Append -Encoding UTF8
}

function Start-WebUI {
    if ($script:WebProc -and -not $script:WebProc.HasExited) {
        Write-TrayLog "Start ignored: WebUI process still alive (PID $($script:WebProc.Id))"
        return
    }
    if (Get-PortBound) {
        Write-TrayLog "Start ignored: port 8787 already bound by another process"
        return
    }
    Write-TrayLog "Spawning WebUI ..."
    $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $LaunchScript)
    # WindowStyle Hidden = no flash of console; logs go to journalctl-style
    # output via the spawned PowerShell which the launcher already prints.
    # If you want to see the console output, change Hidden -> Normal here.
    $script:WebProc = Start-Process -PassThru -WindowStyle Hidden `
        -FilePath 'powershell.exe' -ArgumentList $args
    Write-TrayLog "Spawned PID $($script:WebProc.Id)"
}

function Stop-WebUI {
    Write-TrayLog "Stop requested"
    # Kill the host we spawned (if still alive)
    if ($script:WebProc -and -not $script:WebProc.HasExited) {
        try { Stop-Process -Id $script:WebProc.Id -Force -ErrorAction SilentlyContinue } catch {}
    }
    # Also kill any orphaned process still holding port 8787 — happens if the
    # tray was killed mid-session and a previous WebUI is still up.
    try {
        Get-NetTCPConnection -LocalPort 8787 -ErrorAction SilentlyContinue |
            ForEach-Object {
                try { Stop-Process -Id $_.OwningProcess -Force -ErrorAction SilentlyContinue } catch {}
            }
    } catch {}
    $script:WebProc = $null
    Start-Sleep -Milliseconds 500
    Write-TrayLog "Stop complete"
}

function Restart-WebUI {
    Write-TrayLog "Restart requested"
    Stop-WebUI
    Start-Sleep -Milliseconds 800
    Start-WebUI
}

function Open-WebUIBrowser {
    Start-Process "https://localhost:8787"
}

function Open-LogTail {
    # Tail the launcher log if it exists; otherwise show our own tray log.
    $candidates = @($LogPath)
    $best = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($best) { Start-Process notepad.exe $best } else {
        [System.Windows.Forms.MessageBox]::Show("No log file yet.", "JarvisCopilot Tray", 'OK', 'Information') | Out-Null
    }
}

# --- Icon (built-in app icon, recolored to a JC gold) -----------------------
# We avoid shipping a separate .ico file by drawing a 32x32 bitmap with the
# letters "JC" on a gold disc. Crisp enough for the tray at 16x16 / 24x24.
function New-TrayIcon {
    $bmp = New-Object System.Drawing.Bitmap 32, 32
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.TextRenderingHint = 'AntiAlias'
    $g.Clear([System.Drawing.Color]::Transparent)
    # Gold disc
    $brush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 245, 197, 66))
    $g.FillEllipse($brush, 1, 1, 30, 30)
    $brush.Dispose()
    # Bronze ring
    $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(255, 205, 127, 50)), 2
    $g.DrawEllipse($pen, 2, 2, 28, 28)
    $pen.Dispose()
    # "JC"
    $font = New-Object System.Drawing.Font 'Segoe UI', 13, ([System.Drawing.FontStyle]::Bold)
    $text = "JC"
    $size = $g.MeasureString($text, $font)
    $tb = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 40, 30, 10))
    $g.DrawString($text, $font, $tb, (32 - $size.Width) / 2, (32 - $size.Height) / 2)
    $tb.Dispose(); $font.Dispose(); $g.Dispose()
    $hIcon = $bmp.GetHicon()
    $icon = [System.Drawing.Icon]::FromHandle($hIcon)
    return $icon
}

# --- Tray + menu ------------------------------------------------------------
$ni = New-Object System.Windows.Forms.NotifyIcon
$ni.Icon = New-TrayIcon
$ni.Visible = $true
$ni.Text = 'JarvisCopilot'

$menu = New-Object System.Windows.Forms.ContextMenuStrip
function _addItem($text, $handler) {
    $item = New-Object System.Windows.Forms.ToolStripMenuItem $text
    $item.Add_Click($handler)
    $menu.Items.Add($item) | Out-Null
    return $item
}

$openItem    = _addItem 'Open WebUI (https://localhost:8787)' { Open-WebUIBrowser }
$null = $menu.Items.Add('-')
$startItem   = _addItem 'Start WebUI'   { Start-WebUI }
$stopItem    = _addItem 'Stop WebUI'    { Stop-WebUI }
$restartItem = _addItem 'Restart WebUI' { Restart-WebUI }
$null = $menu.Items.Add('-')
$logsItem    = _addItem 'View tray logs' { Open-LogTail }
$null = $menu.Items.Add('-')
$exitItem    = _addItem 'Exit (stops WebUI)' {
    Stop-WebUI
    $ni.Visible = $false
    $ni.Dispose()
    [System.Windows.Forms.Application]::Exit()
}

$ni.ContextMenuStrip = $menu

# Double-click on the tray icon opens the WebUI in the default browser.
$ni.Add_DoubleClick({ Open-WebUIBrowser })

# --- Health-tooltip updater -------------------------------------------------
# Polls every 4s, updates the tooltip + enables/disables menu items based on
# whether the WebUI is currently bound to port 8787. Cheap (one Get-Net call)
# and matches what the user would check manually.
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 4000
$timer.Add_Tick({
    $running = Get-PortBound
    if ($running) {
        $ni.Text = 'JarvisCopilot — running on :8787'
        $startItem.Enabled = $false
        $stopItem.Enabled = $true
        $restartItem.Enabled = $true
    } else {
        $ni.Text = 'JarvisCopilot — stopped'
        $startItem.Enabled = $true
        $stopItem.Enabled = $false
        $restartItem.Enabled = $false
    }
})
$timer.Start()

Write-TrayLog "Tray started"

# --- Auto-start the WebUI ---------------------------------------------------
Start-WebUI

# --- WinForms message loop --------------------------------------------------
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::Run()

# Cleanup if the loop ever exits without our Exit handler firing.
try { $ni.Visible = $false; $ni.Dispose() } catch {}
try { $timer.Stop(); $timer.Dispose() } catch {}
try { $mutex.ReleaseMutex(); $mutex.Dispose() } catch {}
