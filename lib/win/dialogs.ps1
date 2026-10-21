<#
  NetBot setup dialogs for Windows (WinForms, built into Windows; nothing installed). Dot-sourced by install.ps1.
  Layout, fonts and wording follow WINDOWS-DIALOGS.md (the copy shipped for tests is tests/windows/fixtures/).
  Colors come from the shipped theme, netbot/theme/tokens.css, read at run time; system colors are used when
  Windows high contrast is on. All wording comes from strings/messages.ps1 ($MSG).

  Show-NbScreen -Screen <name> [-Values @{...}] [-OnSave {...}]  ->  @{ Button = 'primary'|'secondary'|'closed'; ... }
    DishMonitoring  Values: Address, Found        RouterEntry  -> Make, Model
    AddonFound      Values: Router                NoAddon      Values: NotSure
    RouterPassword  -OnSave { param($secure) ... return $null or an inline error message }
    Success         Values: RouterOn              Error        Values: Body, LogPath
#>

# Spec token name -> tokens.css variable (the dialog palette is a subset of the dashboard theme).
$script:NbTokenVars = [ordered]@{ Bg = '--nb-bg'; Panel = '--nb-panel'; Raised = '--nb-raised'; Hair = '--nb-hairline'; Control = '--nb-control'
  Text = '--nb-text'; Text2 = '--nb-text-2'; Text3 = '--nb-text-3'; Accent = '--nb-accent'; Ok = '--nb-ok'; Alert = '--nb-alert' }

# -> @{ Bg = @(r, g, b); ... } from the #RRGGBB values in tokens.css
function Read-NbTokens([string] $TokensCss) {
  $css = [regex]::Replace((Get-Content -LiteralPath $TokensCss -Raw -Encoding UTF8), '(?s)/\*.*?\*/', '')
  $out = @{}
  foreach ($k in $script:NbTokenVars.Keys) {
    $m = [regex]::Match($css, [regex]::Escape($script:NbTokenVars[$k]) + '\s*:\s*#([0-9A-Fa-f]{6})\s*;')
    if (-not $m.Success) { throw "theme token $($script:NbTokenVars[$k]) missing from $TokensCss" }
    $h = $m.Groups[1].Value
    $out[$k] = @([Convert]::ToInt32($h.Substring(0, 2), 16), [Convert]::ToInt32($h.Substring(2, 2), 16), [Convert]::ToInt32($h.Substring(4, 2), 16))
  }
  # Primary-button hover: the one shade in the spec that is not a theme token (Accent lightened, 11.0:1 with Bg).
  $out.AccentH = @(138, 247, 164)
  return $out
}

function Initialize-NbDialogs([string] $TokensCss) {
  Add-Type -AssemblyName System.Windows.Forms, System.Drawing
  [System.Windows.Forms.Application]::EnableVisualStyles()
  $t = Read-NbTokens $TokensCss
  $script:C = @{}
  foreach ($k in $t.Keys) { $script:C[$k] = [System.Drawing.Color]::FromArgb($t[$k][0], $t[$k][1], $t[$k][2]) }
  if ([System.Windows.Forms.SystemInformation]::HighContrast) {
    $S = [System.Drawing.SystemColors]
    $script:C = @{ Bg = $S::Window; Panel = $S::Control; Raised = $S::Control; Hair = $S::ControlDark; Control = $S::ControlDark
      Text = $S::ControlText; Text2 = $S::ControlText; Text3 = $S::GrayText; Accent = $S::Highlight; AccentH = $S::HotTrack
      Ok = $S::Highlight; Alert = $S::Highlight }
  }
  $script:F = @{
    Heading = New-Object System.Drawing.Font('Segoe UI Semibold', 12.0)
    Body    = New-Object System.Drawing.Font('Segoe UI', 9.75)
    Hint    = New-Object System.Drawing.Font('Segoe UI', 9.0)
    Button  = New-Object System.Drawing.Font('Segoe UI Semibold', 9.75)
    Kicker  = New-Object System.Drawing.Font('Consolas', 8.25, [System.Drawing.FontStyle]::Bold)
    Field   = New-Object System.Drawing.Font('Segoe UI', 9.75)
    Secret  = New-Object System.Drawing.Font('Consolas', 11.25)
    Mono    = New-Object System.Drawing.Font('Consolas', 9.0)
  }
  try {
    Add-Type -Namespace NetBotUi -Name Native -ErrorAction Stop -MemberDefinition @'
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern System.IntPtr SendMessage(System.IntPtr h, int m, System.IntPtr w, string l);
[DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(System.IntPtr h, int a, ref int v, int s);
'@
  } catch { }
}

function Add-NbLabel($Parent, [string] $Text, $Font, $Color, [int] $X, [int] $Y, [int] $W, [int] $H) {
  $l = New-Object System.Windows.Forms.Label
  $l.Text = $Text; $l.Font = $Font; $l.ForeColor = $Color; $l.BackColor = [System.Drawing.Color]::Transparent
  $l.SetBounds($X, $Y, $W, $H); $l.UseMnemonic = $false
  $Parent.Controls.Add($l); return $l
}
function Add-NbTextBox($Parent, [int] $X, [int] $Y, [int] $W, $Font, [string] $AccessibleName, [string] $Cue = '', [switch] $Secret, [switch] $ReadOnly) {
  $t = New-Object System.Windows.Forms.TextBox
  $t.SetBounds($X, $Y, $W, 28); $t.Font = $Font; $t.BorderStyle = 'FixedSingle'
  $t.BackColor = $C.Bg; $t.ForeColor = $C.Text; $t.AccessibleName = $AccessibleName
  if ($Secret) { $t.UseSystemPasswordChar = $true; $t.ShortcutsEnabled = $false }
  if ($ReadOnly) { $t.ReadOnly = $true }
  if ($Cue) {
    $t.Tag = $Cue
    $t.Add_HandleCreated({ param($s, $e) try { [void][NetBotUi.Native]::SendMessage($s.Handle, 0x1501, [IntPtr]1, [string]$s.Tag) } catch { } })
  }
  $Parent.Controls.Add($t); return $t
}
function New-NbButton([string] $Text, [bool] $Primary, [int] $X, [int] $W) {
  $b = New-Object System.Windows.Forms.Button
  $b.Text = $Text; $b.Font = $F.Button; $b.SetBounds($X, 21, $W, 32)
  $b.FlatStyle = 'Flat'; $b.FlatAppearance.BorderSize = 1; $b.Cursor = 'Hand'; $b.UseMnemonic = $false
  if ($Primary) { $b.BackColor = $C.Accent; $b.ForeColor = $C.Bg; $b.FlatAppearance.BorderColor = $C.Accent; $b.FlatAppearance.MouseOverBackColor = $C.AccentH }
  else { $b.BackColor = $C.Panel; $b.ForeColor = $C.Text; $b.FlatAppearance.BorderColor = $C.Control; $b.FlatAppearance.MouseOverBackColor = $C.Raised }
  $focusColor = $C.Text
  $b.Add_Paint({ param($s, $e)       # flat buttons draw no focus cue of their own: 2 px Text rectangle
      if ($s.Focused) { $p = New-Object System.Drawing.Pen($focusColor, 2); $e.Graphics.DrawRectangle($p, 3, 3, $s.Width - 7, $s.Height - 7); $p.Dispose() } }.GetNewClosure())
  return $b
}

# -> lines the error body wraps to at 412 px (the spec adds 19 px per extra line)
function Get-NbBodyLines([string] $Text) {
  if (-not $Text) { return 1 }
  try {
    $sz = [System.Windows.Forms.TextRenderer]::MeasureText($Text, $F.Body, (New-Object System.Drawing.Size(412, 0)), [System.Windows.Forms.TextFormatFlags]::WordBreak)
    return [Math]::Max(1, [int][Math]::Ceiling($sz.Height / 19.0))
  } catch { return [Math]::Max(1, [int][Math]::Ceiling($Text.Length / 70.0)) }
}

# -> hashtable describing one screen (sizes and wording from the spec)
function Get-NbScreenSpec([string] $Screen, [hashtable] $Values) {
  switch ($Screen) {
    'DishMonitoring' { return @{ H = 245; Stripe = 'Accent'; Kicker = $MSG.D1_KICKER; Head = $MSG.D1_HEAD; BodyH = 76
        Body = $(if ($Values.Found) { $MSG.D1_BODY_FOUND -f $Values.Address } else { $MSG.D1_BODY_NOT_YET -f $Values.Address })
        Buttons = @(@($MSG.BTN_CONTINUE, $true)); Esc = 'primary' } }
    'RouterEntry' { return @{ H = 305; Stripe = 'Accent'; Kicker = $MSG.D2_KICKER; Head = $MSG.D2_HEAD; Body = $MSG.D2_BODY; BodyH = 57
        Buttons = @(@($MSG.BTN_NOT_SURE, $false), @($MSG.BTN_CONTINUE, $true)); Esc = 'secondary' } }
    'AddonFound' { return @{ H = 226; Stripe = 'Accent'; Kicker = $MSG.D3A_KICKER; Head = $MSG.D3A_HEAD; Body = ($MSG.D3A_BODY -f $Values.Router); BodyH = 57
        Buttons = @(@($MSG.BTN_NOT_NOW, $false), @($MSG.BTN_TURN_ON, $true)); Esc = 'secondary' } }
    'NoAddon' { return @{ H = 288; Stripe = 'Accent'; Kicker = $MSG.D3B_KICKER; Head = $MSG.D3B_HEAD; BodyH = 38
        Body = $(if ($Values.NotSure) { $MSG.D3B_BODY_NOT_SURE } else { $MSG.D3B_BODY_NO_ADDON })
        Buttons = @(@($MSG.BTN_CONTINUE, $true)); Esc = 'primary' } }
    'RouterPassword' { return @{ H = 343; Stripe = 'Accent'; Kicker = $MSG.D4_KICKER; Head = $MSG.D4_HEAD; Body = $MSG.D4_BODY; BodyH = 76
        Buttons = @(@($MSG.BTN_SKIP, $false), @($MSG.BTN_SAVE, $true)); Esc = 'secondary' } }
    'Success' { return @{ H = 271; Stripe = 'Ok'; Kicker = $MSG.D5_KICKER; Head = $MSG.D5_HEAD; Body = $MSG.D5_BODY; BodyH = 38
        Buttons = @(@($MSG.BTN_CLOSE, $false), @($MSG.BTN_OPEN_DASHBOARD, $true)); Esc = 'secondary' } }
    'Error' { $lines = Get-NbBodyLines $Values.Body
      return @{ H = 228 + 19 * ($lines - 1); Stripe = 'Alert'; Kicker = $MSG.D6_KICKER; Head = $MSG.D6_HEAD; Body = $Values.Body; BodyH = 19 * $lines
        Buttons = @(@($MSG.BTN_SHOW_LOG, $false), @($MSG.BTN_OK, $true)); Esc = 'primary' } }
  }
  throw "unknown screen $Screen"
}

function Show-NbScreen([string] $Screen, [hashtable] $Values = @{}, [scriptblock] $OnSave = $null) {
  $S = Get-NbScreenSpec $Screen $Values
  $res = @{ Button = 'closed' }
  $form = New-Object System.Windows.Forms.Form
  $form.Text = $MSG.TITLE; $form.AutoScaleMode = 'Dpi'; $form.ClientSize = New-Object System.Drawing.Size(460, $S.H)
  $form.FormBorderStyle = 'FixedDialog'; $form.StartPosition = 'CenterScreen'; $form.MaximizeBox = $false; $form.MinimizeBox = $false
  $form.BackColor = $C.Panel; $form.ForeColor = $C.Text; $form.Font = $F.Body; $form.KeyPreview = $true; $form.TopMost = $true
  $form.Add_HandleCreated({ param($s, $e) try { $one = 1; [void][NetBotUi.Native]::DwmSetWindowAttribute($s.Handle, 20, [ref]$one, 4) } catch { } })

  $stripe = New-Object System.Windows.Forms.Panel; $stripe.SetBounds(0, 0, 460, 3); $stripe.BackColor = $C[$S.Stripe]; $form.Controls.Add($stripe)
  [void](Add-NbLabel $form $S.Kicker $F.Kicker $C[$S.Stripe] 24 27 412 16)
  [void](Add-NbLabel $form $S.Head $F.Heading $C.Text 24 47 412 26)
  [void](Add-NbLabel $form $S.Body $F.Body $C.Text2 24 77 412 $S.BodyH)

  $focus = $null; $make = $null; $model = $null; $pw = $null; $hint = $null
  switch ($Screen) {
    'RouterEntry' {
      [void](Add-NbLabel $form $MSG.D2_MAKE $F.Kicker $C.Text3 24 146 198 16)
      [void](Add-NbLabel $form $MSG.D2_MODEL $F.Kicker $C.Text3 238 146 198 16)
      $make = Add-NbTextBox $form 24 166 198 $F.Field $MSG.D2_MAKE_NAME $MSG.D2_MAKE_CUE; $make.TabIndex = 0; $focus = $make
      $model = Add-NbTextBox $form 238 166 198 $F.Field $MSG.D2_MODEL_NAME $MSG.D2_MODEL_CUE; $model.TabIndex = 1
      [void](Add-NbLabel $form $MSG.D2_HINT $F.Hint $C.Text3 24 200 412 18)
    }
    'RouterPassword' {
      [void](Add-NbLabel $form $MSG.D4_LABEL $F.Kicker $C.Text3 24 165 412 16)
      $pw = Add-NbTextBox $form 24 185 412 $F.Secret $MSG.D4_NAME -Secret; $pw.TabIndex = 0; $focus = $pw
      $hint = Add-NbLabel $form $MSG.D4_HINT $F.Hint $C.Text3 24 217 412 34
    }
    'NoAddon' {
      for ($i = 0; $i -lt 4; $i++) {
        $x = 24 + ($i % 2) * 212; $y = 123 + [Math]::Floor($i / 2) * 24
        [void](Add-NbLabel $form ([string][char]0x25A0) $F.Mono $C.Accent $x $y 16 18)            # accent square mark
        [void](Add-NbLabel $form $MSG.D3B_ITEMS[$i] $F.Mono $C.Text ($x + 16) $y 184 18)
      }
      [void](Add-NbLabel $form $MSG.D3B_FOOT $F.Body $C.Text2 24 177 412 19)
    }
    'Success' {   # chips: filled square + Accent border when on, hollow square + Control border when off
      $chips = @(@($MSG.D5_CHIP_DISH, $true), @($MSG.D5_CHIP_NETWORK, $true),
                 @($(if ($Values.RouterOn) { $MSG.D5_CHIP_ROUTER_ON } else { $MSG.D5_CHIP_ROUTER_OFF }), [bool]$Values.RouterOn))
      $x = 24; $y = 127
      foreach ($c in $chips) {
        $txt = [string]$(if ($c[1]) { [char]0x25A0 } else { [char]0x25A1 }) + '  ' + $c[0]
        $w = [System.Windows.Forms.TextRenderer]::MeasureText($txt, $F.Kicker).Width + 16
        if ($x + $w -gt 436) { $x = 24; $y += 30 }
        $l = Add-NbLabel $form $txt $F.Kicker ($(if ($c[1]) { $C.Text } else { $C.Text2 })) $x $y $w 22
        $l.TextAlign = 'MiddleCenter'
        $border = $(if ($c[1]) { $C.Accent } else { $C.Control })
        $l.Add_Paint({ param($s, $e) $p = New-Object System.Drawing.Pen($border, 1); $e.Graphics.DrawRectangle($p, 0, 0, $s.Width - 1, $s.Height - 1); $p.Dispose() }.GetNewClosure())
        $x += $w + 8
      }
    }
    'Error' {
      $p = Add-NbTextBox $form 24 (108 + 19 * ((Get-NbBodyLines $Values.Body) - 1)) 412 $F.Mono $MSG.D6_LOG_NAME -ReadOnly
      $p.Text = $Values.LogPath
    }
  }

  # Button strip: bottom 72 px, Raised fill, 1 px Hairline rule; min 96 px wide, 8 px apart, 24 px right margin, primary on the right.
  $strip = New-Object System.Windows.Forms.Panel; $strip.SetBounds(0, $S.H - 72, 460, 72); $strip.BackColor = $C.Raised
  $rule = New-Object System.Windows.Forms.Panel; $rule.SetBounds(0, 0, 460, 1); $rule.BackColor = $C.Hair; $strip.Controls.Add($rule)
  $btn = @{}; $x = 436
  for ($i = $S.Buttons.Count - 1; $i -ge 0; $i--) {
    $t = $S.Buttons[$i][0]; $primary = $S.Buttons[$i][1]
    $w = [Math]::Max(96, [System.Windows.Forms.TextRenderer]::MeasureText($t, $F.Button).Width + 32); $x -= $w
    $b = New-NbButton $t $primary $x $w; $b.TabIndex = 10 + $i
    $btn[$(if ($primary) { 'primary' } else { 'secondary' })] = $b
    $strip.Controls.Add($b); $x -= 8
    if ($primary) { $form.AcceptButton = $b }
  }
  $form.Controls.Add($strip)

  $finish = {
    param([string] $which)
    if ($which -eq 'primary' -and $Screen -eq 'RouterPassword') {
      if ($pw.TextLength -eq 0) { $hint.Text = $MSG.D4_ERR_EMPTY; $hint.ForeColor = $C.Alert; $pw.Focus(); return }
      $sec = New-Object System.Security.SecureString
      foreach ($ch in $pw.Text.ToCharArray()) { $sec.AppendChar($ch) }
      $sec.MakeReadOnly(); $pw.Clear()                            # the box is cleared as soon as the value is taken
      $err = if ($OnSave) { & $OnSave $sec } else { $null }
      $sec.Dispose()
      if ($err) { $hint.Text = $err; $hint.ForeColor = $C.Alert; $pw.Focus(); return }
    }
    if ($which -eq 'secondary' -and $Screen -eq 'Error') { Open-NbFile 'notepad.exe' $Values.LogPath; return }   # Show Log keeps the dialog
    if ($Screen -eq 'RouterEntry') { $res.Make = $make.Text.Trim(); $res.Model = $model.Text.Trim() }
    $res.Button = $which; $form.Close()
  }.GetNewClosure()
  foreach ($k in @($btn.Keys)) { $kk = $k; $btn[$k].Add_Click({ & $finish $kk }.GetNewClosure()) }
  $escWhich = $(if ($btn.ContainsKey($S.Esc)) { $S.Esc } else { 'primary' })
  $form.Add_KeyDown({ param($s, $e) if ($e.KeyCode -eq 'Escape') { $e.Handled = $true; & $finish $escWhich } }.GetNewClosure())
  if ($focus) { $form.Add_Shown({ $focus.Focus() }.GetNewClosure()) }
  [void]$form.ShowDialog(); $form.Dispose()
  return $res
}
