# Pester tests for the Windows setup-dialog styling sample (owned by Graphic Designer). Static checks on the parsed
# script only: it needs WinForms, which exists only on Windows, so it is never run here. A real preview on Windows 11
# is still a manual step. Run:  pwsh -c 'Invoke-Pester tests/windows -Output Detailed'
# Inputs ship with the branch, so every test runs in a bare clone:
#   tests/windows/fixtures/windows-dialog-sample.ps1, tests/windows/fixtures/WINDOWS-DIALOGS.md  (copies of the design files)
#   netbot/theme/tokens.css                                                                    (the shipped theme tokens)
# NETBOT_DESIGN_DIR (optional) runs the same tests on a design folder instead. Whenever a design folder is present
# (NETBOT_DESIGN_DIR, or _design/ next to the package), extra tests check that the fixtures and the shipped tokens
# match it; with no design folder those extra tests are simply not generated.

BeforeDiscovery {
  $script:SrcDir = if ($env:NETBOT_DESIGN_DIR) { $env:NETBOT_DESIGN_DIR } else { Join-Path $PSScriptRoot 'fixtures' }
  $script:SamplePath = Join-Path $script:SrcDir 'windows-dialog-sample.ps1'
  $script:HaveSample = Test-Path $script:SamplePath
  # Design folder to compare the shipped copies against, if one is present
  $cmp = if ($env:NETBOT_DESIGN_DIR) { $env:NETBOT_DESIGN_DIR } else { Join-Path $PSScriptRoot '../../_design' }
  $script:SyncPairs = @()
  if (Test-Path (Join-Path $cmp 'windows-dialog-sample.ps1')) {
    $script:SyncPairs = @(
      @{ Name = 'tests/windows/fixtures/windows-dialog-sample.ps1'; Shipped = (Join-Path $PSScriptRoot 'fixtures/windows-dialog-sample.ps1'); Design = (Join-Path $cmp 'windows-dialog-sample.ps1') }
      @{ Name = 'tests/windows/fixtures/WINDOWS-DIALOGS.md';        Shipped = (Join-Path $PSScriptRoot 'fixtures/WINDOWS-DIALOGS.md');        Design = (Join-Path $cmp 'WINDOWS-DIALOGS.md') }
      @{ Name = 'netbot/theme/tokens.css';                          Shipped = (Join-Path $PSScriptRoot '../../netbot/theme/tokens.css');     Design = (Join-Path $cmp 'tokens.css') }
    )
  }
  # Screens in flow order, with ClientSize height and heading from WINDOWS-DIALOGS.md
  $script:Screens = @(
    @{ Name = 'DishMonitoring'; H = 245; Head = 'Dish monitoring is on';                     Buttons = @('Continue');               Esc = 0 }
    @{ Name = 'RouterEntry';    H = 305; Head = 'What router do you have?';                  Buttons = @("I'm not sure", 'Continue'); Esc = 0 }
    @{ Name = 'AddonFound';     H = 226; Head = 'There is an add-on for your router';        Buttons = @('Not now', 'Turn On');     Esc = 0 }
    @{ Name = 'NoAddon';        H = 288; Head = 'NetBot will use dish and network monitoring'; Buttons = @('Continue');             Esc = 0 }
    @{ Name = 'RouterPassword'; H = 343; Head = 'Router password (optional)';                Buttons = @('Skip', 'Save');           Esc = 0 }
    @{ Name = 'Success';        H = 271; Head = 'NetBot is installed';                       Buttons = @('Close', 'Open Dashboard'); Esc = 0 }
    @{ Name = 'Error';          H = 228; Head = 'NetBot could not finish installing';        Buttons = @('Show Log', 'OK');         Esc = 1 }
  )
}

BeforeAll {
  $script:SrcDir = if ($env:NETBOT_DESIGN_DIR) { $env:NETBOT_DESIGN_DIR } else { Join-Path $PSScriptRoot 'fixtures' }
  # tokens: the design folder's when overridden, else the shipped theme copy
  $script:TokensPath = if ($env:NETBOT_DESIGN_DIR) { Join-Path $env:NETBOT_DESIGN_DIR 'tokens.css' } else { Join-Path $PSScriptRoot '../../netbot/theme/tokens.css' }
  $script:SamplePath = Join-Path $script:SrcDir 'windows-dialog-sample.ps1'
  if (Test-Path $script:SamplePath) {
    $tokens = $null; $script:ParseErrors = $null
    $script:Ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $script:SamplePath), [ref]$tokens, [ref]$script:ParseErrors)
    $script:Text = Get-Content -Raw $script:SamplePath
    # Screen table: the hashtable literal for each case of the `switch ($Screen)` that builds $S
    $script:ScreenTable = @{}
    $assign = $script:Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$S' }, $true) | Select-Object -First 1
    $switchAst = $assign.FindAll({ param($n) $n -is [System.Management.Automation.Language.SwitchStatementAst] }, $true) | Select-Object -First 1
    foreach ($clause in $switchAst.Clauses) {
      $name = $clause.Item1.Value
      $ht = $clause.Item2.FindAll({ param($n) $n -is [System.Management.Automation.Language.HashtableAst] }, $true) | Select-Object -First 1
      $entry = @{}
      foreach ($kv in $ht.KeyValuePairs) { $entry[$kv.Item1.Value] = $kv.Item2.Extent.Text }
      $script:ScreenTable[$name] = $entry
    }
  }
  $script:AppName = (Select-String -Path (Join-Path $PSScriptRoot '../../netbot/ui_text.py') -Pattern '^APP_NAME = "(.*)"$').Matches[0].Groups[1].Value
}

Describe 'Windows dialog sample: script shape' -Skip:(-not $HaveSample) {
  It 'parses without errors' {
    $ParseErrors.Count | Should -Be 0
  }
  It 'offers exactly the seven screens, in flow order' {
    $p = $Ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Screen' }
    $vs = $p.Attributes | Where-Object { $_.TypeName.Name -eq 'ValidateSet' }
    @($vs.PositionalArguments.Value) | Should -Be @('DishMonitoring', 'RouterEntry', 'AddonFound', 'NoAddon', 'RouterPassword', 'Success', 'Error')
  }
  It 'defaults to the first screen' {
    ($Ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Screen' }).DefaultValue.Value | Should -Be 'DishMonitoring'
  }
}

Describe 'Windows dialog sample: screen <Name>' -Skip:(-not $HaveSample) -ForEach $Screens {
  It 'has the height from the spec (<H> px)' {
    $ScreenTable[$Name]['H'] | Should -Be "$H"
  }
  It 'has the heading from the spec' {
    $ScreenTable[$Name]['Head'] | Should -Be "'$Head'"
  }
  It 'has the buttons from the spec, primary last' {
    $b = $ScreenTable[$Name]['Buttons']
    foreach ($label in $Buttons) { $b | Should -Match ([regex]::Escape($label.Replace("'", "''")) + '|' + [regex]::Escape($label)) }
    $b | Should -Match '\$true\)\)$'
  }
  It 'maps Esc to the button from the spec' {
    $ScreenTable[$Name]['Esc'] | Should -Be "$Esc"
  }
  It 'uses the right stripe color (OK on success, Alert on error, Accent otherwise)' {
    $want = switch ($Name) { 'Success' { '$C.Ok' } 'Error' { '$C.Alert' } default { '$C.Accent' } }
    $ScreenTable[$Name]['Stripe'] | Should -Be $want
  }
}

Describe 'Windows dialog sample: tokens match WINDOWS-DIALOGS.md and tokens.css' -Skip:(-not $HaveSample) {
  BeforeAll {
    # Token table rows in the spec:  | Accent | `#RRGGBB` | `FromArgb(r, g, b)` | ... |
    $doc = Get-Content -Raw (Join-Path $script:SrcDir 'WINDOWS-DIALOGS.md')
    $script:Spec = @{}
    foreach ($m in [regex]::Matches($doc, '(?m)^\|\s*([A-Za-z0-9 ]+?)\s*\|\s*`(#[0-9A-Fa-f]{6})`\s*\|\s*`FromArgb\(([0-9, ]+)\)`')) {
      $script:Spec[$m.Groups[1].Value] = @{ Hex = $m.Groups[2].Value.ToUpper(); Rgb = $m.Groups[3].Value }
    }
    $script:Css = Get-Content -Raw $script:TokensPath
    # sample key -> spec row name
    $script:KeyMap = @{ Bg = 'Bg'; Panel = 'Panel'; Raised = 'Raised'; Hair = 'Hairline'; Control = 'Control'; Text = 'Text'
                        Text2 = 'Text 2'; Text3 = 'Text 3'; Accent = 'Accent'; AccentH = 'Accent hover'; Ok = 'OK'; Alert = 'Alert' }
  }
  It 'the spec lists all 12 tokens' {
    $Spec.Count | Should -Be 12
  }
  It '<_> matches the spec (FromArgb and hex comment)' -ForEach @('Bg', 'Panel', 'Raised', 'Hair', 'Control', 'Text', 'Text2', 'Text3', 'Accent', 'AccentH', 'Ok', 'Alert') {
    $row = $Spec[$KeyMap[$_]]
    $row | Should -Not -BeNullOrEmpty
    $m = [regex]::Match($Text, "(?m)^\s*$_\s*=\s*\[System\.Drawing\.Color\]::FromArgb\(([0-9, ]+)\)\s*#\s*(#[0-9A-Fa-f]{6})")
    $m.Success | Should -BeTrue
    $m.Groups[1].Value | Should -Be $row.Rgb
    $m.Groups[2].Value.ToUpper() | Should -Be $row.Hex
  }
  It 'every spec color except the hover shade is a tokens.css token' {
    foreach ($k in $Spec.Keys | Where-Object { $_ -ne 'Accent hover' }) {
      $Css | Should -Match ([regex]::Escape($Spec[$k].Hex)) -Because "$k ($($Spec[$k].Hex)) should be in tokens.css"
    }
  }
}

Describe 'Windows dialog sample: colors are the shipped theme tokens (netbot/theme/tokens.css)' -Skip:(-not $HaveSample) {
  BeforeAll {
    $shipped = Get-Content -Raw (Join-Path $PSScriptRoot '../../netbot/theme/tokens.css')
    $script:Tok = @{}
    foreach ($m in [regex]::Matches($shipped, '(--[\w-]+)\s*:\s*#([0-9A-Fa-f]{6})\s*;')) { $script:Tok[$m.Groups[1].Value] = $m.Groups[2].Value.ToUpper() }
    $script:SampleRgb = @{}
    foreach ($m in [regex]::Matches($Text, '(?m)^\s*(\w+)\s*=\s*\[System\.Drawing\.Color\]::FromArgb\((\d+),\s*(\d+),\s*(\d+)\)')) {
      $script:SampleRgb[$m.Groups[1].Value] = ('{0:X2}{1:X2}{2:X2}' -f [int]$m.Groups[2].Value, [int]$m.Groups[3].Value, [int]$m.Groups[4].Value)
    }
  }
  It 'every sample color except the hover shade is a shipped token' {
    $SampleRgb.Count | Should -BeGreaterThan 0
    foreach ($k in $SampleRgb.Keys | Where-Object { $_ -ne 'AccentH' }) {
      $Tok.Values | Should -Contain $SampleRgb[$k] -Because "$k should use a color from netbot/theme/tokens.css"
    }
  }
  It '<_.Key> is <_.Value> from the shipped tokens' -ForEach @(
    @{ Key = 'Accent'; Value = '--nb-accent' }, @{ Key = 'Ok'; Value = '--nb-ok' }, @{ Key = 'Alert'; Value = '--nb-alert' },
    @{ Key = 'Panel'; Value = '--nb-panel' }, @{ Key = 'Text'; Value = '--nb-text' }) {
    $SampleRgb[$_.Key] | Should -Be $Tok[$_.Value]
  }
}

Describe 'Windows dialog sample: safety' -Skip:(-not $HaveSample) {
  It 'masks the password field and blocks copy/cut' {
    $Text | Should -Match 'UseSystemPasswordChar = \$true'
    $Text | Should -Match 'ShortcutsEnabled = \$false'
  }
  It 'never reads the password field text back out' {
    $Text | Should -Not -Match '\$focus\.Text'
    $Text | Should -Not -Match 'Secret[^\r\n]*\.Text\b'
  }
  It 'stores, sends, and starts nothing (styling only)' {
    $cmds = $Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() }
    foreach ($bad in 'Set-Content', 'Add-Content', 'Out-File', 'Start-Process', 'Invoke-WebRequest', 'Invoke-RestMethod', 'cmdkey', 'New-StoredCredential', 'Register-ScheduledTask', 'Invoke-Expression') {
      $cmds | Should -Not -Contain $bad
    }
  }
  It 'contains no product, company, or service brand names' {
    $brands = @(('Star' + 'link'), ('Space' + 'X'), ('Link' + 'sys'))
    foreach ($b in $brands) { $Text | Should -Not -Match $b }
  }
  It 'mentions the high-contrast fallback' {
    $Text | Should -Match 'SystemInformation\]::HighContrast'
  }
}

Describe 'Windows dialog sample: title' -Skip:(-not $HaveSample) {
  It 'window title bar uses the app name constant (APP_NAME in netbot/ui_text.py)' {
    $AppName | Should -Not -BeNullOrEmpty
    $m = [regex]::Match($Text, "\`$form\.Text = '([^']*)'")
    $m.Success | Should -BeTrue
    $m.Groups[1].Value | Should -BeExactly $AppName
  }
}

Describe 'Shipped copies match the design folder (only when one is present)' {
  It '<Name> matches the design copy' -ForEach $SyncPairs -AllowNullOrEmptyForEach {
    (Get-FileHash -Algorithm SHA256 $Shipped).Hash | Should -Be (Get-FileHash -Algorithm SHA256 $Design).Hash -Because "$Name is a copy of the design file; refresh it"
  }
}
