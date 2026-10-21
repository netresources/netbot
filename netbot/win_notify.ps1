<#
  NetBot notification for Windows: a tray balloon from the built-in Windows Forms NotifyIcon (nothing installed).
  Run by evaluate_alerts.py when a new ALERT appears. Title and message are plain text, never secrets.
#>
param([Parameter(Mandatory = $true)] [string] $Title, [Parameter(Mandatory = $true)] [string] $Message)
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
$n = New-Object System.Windows.Forms.NotifyIcon
$n.Icon = [System.Drawing.SystemIcons]::Warning
$n.BalloonTipIcon = 'Warning'
$n.BalloonTipTitle = $Title
$n.BalloonTipText = $Message
$n.Visible = $true
$n.ShowBalloonTip(10000)
Start-Sleep -Seconds 10
$n.Dispose()
