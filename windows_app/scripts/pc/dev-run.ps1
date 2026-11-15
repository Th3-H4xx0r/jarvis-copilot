# Runs ~/jc-dev/cmd.ps1 inside the interactive desktop session; output to ~/jc-dev/out.txt,
# ending with a __done__ line. Started by the \Jarvis\Dev scheduled task.
$dev = Join-Path $env:USERPROFILE 'jc-dev'
$out = Join-Path $dev 'out.txt'

function Shot([string]$name) {
  Add-Type -AssemblyName System.Windows.Forms
  Add-Type -AssemblyName System.Drawing
  $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
  $bmp = New-Object System.Drawing.Bitmap $vs.Width, $vs.Height
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  try {
    $g.CopyFromScreen($vs.Left, $vs.Top, 0, 0, $bmp.Size)
    $bmp.Save((Join-Path $dev "$name.png"), [System.Drawing.Imaging.ImageFormat]::Png)
    "saved $name.png ($($vs.Width)x$($vs.Height))"
  } finally {
    $g.Dispose(); $bmp.Dispose()
  }
}

try {
  & (Join-Path $dev 'cmd.ps1') *>&1 | Out-String -Width 400 | Set-Content -Path $out -Encoding utf8
} catch {
  "ERROR: $_" | Set-Content -Path $out -Encoding utf8
}
Add-Content -Path $out -Value '__done__' -Encoding utf8
