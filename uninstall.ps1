<#
  Removes NetBot from this PC. Please read before running. Easiest: double-click 'Uninstall NetBot.cmd'.
  Or:  powershell -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1
  Removes: the scheduled task, NetBot's program files, the router password in Windows Credential Manager only
  if NetBot saved it, and puts the sleep setting back if NetBot changed it. Asks before deleting your history,
  dashboard and synced copy. Safe to run more than once. Wording lives in strings\messages.ps1.
#>
param(
  [switch] $Launcher,
  [switch] $DryRun        # list the paths that would be deleted instead of deleting them (all checks still run)
)

$NbSrc = $PSScriptRoot
. ([IO.Path]::Combine($NbSrc, 'strings', 'messages.ps1'))
. ([IO.Path]::Combine($NbSrc, 'lib', 'win', 'common.ps1'))
if ($DryRun) { $script:NbDryRun = $true }

$NbTaskName = 'io.netbot.collect'
$NbCredTarget = 'netbot-linksys'

function Get-NbHome { if ($env:NETBOT_HOME) { return $env:NETBOT_HOME } return (Join-Path $env:USERPROFILE 'NetBot') }

function Invoke-NbUninstall {
  $NbHome = Get-NbHome
  $State = Join-Path $NbHome '.netbot-state'
  $script:NbStepNum = 0; $script:NbStepTotal = 4; $script:NbLog = $null     # the log lives in the folder being removed
  try {
    Write-NbSay $MSG.UNINSTALL_BANNER

    # ------------------------------------------------------------ 1. stop the schedule
    Write-NbStep $MSG.UN_STEP_SCHEDULE
    $task = $NbTaskName
    $tf = Join-Path $State 'task'
    if (Test-Path -LiteralPath $tf) { $t = (Get-Content -LiteralPath $tf -Raw).Trim(); if ($t -match '^[\w.\-]+$') { $task = $t } }
    $was = Test-NbTask $task
    if ($was) { Unregister-NbTask $task | Out-Null }
    if (Test-NbTask $task) { Write-NbWarn ($MSG.UN_STILL_SCHEDULED -f $task) }
    elseif ($was) { Write-NbOk $MSG.UN_STOPPED }
    else { Write-NbOk $MSG.UN_NOT_SCHEDULED }

    # ------------------------------------------------------------ 2. Credential Manager (only if NetBot created it)
    Write-NbStep $MSG.UN_STEP_CRED
    $own = Join-Path $State 'credential_created'
    if (Test-Path -LiteralPath $own) {
      if ((Test-NbCredential $NbCredTarget) -and (Remove-NbCredential $NbCredTarget)) { Write-NbOk $MSG.UN_CRED_REMOVED } else { Write-NbOk $MSG.UN_CRED_NONE }
      Remove-NbPath @($own) -Root $NbHome
    } elseif (Test-NbCredential $NbCredTarget) { Write-NbOk $MSG.UN_CRED_KEPT }
    else { Write-NbOk $MSG.UN_CRED_NONE }

    # ------------------------------------------------------------ 3. program files (and the sleep setting, if NetBot changed it)
    Write-NbStep $MSG.UN_STEP_FILES
    $cfg = Join-Path $NbHome 'config.toml'
    $sync = ''
    if (Test-Path -LiteralPath $cfg) {
      $m = [regex]::Match((Get-Content -LiteralPath $cfg -Raw -Encoding UTF8), '(?m)^sync_dir = "(.*)"\s*$')
      if ($m.Success) { $sync = $m.Groups[1].Value -replace '/', '\' }
    }
    $created = @()
    $sf = Join-Path $State 'sync_dirs_created'
    if (Test-Path -LiteralPath $sf) { $created = @(Get-Content -LiteralPath $sf -Encoding UTF8 | Where-Object { $_ }) }
    $sleepFile = Join-Path $State 'sleep_before'
    if (Test-Path -LiteralPath $sleepFile) {
      $before = 0
      if ([int]::TryParse((Get-Content -LiteralPath $sleepFile -Raw).Trim(), [ref]$before) -and (Set-NbSleepMinutes $before)) { Write-NbOk ($MSG.UN_SLEEP_RESTORED -f $before) }
    }
    # Library folder names come from the constants file in this download; the legacy name is skipped if it can't be read.
    $legacy = ''
    $py = Find-NbPython
    $kj = if ($py) { Get-NbPythonOutput $py.Exe @(([IO.Path]::Combine($NbSrc, 'netbot', 'dish_constants.py')), '--json') } else { $null }
    if ($kj) {
      $ld = [string]($kj | ConvertFrom-Json).DISH_LIB_LEGACY_DIR
      if ($ld -match '^[\w.\-]+$' -and $ld -notin @('.', '..')) { $legacy = Join-Path $NbHome $ld }
    }
    if (Test-Path -LiteralPath $NbHome) {
      $paths = @((Join-Path $NbHome 'venv'), (Join-Path $NbHome 'netbot'), (Join-Path $NbHome 'netbot.new'),
        (Join-Path $NbHome 'dish-lib'), (Join-Path $NbHome 'dish-lib.new'), (Join-Path $NbHome 'dish-lib.tar.gz'), $legacy,
        $cfg, "$cfg.new", $State) | Where-Object { $_ }          # the legacy name is '' when unknown; an empty path is refused
      Remove-NbPath @($paths) -Root $NbHome
    }
    Write-NbOk $MSG.UN_PROGRAM_REMOVED

    # ------------------------------------------------------------ 4. history (asks first)
    Write-NbStep $MSG.UN_STEP_HISTORY
    if (-not (Test-Path -LiteralPath $NbHome)) { Write-NbOk ($MSG.UN_DELETED -f $NbHome) }
    elseif (Confirm-Nb ('  ' + ($MSG.UN_DELETE_ASK -f $NbHome)) $false) {
      Remove-NbPath @($NbHome) -Root $NbHome; Write-NbOk ($MSG.UN_DELETED -f $NbHome)
      # synced copy: only a folder named NetBot (the one the installer made inside the chosen cloud folder)
      foreach ($d in @($created + $sync)) {
        if ($d -and (Split-Path -Leaf $d) -ceq 'NetBot' -and (Test-Path -LiteralPath $d)) {
          try { Remove-NbPath @($d) -Root $d; Write-NbOk ($MSG.UN_DELETED -f $d) } catch { Write-NbWarn $_.Exception.Message }   # a refused path is reported, not deleted
        }
      }
      $sync = ''
    } else { Write-NbOk ($MSG.UN_KEPT -f $NbHome) }
    if ($sync -and (Test-Path -LiteralPath $sync)) { Write-NbLine ('  ' + ($MSG.UN_SYNC_KEPT -f $sync)) }
    Write-NbSay $MSG.UN_DONE
    if ($Launcher) { Write-NbLine $MSG.LAUNCH_DONE_CLOSING }
    return 0
  } catch {
    Write-NbErr ($MSG.UN_FAILED -f $_.Exception.Message)
    if ($Launcher) { Write-NbLine ''; Write-NbLine $MSG.LAUNCH_FAILED }
    return 1
  }
}

if ($MyInvocation.InvocationName -ne '.') { $r = @(Invoke-NbUninstall); exit $(if ($r.Count) { [int]$r[-1] } else { 1 }) }
