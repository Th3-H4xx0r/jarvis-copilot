# ============================================================================
# Jarvis: one-time setup for the gaming PC (Windows 11)
# ============================================================================
# Open a normal PowerShell window (not "Run as administrator") and paste:
#
#   irm https://raw.githubusercontent.com/Th3-H4xx0r/jarvis-copilot/main/scripts/windows/setup-pc.ps1 | iex
#
# Click "Yes" on the one Windows admin prompt. Safe to run again.
#
# It does everything the Mac needs to take over from here:
#   admin part (one UAC prompt): Git, Python 3.12, .NET 8 SDK, PowerShell 7 and Node LTS
#     via winget; the OpenSSH server with the Mac's key, PowerShell as its shell and the
#     firewall limited to the tailnet and home network; wake-on-magic-packet on the network
#     adapters; Tailscale kept connected before sign-in.
#   your part (not elevated): jc-client installed and supervised by Task Scheduler, a dev
#     checkout at ~\src\jarvis-copilot with a test venv, the \Jarvis\Dev desktop task, and
#     the Jarvis app built and installed.
# Pairing jc-client is left to the Mac (headless, over SSH), so no dialog needs you.
# Logs and a summary land in ~\jarvis-setup\.
# ============================================================================
param([ValidateSet('', 'admin', 'user')][string]$Part = '')

$ErrorActionPreference = 'Stop'
$ScriptUrl = 'https://raw.githubusercontent.com/Th3-H4xx0r/jarvis-copilot/main/scripts/windows/setup-pc.ps1'
$Repo      = 'https://github.com/Th3-H4xx0r/jarvis-copilot.git'
$MacKey    = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAbJ0qWmBiRelN9T+C6N30lQPrgmzXHn7tntFkUzHSdO jarvis-mac-to-pc'
$LogDir    = Join-Path $env:USERPROFILE 'jarvis-setup'
$Clone     = Join-Path $env:USERPROFILE 'src\jarvis-copilot'
New-Item -ItemType Directory -Force $LogDir | Out-Null

function Info($m) { Write-Host "[jarvis setup] $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "[jarvis setup] $m" -ForegroundColor Green }
function Warn($m) { Write-Host "[jarvis setup] $m" -ForegroundColor Yellow }

# Each step runs on its own: one failure is logged and the rest still run.
$script:Results = @()
function Step([string]$name, [scriptblock]$body) {
    Info $name
    try {
        & $body
        $script:Results += "ok    $name"
        Ok "  done"
    } catch {
        $script:Results += "FAIL  $name : $($_.Exception.Message)"
        Warn "  failed: $($_.Exception.Message)"
    }
}
function Refresh-Path {
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
                [Environment]::GetEnvironmentVariable('Path', 'User')
}
function Is-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Run([string]$exe, [string[]]$argv) {
    & $exe @argv
    if ($LASTEXITCODE -ne 0) { throw "$exe exited $LASTEXITCODE" }
}

# ---------------------------------------------------------------------------
# admin part (elevated)
# ---------------------------------------------------------------------------
function Admin-Part {
    Start-Transcript -Path (Join-Path $LogDir 'admin.log') -Force | Out-Null

    foreach ($id in @('Git.Git', 'Python.Python.3.12', 'Microsoft.DotNet.SDK.8',
                      'Microsoft.PowerShell', 'OpenJS.NodeJS.LTS')) {
        Step "winget: $id" {
            winget list --id $id -e --accept-source-agreements --disable-interactivity | Out-Null
            if ($LASTEXITCODE -eq 0) { Info "  already installed"; return }
            Run winget @('install', '--id', $id, '-e', '--scope', 'machine', '--silent',
                         '--accept-source-agreements', '--accept-package-agreements', '--disable-interactivity')
        }
    }

    Step 'OpenSSH server on, starts with Windows' {
        $cap = Get-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0'
        if ($cap.State -ne 'Installed') { Add-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0' | Out-Null }
        Set-Service -Name sshd -StartupType Automatic
        Start-Service sshd
    }

    Step "The Mac's SSH key" {
        # Admin accounts: sshd reads only administrators_authorized_keys (and refuses it unless
        # only Administrators and SYSTEM can write it). The per-user file covers a standard account.
        $adminKeys = Join-Path $env:ProgramData 'ssh\administrators_authorized_keys'
        $userKeys  = Join-Path $env:USERPROFILE '.ssh\authorized_keys'
        New-Item -ItemType Directory -Force (Split-Path $userKeys) | Out-Null
        foreach ($f in @($adminKeys, $userKeys)) {
            $have = (Test-Path $f) -and (Select-String -Path $f -SimpleMatch $MacKey -Quiet)
            if (-not $have) { Add-Content -Path $f -Value $MacKey -Encoding ascii }
        }
        Run icacls @($adminKeys, '/inheritance:r', '/grant', 'Administrators:F', '/grant', 'SYSTEM:F')
    }

    Step 'PowerShell as the SSH shell' {
        New-Item -Path 'HKLM:\SOFTWARE\OpenSSH' -Force | Out-Null
        New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell -PropertyType String -Force `
            -Value "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" | Out-Null
        Restart-Service sshd
    }

    Step 'Firewall: SSH only from the tailnet and home network' {
        $rules = Get-NetFirewallRule -Name '*OpenSSH*' -ErrorAction SilentlyContinue
        if (-not $rules) {
            New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' -Enabled True `
                -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
            $rules = Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP'
        }
        # Profile Any: Windows often calls the Wi-Fi and the Tailscale adapter "Public", and the
        # built-in rule covers only Private; the address limit is what keeps it off the internet.
        $rules | Set-NetFirewallRule -Enabled True -Profile Any -RemoteAddress @('100.64.0.0/10', 'LocalSubnet')
    }

    Step 'Wake on magic packet (Wi-Fi and Ethernet)' {
        # Best effort per adapter: many Wi-Fi cards wake only from sleep, never from shut down.
        $adapters = Get-NetAdapter -Physical | Where-Object { $_.Status -ne 'Disabled' }
        foreach ($a in $adapters) {
            try {
                Set-NetAdapterPowerManagement -Name $a.Name -WakeOnMagicPacket Enabled -ErrorAction Stop
                Info "  $($a.Name): wake on magic packet enabled"
            } catch { Warn "  $($a.Name): no wake on magic packet ($($_.Exception.Message))" }
            # 'Continue' locally: in Windows PowerShell 5.1 a 2>$null on a program throws under 'Stop'.
            & { $ErrorActionPreference = 'Continue'; powercfg /deviceenablewake $a.InterfaceDescription 2>$null | Out-Null }
        }
    }

    Step 'Tailscale stays connected before sign-in' {
        $ts = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'
        if (-not (Test-Path $ts)) { throw 'Tailscale not found' }
        Run $ts @('set', '--unattended=true')
    }

    $script:Results | Set-Content -Path (Join-Path $LogDir 'admin-results.txt') -Encoding utf8
    Stop-Transcript | Out-Null
}

# ---------------------------------------------------------------------------
# your part (not elevated: the client, its tray and the app must not run as admin)
# ---------------------------------------------------------------------------
function User-Part {
    Start-Transcript -Path (Join-Path $LogDir 'user.log') -Force | Out-Null
    Refresh-Path

    Step 'Dev checkout at ~\src\jarvis-copilot' {
        if (Test-Path (Join-Path $Clone '.git')) {
            Push-Location $Clone
            try { Run git @('pull', '-q', '--ff-only') } finally { Pop-Location }
        } else {
            New-Item -ItemType Directory -Force (Split-Path $Clone) | Out-Null
            Run git @('clone', '-q', $Repo, $Clone)
        }
    }

    Step 'jc-client installed (Task Scheduler supervises it)' {
        $installer = Join-Path $Clone 'desktop_client\installers\install-windows.ps1'
        Run powershell.exe @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $installer, '-NoTray')
    }

    Step 'Test venv for jc-client (~\src\jarvis-copilot\.venv-win)' {
        $venv = Join-Path $Clone '.venv-win'
        if (-not (Test-Path (Join-Path $venv 'Scripts\python.exe'))) { Run py @('-3.12', '-m', 'venv', $venv) }
        $py = Join-Path $venv 'Scripts\python.exe'
        Run $py @('-m', 'pip', 'install', '-q', '--upgrade', 'pip')
        Run $py @('-m', 'pip', 'install', '-q', '-e', (Join-Path $Clone 'desktop_client'), 'pytest')
    }

    Step 'Desktop task for the Mac (\Jarvis\Dev)' {
        Run pwsh @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $Clone 'windows_app\scripts\pc\register-dev-task.ps1'))
    }

    Step 'Jarvis app built and installed' {
        Run pwsh @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $Clone 'windows_app\scripts\package.ps1'))
        Run pwsh @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $Clone 'windows_app\scripts\install.ps1'))
    }

    $script:Results | Set-Content -Path (Join-Path $LogDir 'user-results.txt') -Encoding utf8
    Stop-Transcript | Out-Null
}

# ---------------------------------------------------------------------------
# entry: get a copy on disk, run the admin part elevated, then your part not elevated
# ---------------------------------------------------------------------------
if ($Part -eq 'admin') { Admin-Part; return }
if ($Part -eq 'user')  { User-Part;  return }

$Self = $PSCommandPath
if (-not $Self) {
    # Pasted through `irm | iex`: there is no file yet; the elevated part needs one.
    $Self = Join-Path $LogDir 'setup-pc.ps1'
    Invoke-RestMethod $ScriptUrl -OutFile $Self
}
$PsArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$Self`"")

if (Is-Admin) {
    # Opened as administrator anyway: do the admin part here, and run your part through a
    # one-off scheduled task at the normal (limited) level, in this desktop session.
    Admin-Part
    $task = 'SetupUserPart'
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument (($PsArgs + @('-Part', 'user')) -join ' ')
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskPath '\Jarvis\' -TaskName $task -Action $action -Principal $principal -Force | Out-Null
    Start-ScheduledTask -TaskPath '\Jarvis\' -TaskName $task
    Info 'Your part is running in its own window (not as admin) ...'
    Start-Sleep -Seconds 3
    while ((Get-ScheduledTask -TaskPath '\Jarvis\' -TaskName $task).State -eq 'Running') { Start-Sleep -Seconds 5 }
    Unregister-ScheduledTask -TaskPath '\Jarvis\' -TaskName $task -Confirm:$false
} else {
    Info 'Asking Windows for admin rights once (click Yes) ...'
    try {
        Start-Process powershell.exe -Verb RunAs -Wait -ArgumentList (($PsArgs + @('-Part', 'admin')) -join ' ')
    } catch {
        Warn 'The admin prompt was declined; SSH and the installs need it. Run this again and click Yes.'
        return
    }
    User-Part
}

# ---------------------------------------------------------------------------
# summary (also left in ~\jarvis-setup\summary.txt for the Mac to read)
# ---------------------------------------------------------------------------
$ip = try { & { $ErrorActionPreference = 'Continue'
                 & (Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe') ip -4 2>$null | Select-Object -First 1 } } catch { '' }
$summary = @(
    "Jarvis PC setup  $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
    "Windows user:    $env:USERNAME"
    "Computer:        $env:COMPUTERNAME"
    "Tailscale IP:    $ip"
    ''
) + (Get-Content (Join-Path $LogDir 'admin-results.txt') -ErrorAction SilentlyContinue) `
  + (Get-Content (Join-Path $LogDir 'user-results.txt') -ErrorAction SilentlyContinue)
$summary | Set-Content -Path (Join-Path $LogDir 'summary.txt') -Encoding utf8
Write-Host ''
$summary | ForEach-Object { if ($_ -like 'FAIL*') { Warn $_ } else { Write-Host $_ } }
Write-Host ''
Ok "All set. Leave the PC on and signed in; the Mac takes it from here."
