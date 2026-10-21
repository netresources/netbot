<#
  NetBot Windows setup dialogs: STYLING REFERENCE (design file only).
  It shows the colors, fonts, sizes, layout and wording from WINDOWS-DIALOGS.md. It is not wired up:
  it stores nothing, looks up nothing, opens nothing, and only prints which button was clicked.
  Preview on Windows (PowerShell 5.1 or 7):
    powershell -NoProfile -ExecutionPolicy Bypass -File .\windows-dialog-sample.ps1 -Screen DishMonitoring
  Screens, in flow order: DishMonitoring | RouterEntry | AddonFound | NoAddon | RouterPassword | Success | Error
#>
param([ValidateSet('DishMonitoring', 'RouterEntry', 'AddonFound', 'NoAddon', 'RouterPassword', 'Success', 'Error')] [string] $Screen = 'DishMonitoring')

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# ---- Tokens (same values as tokens.css)
$C = @{
  Bg      = [System.Drawing.Color]::FromArgb(6, 8, 11)       # #06080B  field fill, primary button text
  Panel   = [System.Drawing.Color]::FromArgb(12, 17, 23)     # #0C1117  window body
  Raised  = [System.Drawing.Color]::FromArgb(18, 25, 34)     # #121922  button strip
  Hair    = [System.Drawing.Color]::FromArgb(38, 50, 65)     # #263241  strip rule
  Control = [System.Drawing.Color]::FromArgb(86, 102, 122)   # #56667A  borders of buttons, fields, chips (3.2:1)
  Text    = [System.Drawing.Color]::FromArgb(242, 245, 248)  # #F2F5F8
  Text2   = [System.Drawing.Color]::FromArgb(167, 178, 192)  # #A7B2C0
  Text3   = [System.Drawing.Color]::FromArgb(123, 135, 150)  # #7B8796
  Accent  = [System.Drawing.Color]::FromArgb(61, 242, 111)   # #3DF26F
  AccentH = [System.Drawing.Color]::FromArgb(138, 247, 164)  # #8AF7A4  primary hover
  Ok      = [System.Drawing.Color]::FromArgb(55, 164, 132)   # #37A484
  Alert   = [System.Drawing.Color]::FromArgb(255, 92, 92)    # #FF5C5C
}
$F = @{
  Heading = New-Object System.Drawing.Font('Segoe UI Semibold', 12.0)                            # 16 px
  Body    = New-Object System.Drawing.Font('Segoe UI', 9.75)                                     # 13 px
  Hint    = New-Object System.Drawing.Font('Segoe UI', 9.0)                                      # 12 px
  Button  = New-Object System.Drawing.Font('Segoe UI Semibold', 9.75)                            # 13 px
  Kicker  = New-Object System.Drawing.Font('Consolas', 8.25, [System.Drawing.FontStyle]::Bold)   # 11 px
  Field   = New-Object System.Drawing.Font('Segoe UI', 9.75)                                     # 13 px
  Secret  = New-Object System.Drawing.Font('Consolas', 11.25)                                    # 15 px
  Mono    = New-Object System.Drawing.Font('Consolas', 9.0)                                      # 12 px
}

function Add-Label($form, $text, $font, $color, $x, $y, $w, $h) {
  $l = New-Object System.Windows.Forms.Label
  $l.Text = $text; $l.Font = $font; $l.ForeColor = $color; $l.BackColor = [System.Drawing.Color]::Transparent
  $l.SetBounds($x, $y, $w, $h); $l.UseMnemonic = $false
  $form.Controls.Add($l); return $l
}
function Add-TextBox($form, $x, $y, $w, $font, $accessibleName, [string] $cue = '', [switch] $Secret, [switch] $ReadOnly) {
  $t = New-Object System.Windows.Forms.TextBox
  $t.SetBounds($x, $y, $w, 28); $t.Font = $font; $t.BorderStyle = 'FixedSingle'
  $t.BackColor = $C.Bg; $t.ForeColor = $C.Text; $t.AccessibleName = $accessibleName
  if ($Secret)   { $t.UseSystemPasswordChar = $true; $t.ShortcutsEnabled = $false }   # masked, no copy/cut
  if ($ReadOnly) { $t.ReadOnly = $true }
  if ($cue) {    # grey placeholder text (EM_SETCUEBANNER), shown while the box is empty
    $t.Add_HandleCreated({ param($s, $e) [void][NetBotUi.Native]::SendMessage($s.Handle, 0x1501, [IntPtr]1, $s.Tag) }.GetNewClosure())
    $t.Tag = $cue
  }
  $form.Controls.Add($t); return $t
}
function New-Button($text, [bool] $primary, $x, $y, $w) {
  $b = New-Object System.Windows.Forms.Button
  $b.Text = $text; $b.Font = $F.Button; $b.SetBounds($x, $y, $w, 32)
  $b.FlatStyle = 'Flat'; $b.FlatAppearance.BorderSize = 1; $b.Cursor = 'Hand'
  if ($primary) { $b.BackColor = $C.Accent; $b.ForeColor = $C.Bg; $b.FlatAppearance.BorderColor = $C.Accent; $b.FlatAppearance.MouseOverBackColor = $C.AccentH }
  else          { $b.BackColor = $C.Panel;  $b.ForeColor = $C.Text; $b.FlatAppearance.BorderColor = $C.Control; $b.FlatAppearance.MouseOverBackColor = $C.Raised }
  return $b
}
try {
  Add-Type -Namespace NetBotUi -Name Native -ErrorAction Stop -MemberDefinition @'
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern System.IntPtr SendMessage(System.IntPtr h, int m, System.IntPtr w, string l);
[DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(System.IntPtr h, int a, ref int v, int s);
'@
} catch { }

# ---- Screen definitions (wording is exact; see WINDOWS-DIALOGS.md)
$dot = [string][char]0x25CF; $dia = [string][char]0x25C6
$S = switch ($Screen) {
  'DishMonitoring' { @{ H = 245; Stripe = $C.Accent; KColor = $C.Accent; Kicker = "$dot  DISH MONITORING"
      Head = 'Dish monitoring is on'
      Body = "NetBot found your dish at 192.168.100.1. Every 5 minutes it checks the dish's status, outages, obstruction, latency, throughput and alerts, plus ping, latency, packet loss and speed tests on your connection."; BodyH = 76
      Buttons = @(@('Continue', $true)); Esc = 0 } }
  'RouterEntry' { @{ H = 305; Stripe = $C.Accent; KColor = $C.Accent; Kicker = "$dot  ROUTER · OPTIONAL"
      Head = 'What router do you have?'
      Body = 'Optional. If NetBot has an add-on for your router, it can also show router stats, such as connected devices and Wi-Fi signal. The make and model are usually on a label on the router.'; BodyH = 57
      Buttons = @(@("I'm not sure", $false), @('Continue', $true)); Esc = 0 } }
  'AddonFound' { @{ H = 226; Stripe = $C.Accent; KColor = $C.Accent; Kicker = "$dot  ROUTER ADD-ON FOUND"
      Head = 'There is an add-on for your router'
      Body = 'NetBot can add router stats for your {Make} {Model}: WAN connection, connected devices and Wi-Fi signal. You can turn it on now or later.'; BodyH = 57
      Buttons = @(@('Not now', $false), @('Turn On', $true)); Esc = 0 } }
  'NoAddon' { @{ H = 288; Stripe = $C.Accent; KColor = $C.Accent; Kicker = "$dot  DISH + NETWORK MONITORING"
      Head = 'NetBot will use dish and network monitoring'
      Body = "There is no add-on for this router yet, and that's fine. NetBot will still watch:"; BodyH = 38
      Buttons = @(@('Continue', $true)); Esc = 0 } }
  'RouterPassword' { @{ H = 343; Stripe = $C.Accent; KColor = $C.Accent; Kicker = "$dot  ROUTER ADD-ON · OPTIONAL"
      Head = 'Router password (optional)'
      Body = "The router add-on can read more router stats with your router's admin password.`r`n`r`nIt is saved only on this computer, in Windows Credential Manager."; BodyH = 76
      Buttons = @(@('Skip', $false), @('Save', $true)); Esc = 0 } }
  'Success' { @{ H = 271; Stripe = $C.Ok; KColor = $C.Ok; Kicker = "$dot  OK · INSTALLED"
      Head = 'NetBot is installed'
      Body = 'NetBot checks your dish and connection every 5 minutes. Bookmark the dashboard so you can find it later.'; BodyH = 38
      Buttons = @(@('Close', $false), @('Open Dashboard', $true)); Esc = 0 } }
  'Error' { @{ H = 228; Stripe = $C.Alert; KColor = $C.Alert; Kicker = "$dia  ALERT · INSTALL FAILED"
      Head = 'NetBot could not finish installing'
      Body = 'NetBot stopped before it finished. Details are in:'; BodyH = 19
      Buttons = @(@('Show Log', $false), @('OK', $true)); Esc = 1 } }
}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'NetBot'; $form.AutoScaleMode = 'Dpi'; $form.ClientSize = New-Object System.Drawing.Size(460, $S.H)
$form.FormBorderStyle = 'FixedDialog'; $form.StartPosition = 'CenterScreen'; $form.MaximizeBox = $false; $form.MinimizeBox = $false
$form.BackColor = $C.Panel; $form.ForeColor = $C.Text; $form.Font = $F.Body; $form.KeyPreview = $true
$form.Add_HandleCreated({ try { $one = 1; [void][NetBotUi.Native]::DwmSetWindowAttribute($form.Handle, 20, [ref]$one, 4) } catch { } })  # dark title bar

$stripe = New-Object System.Windows.Forms.Panel; $stripe.SetBounds(0, 0, 460, 3); $stripe.BackColor = $S.Stripe; $form.Controls.Add($stripe)
[void](Add-Label $form $S.Kicker $F.Kicker $S.KColor 24 27 412 16)
[void](Add-Label $form $S.Head $F.Heading $C.Text 24 47 412 26)
[void](Add-Label $form $S.Body $F.Body $C.Text2 24 77 412 $S.BodyH)

$focus = $null
switch ($Screen) {
  'RouterEntry' {
    [void](Add-Label $form 'MAKE' $F.Kicker $C.Text3 24 146 198 16)
    [void](Add-Label $form 'MODEL' $F.Kicker $C.Text3 238 146 198 16)
    $focus = Add-TextBox $form 24 166 198 $F.Field 'Router make' 'Brand on the label'
    [void](Add-TextBox $form 238 166 198 $F.Field 'Router model' 'For example X100')
    [void](Add-Label $form 'Not sure? Dish and network monitoring work without it.' $F.Hint $C.Text3 24 200 412 18)
  }
  'RouterPassword' {
    [void](Add-Label $form 'ROUTER ADMIN PASSWORD' $F.Kicker $C.Text3 24 165 412 16)
    $focus = Add-TextBox $form 24 185 412 $F.Secret 'Router admin password' -Secret
    [void](Add-Label $form 'Characters are hidden as you type. Skip if you prefer. The add-on then shows only what the router shares without a password.' $F.Hint $C.Text3 24 217 412 34)
  }
  'NoAddon' {
    $items = @('Dish status and alerts', 'Outages and obstruction', 'Ping, latency and loss', 'Speed tests')
    for ($i = 0; $i -lt 4; $i++) {
      $x = 24 + ($i % 2) * 212; $y = 123 + [Math]::Floor($i / 2) * 24
      [void](Add-Label $form ("$dot  " + $items[$i]) $F.Mono $C.Text $x $y 200 18)
    }
    [void](Add-Label $form 'You can add a router add-on later by running setup again.' $F.Body $C.Text2 24 177 412 19)
  }
  'Success' {   # status chips: border + filled square when on, hollow square when off (round marks are reserved for the OK light) (example values)
    $chips = @(@('DISH · ON', $true), @('NETWORK CHECKS · ON', $true), @('ROUTER ADD-ON · ON', $true))   # router chip shows OFF when the add-on is off
    $x = 24; $y = 127
    foreach ($c in $chips) {
      $txt = $(if ($c[1]) { [char]0x25A0 } else { [char]0x25A1 }) + '  ' + $c[0]
      $w = [System.Windows.Forms.TextRenderer]::MeasureText($txt, $F.Kicker).Width + 16
      if ($x + $w -gt 436) { $x = 24; $y += 30 }
      $l = Add-Label $form $txt $F.Kicker ($(if ($c[1]) { $C.Text } else { $C.Text2 })) $x $y $w 22
      $l.TextAlign = 'MiddleCenter'; $l.BorderStyle = 'FixedSingle'   # system border; owner-draw for Accent/Control borders
      $x += $w + 8
    }
  }
  'Error' {
    $p = Add-TextBox $form 24 108 412 $F.Mono 'Install log location' -ReadOnly
    $p.Text = (Join-Path $env:USERPROFILE 'NetBot\install.log')   # display only
  }
}

# Button strip: bottom 72 px, Raised fill, 1 px Hairline rule, buttons 32 px high, min 96 px, 8 px apart, right margin 24 px.
$strip = New-Object System.Windows.Forms.Panel; $strip.SetBounds(0, $S.H - 72, 460, 72); $strip.BackColor = $C.Raised
$rule = New-Object System.Windows.Forms.Panel; $rule.SetBounds(0, 0, 460, 1); $rule.BackColor = $C.Hair; $strip.Controls.Add($rule)
$made = @(); $x = 436
for ($i = $S.Buttons.Count - 1; $i -ge 0; $i--) {
  $t = $S.Buttons[$i][0]; $primary = $S.Buttons[$i][1]
  $w = [Math]::Max(96, [System.Windows.Forms.TextRenderer]::MeasureText($t, $F.Button).Width + 32); $x -= $w
  $b = New-Button $t $primary $x 21 $w; $b.TabIndex = 10 + $i
  $b.Add_Click({ param($s, $e) $form.Tag = $s.Text; $form.Close() }.GetNewClosure())
  $strip.Controls.Add($b); $made = @($b) + $made; $x -= 8
  if ($primary) { $form.AcceptButton = $b }                    # Enter
}
$form.Controls.Add($strip)
# Esc: first button (secondary: I'm not sure / Skip / Close), the only button (Continue), or OK on the error screen.
$escBtn = $made[[Math]::Min($S.Esc, $made.Count - 1)]
$form.Add_KeyDown({ param($s, $e) if ($e.KeyCode -eq 'Escape') { $form.Tag = $escBtn.Text; $form.Close() } }.GetNewClosure())
if ($focus) { $form.Add_Shown({ $focus.Focus() }.GetNewClosure()) }

if ([System.Windows.Forms.SystemInformation]::HighContrast) { Write-Host 'High contrast is on: a real build should fall back to system colors.' }
[void]$form.ShowDialog(); $form.Dispose()
Write-Output ("clicked: " + $(if ($form.Tag) { $form.Tag } else { 'window closed' }))   # preview only; nothing is acted on
