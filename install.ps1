<#
  NetBot installer for Windows 10 and 11 (Windows PowerShell 5.1 or PowerShell 7). Read-only dish monitor,
  network checks, and an optional router add-on. Please read this file before running it. Easiest start:
  double-click 'Install NetBot.cmd'. Or:  powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
  Nothing is downloaded except the pinned dish library (checked against its sha256) and Python packages from PyPI.
  No admin rights needed. Safe to run again: it updates an existing install in place and keeps your history.
  Wording lives in strings\messages.ps1; helpers in lib\win\common.ps1; dialogs in lib\win\dialogs.ps1.
#>
param(
  [switch] $Launcher,     # set by the .cmd launcher: print the closing line it needs
  [switch] $DryRun        # list the paths that would be deleted instead of deleting them (all checks still run)
)

$NbSrc = $PSScriptRoot
. ([IO.Path]::Combine($NbSrc, 'strings', 'messages.ps1'))
. ([IO.Path]::Combine($NbSrc, 'lib', 'win', 'common.ps1'))
. ([IO.Path]::Combine($NbSrc, 'lib', 'win', 'dialogs.ps1'))
if ($DryRun) { $script:NbDryRun = $true }

$NbTaskName = 'io.netbot.collect'           # the same label as the launchd job on a Mac
$NbCredTarget = 'netbot-linksys'            # Credential Manager target = the keychain_service in config.toml
$NbCredUser = 'admin'

function Get-NbHome { if ($env:NETBOT_HOME) { return $env:NETBOT_HOME } return (Join-Path $env:USERPROFILE 'NetBot') }
function ConvertTo-NbTomlPath([string] $Path) { return ($Path -replace '\\', '/') }    # forward slashes: no TOML escapes needed

# -> folders that look like cloud-synced roots on this PC (OneDrive, iCloud Drive, Dropbox, Google Drive)
function Get-NbCloudRoots {
  $c = @()
  if ($env:NETBOT_CLOUD_DIRS) { $c = $env:NETBOT_CLOUD_DIRS -split ';' }
  else {
    $c = @($env:OneDriveConsumer, $env:OneDriveCommercial, $env:OneDrive, (Join-Path $env:USERPROFILE 'iCloudDrive'),
           (Join-Path $env:USERPROFILE 'Dropbox'), (Join-Path $env:USERPROFILE 'Google Drive'), 'G:\My Drive')
  }
  $seen = @{}; $out = @()
  foreach ($d in $c) {
    if (-not $d -or -not (Test-Path -LiteralPath $d -PathType Container)) { continue }
    $full = (Resolve-Path -LiteralPath $d).ProviderPath.TrimEnd('\', '/')
    if (-not $seen.ContainsKey($full.ToLowerInvariant())) { $seen[$full.ToLowerInvariant()] = 1; $out += $full }
  }
  return , $out
}

# -> @{ Host; UsePw } after the router questions (dialogs when $Gui, console otherwise)
function Invoke-NbRouterSetup([bool] $Gui, [string] $State) {
  $r = @{ Host = ''; UsePw = $false }
  if ($Gui) {
    $e = Show-NbScreen 'RouterEntry'
    $notSure = ($e.Button -ne 'primary') -or (-not $e.Make -and -not $e.Model)
    $addon = if ($notSure) { $null } else { Find-NbRouterAddon $e.Make }
    if (-not $addon) {
      Write-NbOk $(if ($notSure) { $MSG.ROUTER_UNSURE } else { $MSG.ROUTER_NO_ADDON })
      [void](Show-NbScreen 'NoAddon' @{ NotSure = $notSure }); return $r
    }
    $name = ("$($e.Make) $($e.Model)").Trim()
    if ((Show-NbScreen 'AddonFound' @{ Router = $name }).Button -ne 'primary') { Write-NbOk $MSG.ROUTER_SKIP; return $r }
  } else {
    if (-not (Confirm-Nb $MSG.ROUTER_ASK $true)) { Write-NbOk $MSG.ROUTER_SKIP; return $r }
    $make = Read-NbAnswer ('  ' + $MSG.ROUTER_MAKE_ASK) ''
    if (-not $make) { Write-NbOk $MSG.ROUTER_UNSURE; return $r }
    $model = Read-NbAnswer ('  ' + $MSG.ROUTER_MODEL_ASK) ''
    if (-not (Find-NbRouterAddon $make)) { Write-NbOk $MSG.ROUTER_NO_ADDON; return $r }
    if (-not (Confirm-Nb ('  ' + $MSG.ROUTER_ADDON_ASK) $true)) { Write-NbOk $MSG.ROUTER_SKIP; return $r }
  }

  # find the router: this PC's gateway first, then the usual addresses
  $cands = if ($env:NETBOT_ROUTER_CANDIDATES) { $env:NETBOT_ROUTER_CANDIDATES -split '\s+' } else { @((Get-NbGateway), '192.168.1.1', '10.0.0.1', '192.168.0.1', 'myrouter.local') }
  foreach ($h in $cands) {
    if (-not $h) { continue }
    $res = Invoke-NbJnap $h 'core/GetDeviceInfo'
    if ($res -eq 'OK') { $r.Host = $h; Write-NbOk ($MSG.ROUTER_FOUND -f $h); break }
    Write-NbLine ('  - {0}: {1}' -f $h, $(if ($res -eq 'NOT_JSON') { $MSG.ROUTER_NOT_SUPPORTED } else { $res }))
  }
  if (-not $r.Host -and -not $Gui) {
    $m = Read-NbAnswer ('  ' + $MSG.ROUTER_TYPE_TEXT) ''
    if ($m -and (Invoke-NbJnap $m 'core/GetDeviceInfo') -eq 'OK') { $r.Host = $m; Write-NbOk ($MSG.ROUTER_FOUND -f $m) }
  }
  if (-not $r.Host) { Write-NbWarn ($MSG.ROUTER_NO_ANSWER -f ($cands -join ', ')); return $r }

  # password: only if the router needs one for client details
  if ((Invoke-NbJnap $r.Host 'networkconnections/GetNetworkConnections') -eq 'OK') { Write-NbOk $MSG.ROUTER_NO_PW_NEEDED; return $r }
  $ownMarker = Join-Path $State 'credential_created'
  if (Test-NbCredential $NbCredTarget) {
    $r.UsePw = $true
    if (Test-Path -LiteralPath $ownMarker) { Write-NbOk $MSG.ROUTER_PW_SAVED } else { Write-NbOk $MSG.ROUTER_PW_KEPT }   # someone else's: use, never replace
    return $r
  }
  $routerHost = $r.Host
  $save = {
    param([System.Security.SecureString] $Secure)
    if ((Invoke-NbJnap $routerHost 'networkconnections/GetNetworkConnections' (Get-NbJnapAuth $NbCredUser $Secure)) -ne 'OK') { return $MSG.D4_ERR_REJECTED }
    $rc = Set-NbCredential $NbCredTarget $NbCredUser $Secure
    if ($rc -ne 0) { return ($MSG.D4_ERR_SAVE -f $rc) }
    Set-Content -LiteralPath $ownMarker -Value 'netbot' -Encoding ASCII
    return $null
  }
  if ($Gui) {
    [void](Show-NbScreen 'RouterPassword' -OnSave $save)
  } elseif (Confirm-Nb ('  ' + $MSG.ROUTER_PW_ASK) $true) {
    $a = Read-NbSecret $MSG.ROUTER_PW_TYPE; $b = if ($null -ne $a) { Read-NbSecret $MSG.ROUTER_PW_TYPE_AGAIN } else { $null }
    if ($null -eq $a -or $null -eq $b) { }                                       # no console (NETBOT_NONINTERACTIVE): skipped
    elseif (-not (Test-NbSecretEqual $a $b)) { Write-NbWarn $MSG.ROUTER_PW_MISMATCH }
    else { $err = & $save $a; if ($err) { Write-NbWarn ($err -replace '^\W+\s*', '') } }
    if ($a) { $a.Dispose() }; if ($b) { $b.Dispose() }
  }
  if (Test-Path -LiteralPath $ownMarker) { $r.UsePw = $true; Write-NbOk $MSG.ROUTER_PW_SAVED } else { Write-NbOk $MSG.ROUTER_PW_SKIPPED }
  return $r
}

function Invoke-NbFirstReading([string] $Py, [string] $NbHome) {
  $old = @{ C = $env:NETBOT_CONFIG; F = $env:NETBOT_FORCE_DASHBOARD }
  $env:NETBOT_CONFIG = Join-Path $NbHome 'config.toml'; $env:NETBOT_FORCE_DASHBOARD = '1'
  Push-Location (Join-Path $NbHome 'netbot')
  try { return ((Invoke-NbPython $Py @('collect.py')) -eq 0) }
  finally { Pop-Location; $env:NETBOT_CONFIG = $old.C; $env:NETBOT_FORCE_DASHBOARD = $old.F }
}

function Invoke-NbInstall {
  $NbHome = Get-NbHome
  $State = Join-Path $NbHome '.netbot-state'      # what this installer created, so uninstall removes only that
  $Gui = (Test-NbInteractive) -and (Test-NbWindows) -and -not $env:NETBOT_NO_GUI
  $script:NbStepNum = 0; $script:NbStepTotal = 9
  $rerun = Test-Path -LiteralPath (Join-Path $State 'installed')
  New-Item -ItemType Directory -Force -Path $NbHome, $State | Out-Null
  $script:NbLog = Join-Path $NbHome 'install.log'
  Write-NbLine ("=== NetBot install " + (Get-Date).ToString('s'))
  Write-NbSay $MSG.INSTALL_BANNER
  if ($rerun) { Write-NbLine ('  ' + $MSG.INSTALL_RERUN) }
  $routerOn = $false
  try {
    if ($Gui) { Initialize-NbDialogs ([IO.Path]::Combine($NbSrc, 'netbot', 'theme', 'tokens.css')) }

    # ------------------------------------------------------------ 1. checks
    Write-NbStep $MSG.STEP_CHECKS
    if (-not (Test-NbWindows) -and -not $env:NETBOT_ALLOW_NON_WINDOWS) { Stop-Nb $MSG.ERR_NOT_WINDOWS }
    $psv = Get-NbPowerShellVersion
    if ($psv -lt [version]'5.1') { Stop-Nb $MSG.ERR_OLD_POWERSHELL }
    Write-NbOk ($MSG.OK_POWERSHELL -f $psv)
    $py = Find-NbPython
    if (-not $py) { Write-NbLine ('  ' + $MSG.ERR_NO_PYTHON_2); Stop-Nb $MSG.ERR_NO_PYTHON }
    Write-NbOk ($MSG.OK_PYTHON -f $py.Version)
    # Dish pin, data keys and address come from the one constants file (the only file that names the library).
    $kj = Get-NbPythonOutput $py.Exe @(([IO.Path]::Combine($NbSrc, 'netbot', 'dish_constants.py')), '--json')
    if (-not $kj) { Stop-Nb $MSG.ERR_CONSTANTS }
    $K = $kj | ConvertFrom-Json
    $libUrl = if ($env:NETBOT_DISH_LIB_URL) { $env:NETBOT_DISH_LIB_URL } else { $K.DISH_LIB_URL }          # overrides: offline tests only
    $libSha = if ($env:NETBOT_DISH_LIB_SHA256) { $env:NETBOT_DISH_LIB_SHA256 } else { $K.DISH_LIB_SHA256 }
    $dishHost = if ($env:NETBOT_DISH_HOST) { $env:NETBOT_DISH_HOST } else { $K.DISH_DEFAULT_HOST }
    $dishPort = if ($env:NETBOT_DISH_PORT) { [int]$env:NETBOT_DISH_PORT } else { [int]$K.DISH_PORT }
    foreach ($d in 'data', 'logs', 'dashboard') { New-Item -ItemType Directory -Force -Path (Join-Path $NbHome $d) | Out-Null }

    # ------------------------------------------------------------ 2. dish library (pinned + sha256, never bundled)
    $short = $K.DISH_LIB_COMMIT.Substring(0, 10)
    Write-NbStep ($MSG.STEP_TOOLS -f $short)
    $tools = Join-Path $NbHome $K.DISH_LIB_DIR
    $ld = [string]$K.DISH_LIB_LEGACY_DIR                              # git checkout made by NetBot 0.1-0.3
    if ($ld -match '^[\w.\-]+$' -and $ld -notin @('.', '..')) { Remove-NbPath @((Join-Path $NbHome $ld)) -Root $NbHome }
    $mark = Join-Path $tools '.netbot-sha256'
    if ((Test-Path -LiteralPath $mark) -and ((Get-Content -LiteralPath $mark -Raw).Trim() -eq $libSha) -and (Test-Path -LiteralPath (Join-Path $tools ($K.DISH_LIB_MODULE + '.py')))) {
      Write-NbOk $MSG.OK_TOOLS_REUSED
    } else {
      $tgz = "$tools.tar.gz"; $new = "$tools.new"
      Remove-NbPath @($tools, $new, $tgz) -Root $NbHome                 # a half-finished earlier download
      try { Invoke-NbDownload $libUrl $tgz } catch { Remove-NbPath @($tgz) -Root $NbHome; Stop-Nb $MSG.ERR_CLONE }
      # the exact bytes are checked against the pinned sha256 before anything is unpacked (and again by verify_unpack.py)
      if ((Get-NbSha256 $tgz) -ne $libSha.ToLowerInvariant()) { Remove-NbPath @($tgz) -Root $NbHome; Stop-Nb $MSG.ERR_PIN }
      if ((Invoke-NbPython $py.Exe @(([IO.Path]::Combine($NbSrc, 'lib', 'verify_unpack.py')), $tgz, $libSha, $new, $K.DISH_LIB_MODULE)) -ne 0) {
        Remove-NbPath @($tgz, $new) -Root $NbHome; Stop-Nb $MSG.ERR_PIN }
      Write-NbUtf8 (Join-Path $new '.netbot-sha256') ($libSha + "`n")
      Remove-NbPath @($tgz) -Root $NbHome; Move-Item -LiteralPath $new -Destination $tools
    }
    Write-NbOk ($MSG.OK_PIN -f $short, $libSha.Substring(0, 12))

    # ------------------------------------------------------------ 3. venv + code
    Write-NbStep $MSG.STEP_VENV
    $venv = Join-Path $NbHome 'venv'; $vpy = Get-NbVenvPython $venv
    if ((Test-Path -LiteralPath $vpy) -and ((Invoke-NbPython $vpy @('-c', 'import sys')) -eq 0)) { Write-NbOk $MSG.OK_VENV_REUSED }
    else {
      Remove-NbPath @($venv) -Root $NbHome
      if ((Invoke-NbPython $py.Exe @('-m', 'venv', $venv)) -ne 0) { Stop-Nb $MSG.ERR_VENV }
      $vpy = Get-NbVenvPython $venv
    }
    if (-not $env:NETBOT_SKIP_PIP_UPGRADE) {
      if ((Invoke-NbPython $vpy @('-m', 'pip', 'install', '--quiet', '--disable-pip-version-check', '--upgrade', 'pip')) -ne 0) { Stop-Nb $MSG.ERR_PIP } }
    $extra = if ($null -ne $env:NETBOT_PIP_EXTRA) { @($env:NETBOT_PIP_EXTRA -split '\s+' | Where-Object { $_ }) } else { @('matplotlib') }
    if ((Invoke-NbPython $vpy (@('-m', 'pip', 'install', '--quiet', '--disable-pip-version-check', '-r', (Join-Path $tools 'requirements.txt')) + $extra)) -ne 0) { Stop-Nb $MSG.ERR_PIP }
    $code = Join-Path $NbHome 'netbot'
    Remove-NbPath @("$code.new") -Root $NbHome; Copy-Item -LiteralPath (Join-Path $NbSrc 'netbot') -Destination "$code.new" -Recurse
    Remove-NbPath @((Join-Path "$code.new" '__pycache__'), $code) -Root $NbHome; Move-Item -LiteralPath "$code.new" -Destination $code
    Write-NbOk ($MSG.OK_VENV -f $venv)
    # one-time rewrite of key names used by older versions (config, history, synced copy); a no-op afterwards
    if ((Invoke-NbPython $py.Exe @((Join-Path $code 'migrate_legacy.py'), $NbHome)) -ne 0) { Stop-Nb $MSG.ERR_MIGRATE }

    # ------------------------------------------------------------ 4. dish
    Write-NbStep ($MSG.STEP_DISH -f $dishHost)
    $dishFound = Test-NbTcp $dishHost $dishPort
    if ($dishFound) { Write-NbOk $MSG.OK_DISH } else { Write-NbWarn ($MSG.WARN_DISH_1 -f $dishHost, $dishPort); Write-NbWarn $MSG.WARN_DISH_2 }
    if ($Gui) { [void](Show-NbScreen 'DishMonitoring' @{ Address = $dishHost; Found = $dishFound }) }

    # ------------------------------------------------------------ 5. sync folder (console question)
    Write-NbStep $MSG.STEP_SYNC
    $syncDir = ''
    $roots = Get-NbCloudRoots
    if ($roots.Count -gt 0) {
      Write-NbLine ('  ' + $MSG.SYNC_PROMPT)
      for ($i = 0; $i -lt $roots.Count; $i++) { Write-NbLine ('  {0}) {1}' -f ($i + 1), (Split-Path -Leaf $roots[$i])) }
      Write-NbLine ('  0) ' + $MSG.SYNC_LOCAL_ONLY)
      $pick = Read-NbAnswer ('  ' + $MSG.SYNC_PICK) '0'
      $n = 0
      if ([int]::TryParse($pick, [ref]$n) -and $n -ge 1 -and $n -le $roots.Count) { $syncDir = Join-Path $roots[$n - 1] 'NetBot' }
    }
    if ($syncDir) {
      if (-not (Test-Path -LiteralPath $syncDir)) {
        New-Item -ItemType Directory -Force -Path $syncDir | Out-Null
        Add-Content -LiteralPath (Join-Path $State 'sync_dirs_created') -Value $syncDir -Encoding UTF8
      }
      Write-NbOk ($MSG.OK_SYNC -f $syncDir)
    } else { Write-NbOk $MSG.OK_LOCAL }

    # ------------------------------------------------------------ 6. router add-on (optional)
    Write-NbStep $MSG.STEP_ROUTER
    $router = Invoke-NbRouterSetup $Gui $State
    $routerOn = [bool]$router.Host

    # ------------------------------------------------------------ 7. config + Task Scheduler
    Write-NbStep $MSG.STEP_SCHEDULE
    $cfg = @"
# Written by install.ps1. No secrets in this file.
[paths]
data_dir = "$(ConvertTo-NbTomlPath (Join-Path $NbHome 'data'))"
sync_dir = "$(ConvertTo-NbTomlPath $syncDir)"
$($K.DISH_PATHS_KEY) = "$(ConvertTo-NbTomlPath $tools)"

# The dish monitor is always on (it is NetBot's core); this section only says where the dish is.
[$($K.DISH_CFG_SECTION)]
target = "${dishHost}:$dishPort"

[router]
enabled = $(if ($routerOn) { 'true' } else { 'false' })
host = "$($router.Host)"
username = "$NbCredUser"
use_password = $(if ($router.UsePw) { 'true' } else { 'false' })
keychain_service = "$NbCredTarget"

[alerts]
quiet_start = 22
quiet_end = 6
"@
    $cfgPath = Join-Path $NbHome 'config.toml'
    Write-NbUtf8 "$cfgPath.new" (($cfg -replace "`r`n", "`n") + "`n")
    Move-Item -LiteralPath "$cfgPath.new" -Destination $cfgPath -Force
    Write-NbOk ($MSG.OK_CONFIG -f $cfgPath)
    try {
      if (Test-NbTask $NbTaskName) { Unregister-NbTask $NbTaskName }      # re-run: replace the old task
      Register-NbTask $NbTaskName (Get-NbVenvPython $venv -NoWindow) (Join-Path $code 'win_task.pyw') $code $MSG.PRODUCT_TITLE | Out-Null
    } catch { Write-NbLine ('    ' + $_.Exception.Message); Stop-Nb $MSG.ERR_SCHEDULE }
    if (-not (Test-NbTask $NbTaskName)) { Stop-Nb $MSG.ERR_SCHEDULE }
    Set-Content -LiteralPath (Join-Path $State 'task') -Value $NbTaskName -Encoding ASCII
    Write-NbOk ($MSG.OK_SCHEDULED -f $NbTaskName)

    # ------------------------------------------------------------ 8. first reading + dashboard
    Write-NbStep $MSG.STEP_FIRST
    $dash = [IO.Path]::Combine($NbHome, 'dashboard', 'index.html')
    if (Invoke-NbFirstReading $vpy $NbHome) { Write-NbOk ($MSG.OK_DASHBOARD -f $dash) }
    else { Write-NbWarn ($MSG.WARN_FIRST -f (Join-Path $NbHome 'logs')) }

    # ------------------------------------------------------------ 9. sleep (optional, console question)
    Write-NbStep $MSG.STEP_SLEEP
    $sleepFile = Join-Path $State 'sleep_before'
    if (Test-Path -LiteralPath $sleepFile) { Write-NbOk ($MSG.OK_SLEEP -f (Get-Content -LiteralPath $sleepFile -Raw).Trim()) }   # changed on an earlier run
    elseif (Confirm-Nb ('  ' + $MSG.SLEEP_ASK) $false) {
      $before = Get-NbSleepMinutes
      if ($null -ne $before -and (Set-NbSleepMinutes 0)) {
        Set-Content -LiteralPath $sleepFile -Value $before -Encoding ASCII; Write-NbOk ($MSG.OK_SLEEP -f $before)
      } else { Write-NbWarn $MSG.WARN_SLEEP }
    } else { Write-NbOk $MSG.OK_UNCHANGED }

    Set-Content -LiteralPath (Join-Path $State 'installed') -Value (Get-Date).ToString('s') -Encoding ASCII
    Write-NbSay $MSG.INSTALL_DONE
    Write-NbLine ($MSG.FULL_LOG -f $script:NbLog)
    if ($Gui -and (Show-NbScreen 'Success' @{ RouterOn = $routerOn }).Button -eq 'primary') { Open-NbFile $dash }
    if ($Launcher) { Write-NbLine $MSG.LAUNCH_DONE_CLOSING }
    return 0
  } catch {
    $mine = [bool]$_.Exception.Data['NetBot']
    Write-NbLine ''
    Write-NbErr $(if ($mine) { $_.Exception.Message } else { "$($_.Exception.Message) ($($_.InvocationInfo.PositionMessage -split "`n" | Select-Object -First 1))" })
    Write-NbErr ($MSG.INSTALL_FAILED -f $script:NbStepNum, $(if ($script:NbStepName) { $script:NbStepName } else { 'start' }))
    Write-NbLine ('  ' + $MSG.INSTALL_FAILED_HINT)
    Write-NbLine ('  ' + ($MSG.FULL_LOG -f $script:NbLog))
    if ($Gui) { try { [void](Show-NbScreen 'Error' @{ Body = $(if ($mine) { $_.Exception.Message } else { $MSG.D6_BODY }); LogPath = $script:NbLog }) } catch { } }
    if ($Launcher) { Write-NbLine ''; Write-NbLine $MSG.LAUNCH_FAILED }
    return 1
  }
}

if ($MyInvocation.InvocationName -ne '.') { $r = @(Invoke-NbInstall); exit $(if ($r.Count) { [int]$r[-1] } else { 1 }) }    # dot-sourced by the Pester tests: functions only
