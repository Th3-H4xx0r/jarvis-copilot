# Letting the Mac reach the PC (one-time setup)

The Windows client is built and tested on the real PC from the Mac over SSH (Tailscale).
Do this once on the PC, in **PowerShell opened as Administrator**:

```powershell
# 1. Turn on the OpenSSH server and start it with Windows
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
Start-Service sshd
Set-Service -Name sshd -StartupType Automatic

# 2. Let the Mac's key in (paste the ONE line the Mac printed for you between the quotes).
#    Your account is an administrator, so Windows reads administrators_authorized_keys.
$key = 'PASTE-THE-ssh-ed25519-LINE-HERE'
Add-Content -Path "$env:ProgramData\ssh\administrators_authorized_keys" -Value $key
icacls "$env:ProgramData\ssh\administrators_authorized_keys" /inheritance:r /grant "Administrators:F" /grant "SYSTEM:F"

# 3. PowerShell as the shell for SSH sessions
New-ItemProperty -Path "HKLM:\SOFTWARE\OpenSSH" -Name DefaultShell `
  -Value "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" -PropertyType String -Force

# 4. Only Tailscale (and this PC) may reach SSH
Get-NetFirewallRule -Name *OpenSSH* | Set-NetFirewallRule -RemoteAddress 100.64.0.0/10,LocalSubnet
```

Then on the Mac, `~/.ssh/config` gets:

```
Host jc-pc
  HostName <the PC's Tailscale name>
  User <your Windows user name>
  IdentityFile ~/.ssh/jc_pc_ed25519
  IdentitiesOnly yes
```

Check from the Mac:

```bash
ssh jc-pc "powershell -NoProfile -c '\$PSVersionTable.PSVersion; whoami; (Get-CimInstance Win32_OperatingSystem).Caption'"
```

It should print a PowerShell version, your user, and "Microsoft Windows 11 …".

## Why each step

- **OpenSSH server**: built into Windows 11, off by default.
- **administrators_authorized_keys**: Windows ignores a per-user `authorized_keys` for admin accounts.
  The `icacls` line is required; sshd refuses the file if anyone else can write it.
- **Firewall to 100.64.0.0/10**: SSH answers only on your tailnet (and your home network), never the internet.
