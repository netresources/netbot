# Pester tests for the Windows installer and uninstaller (install.ps1, uninstall.ps1).
# They run on any box with PowerShell 7 and Python 3.9+ (no Windows needed): every system call in
# lib/win/common.ps1 is replaced by a mock that keeps state, so "nothing left behind" is checked for real.
#   Task Scheduler    -> $State/tasks/<name>      Credential Manager -> $State/creds/<target>
#   downloads         -> a fake dish-library tarball whose sha256 the installer must check
#   JNAP router       -> answers OK only at the addresses in NETBOT_FAKE_ROUTER
# Run:  pwsh -c 'Import-Module Pester -RequiredVersion 6.2.0; Invoke-Pester tests/windows -Output Detailed'
# The real Windows-only parts (WinForms dialogs, the real Credential Manager, Task Scheduler, powercfg,
# pythonw.exe) are listed in the report and need a Windows 11 machine.
#
# Safety (after a cleanup once deleted a real home folder):
#   - every delete here goes through Remove-NbPath (lib/win/common.ps1) with the test folder as its root:
#     a folder nbw-<guid> in the temp folder. There is no direct Remove-Item -Recurse in this file.
#   - HOME, USERPROFILE and NETBOT_HOME point inside that test folder while the tests run; the real ones are
#     saved, listed in NETBOT_PROTECT_PATHS (so the guard refuses them too) and put back in AfterAll.
#   - strict mode; no variable here uses an automatic-variable name ($HOME, $Host, $Input, $Args, $Error, $PID,
#     $Profile, ...): the test folder is $script:Box.
#   - dry run: NETBOT_DRY_RUN=1 makes every delete (tests, installer, uninstaller) only log what it would
#     delete, to the console and to NETBOT_DRY_RUN_LOG (default: netbot-dryrun-<guid>.log in the temp folder).
#     Tests that check something was deleted then fail; the log is the result.
Set-StrictMode -Version Latest

BeforeAll {
  Set-StrictMode -Version Latest
  # the real values, saved before anything can fail; AfterAll puts them back
  $script:SavedEnv = @{}
  foreach ($v in 'HOME', 'USERPROFILE', 'NETBOT_HOME', 'NETBOT_PROTECT_PATHS', 'NETBOT_DRY_RUN_LOG', 'PIP_NO_INDEX', 'PIP_FIND_LINKS', 'NETBOT_ANSWERS') {
    $script:SavedEnv[$v] = [Environment]::GetEnvironmentVariable($v)
  }
  $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).ProviderPath
  $script:Box = Join-Path ([IO.Path]::GetTempPath()) ("nbw-" + [guid]::NewGuid().ToString('N'))
  $script:State = Join-Path $script:Box 'state'
  $script:DryRun = [bool]$env:NETBOT_DRY_RUN

  # the real home folders stay protected while the tests run
  $protect = @($HOME, $env:HOME, $env:USERPROFILE, [Environment]::GetFolderPath('UserProfile'), $env:NETBOT_PROTECT_PATHS) |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
  $env:NETBOT_PROTECT_PATHS = ($protect -join ';')
  if ($script:DryRun -and -not $env:NETBOT_DRY_RUN_LOG) {
    $env:NETBOT_DRY_RUN_LOG = Join-Path ([IO.Path]::GetTempPath()) ("netbot-dryrun-" + [guid]::NewGuid().ToString('N') + '.log')
  }
  if ($script:DryRun) { Write-Host "DRY RUN: nothing is deleted; the paths are listed in $env:NETBOT_DRY_RUN_LOG" }

  New-Item -ItemType Directory -Force -Path $script:State | Out-Null
  $script:TestHome = Join-Path $script:Box 'home'
  New-Item -ItemType Directory -Force -Path $script:TestHome | Out-Null
  $env:HOME = $script:TestHome
  $env:USERPROFILE = $script:TestHome

  # a fake dish library tarball, laid out like the real one: <name>-<commit>/<module>.py + requirements.txt
  $kj = & python3 (Join-Path $script:Root 'netbot/dish_constants.py') --json | ConvertFrom-Json
  $script:K = $kj
  $top = Join-Path $script:State "fake-dish-lib-$($kj.DISH_LIB_COMMIT)"
  New-Item -ItemType Directory -Force -Path $top | Out-Null
  Copy-Item (Join-Path $script:Root 'tests/fake_dish_lib.py') (Join-Path $top ($kj.DISH_LIB_MODULE + '.py'))
  Set-Content (Join-Path $top 'requirements.txt') '' -Encoding ASCII
  $script:Tgz = Join-Path $script:State 'dishlib.tar.gz'
  & tar -C (Split-Path $top) -czf $script:Tgz (Split-Path -Leaf $top)
  if ($LASTEXITCODE -ne 0) { throw 'could not build the fake dish library tarball' }
  $script:TgzSha = (Get-FileHash -LiteralPath $script:Tgz -Algorithm SHA256).Hash.ToLowerInvariant()

  $env:NETBOT_HOME = Join-Path $script:Box 'NetBot'
  $env:NETBOT_NONINTERACTIVE = '1'
  $env:NETBOT_ALLOW_NON_WINDOWS = '1'
  $env:NETBOT_NO_GUI = '1'
  $env:NETBOT_SKIP_PIP_UPGRADE = '1'
  $env:NETBOT_PIP_EXTRA = ''
  # pip installs only from the local wheel cache (fill it with tests/windows/fetch-wheels.sh); never from PyPI
  $script:WheelDir = if ($env:NETBOT_WHEEL_DIR) { $env:NETBOT_WHEEL_DIR } else { Join-Path $PSScriptRoot 'wheels' }
  $env:PIP_NO_INDEX = '1'
  $env:PIP_FIND_LINKS = $script:WheelDir
  $env:NETBOT_DISH_LIB_URL = 'fake://dish-library'
  $env:NETBOT_DISH_LIB_SHA256 = $script:TgzSha
  $env:NETBOT_DISH_HOST = 'localhost'
  $env:NETBOT_DISH_PORT = '9'                 # nothing answers there, so the dish shows "not reachable yet"
  $env:NETBOT_CLOUD_DIRS = ''
  $env:NETBOT_FAKE_ROUTER = 'router-a'        # the fake router that answers JNAP
  $env:NETBOT_ROUTER_CANDIDATES = 'router-a router-b'
  $env:NETBOT_FAKE_SLEEP = '30'               # minutes before sleep, as powercfg would report
  $env:NETBOT_FAKE_TASK_FAIL = ''
  $env:NETBOT_FAKE_CRED_FAIL = ''
  $env:NETBOT_FAKE_BAD_SHA = ''

  . (Join-Path $script:Root 'strings/messages.ps1')
  . (Join-Path $script:Root 'lib/win/common.ps1')
  . (Join-Path $script:Root 'install.ps1')
  . (Join-Path $script:Root 'uninstall.ps1')

  # the only way this file deletes anything: inside the test folder, through the guard
  function Remove-NbTestPath([string[]] $Path) { Remove-NbPath -Path $Path -Root $script:Box -DryRun:$script:DryRun }
  # Runs the installer or uninstaller with these answers (NETBOT_ANSWERS, read in order; nothing reads stdin)
  # -> the exit code the script would exit with (install.ps1 / uninstall.ps1 end with: $r = @(Invoke-Nb...); exit $r[-1], or 1 if nothing was returned)
  function Invoke-NbTestRun([string] $Command, [string[]] $Answers = @()) {
    $env:NETBOT_ANSWERS = ($Answers -join "`n")
    try { $rc = @(& $Command)[-1] } finally { $env:NETBOT_ANSWERS = '' }
    return [int]$rc
  }

  # ---- mocks (replace exactly the system calls; everything else runs for real)
  function Test-NbWindows { return $true }
  function Find-NbPython { return @{ Exe = 'python3'; Version = (& python3 -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])') } }
  # a real venv in the test folder, made once and reused (system python3 refuses pip installs: PEP 668)
  function Get-NbVenvPython([string] $Venv, [switch] $NoWindow) {
    $v = Join-Path $script:Box 'venv-shared'
    $exe = if ($IsWindows) { [IO.Path]::Combine($v, 'Scripts', 'python.exe') } else { [IO.Path]::Combine($v, 'bin', 'python') }
    if (-not (Test-Path -LiteralPath $exe)) {
      & python3 -m venv $v
      if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $exe)) { throw "could not create the test venv at $v" }
    }
    return $exe
  }
  function Invoke-NbDownload([string] $Url, [string] $OutFile) {
    if ($Url -ne 'fake://dish-library') { throw "unexpected download: $Url" }
    Copy-Item $script:Tgz $OutFile
  }
  function Get-NbSha256([string] $Path) {
    $h = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($env:NETBOT_FAKE_BAD_SHA) { return ('0' * 64) }
    return $h
  }
  function Test-NbTcp([string] $HostName, [int] $Port, [int] $TimeoutMs = 3000) { return $false }
  function Get-NbGateway { return 'router-a' }
  function Invoke-NbJnap([string] $RouterHost, [string] $Action, [string] $Auth = '') {
    if ($RouterHost -ne $env:NETBOT_FAKE_ROUTER) { return 'NOT_JSON' }
    if ($Action -eq 'core/GetDeviceInfo') { return 'OK' }
    if ($Action -eq 'networkconnections/GetNetworkConnections') {
      if ($env:NETBOT_FAKE_ROUTER_NEEDS_PW -and $Auth -notlike 'Basic *') { return 'ErrorUnauthorized' }
      return 'OK'
    }
    return 'NOT_JSON'
  }
  function Test-NbCredential([string] $Target) { return (Test-Path -LiteralPath (Join-Path $script:State "creds/$Target")) }
  function Set-NbCredential([string] $Target, [string] $User, [System.Security.SecureString] $Password) {
    if ($env:NETBOT_FAKE_CRED_FAIL) { return 5 }      # a Windows error code; the password is not stored
    New-Item -ItemType Directory -Force -Path (Join-Path $script:State 'creds') | Out-Null
    Set-Content (Join-Path $script:State "creds/$Target") $User -Encoding ASCII
    return 0
  }
  function Remove-NbCredential([string] $Target) {
    Remove-NbTestPath @((Join-Path $script:State "creds/$Target"))
    return $true
  }
  function Test-NbTask([string] $Name) { return (Test-Path -LiteralPath (Join-Path $script:State "tasks/$Name")) }
  function Register-NbTask([string] $Name, [string] $PythonW, [string] $Script, [string] $WorkDir, [string] $Description) {
    if ($env:NETBOT_FAKE_TASK_FAIL) { throw 'access denied (mock)' }
    New-Item -ItemType Directory -Force -Path (Join-Path $script:State 'tasks') | Out-Null
    Set-Content (Join-Path $script:State "tasks/$Name") "$PythonW|$Script|$WorkDir|$Description" -Encoding ASCII
  }
  function Unregister-NbTask([string] $Name) { Remove-NbTestPath @((Join-Path $script:State "tasks/$Name")) }
  function Get-NbSleepMinutes { if ($env:NETBOT_FAKE_SLEEP -eq '') { return $null } return [int]$env:NETBOT_FAKE_SLEEP }
  function Set-NbSleepMinutes([int] $Minutes) { $env:NETBOT_FAKE_SLEEP = "$Minutes"; return $true }
  function Open-NbFile([string] $Path, [string] $Argument = '') { Set-Content (Join-Path $script:State 'opened') "$Path $Argument" -Encoding ASCII }
  function Invoke-NbFirstReading([string] $Py, [string] $NbHome) {   # the collector needs a dish; record that it was called
    Set-Content (Join-Path $script:State 'first-reading') $NbHome -Encoding ASCII
    New-Item -ItemType Directory -Force -Path (Join-Path $NbHome 'dashboard') | Out-Null
    Set-Content (Join-Path $NbHome 'dashboard/index.html') '<html></html>' -Encoding ASCII
    return $true
  }

  function Reset-NbBox {
    Remove-NbTestPath @($env:NETBOT_HOME, (Join-Path $script:State 'tasks'), (Join-Path $script:State 'creds'))   # missing ones are skipped
    $env:NETBOT_FAKE_ROUTER_NEEDS_PW = ''
    $env:NETBOT_FAKE_TASK_FAIL = ''
    $env:NETBOT_FAKE_CRED_FAIL = ''
    $env:NETBOT_FAKE_BAD_SHA = ''
    $env:NETBOT_FAKE_SLEEP = '30'
  }
  function Read-NbConfig { return (Get-Content -LiteralPath (Join-Path $env:NETBOT_HOME 'config.toml') -Raw -Encoding UTF8) }
  function Assert-NbClean([string] $Where) {
    (Test-Path -LiteralPath $env:NETBOT_HOME) | Should -BeFalse -Because "$Where : NetBot folder removed"
    (Test-NbTask 'io.netbot.collect') | Should -BeFalse -Because "$Where : scheduled task removed"
    (Test-NbCredential 'netbot-linksys') | Should -BeFalse -Because "$Where : credential removed"
  }
}

AfterAll {
  # HOME and USERPROFILE go back first: while they point into the test folder, the guard refuses to delete it.
  # NETBOT_PROTECT_PATHS (the real home folders) stays set until the test folder is gone.
  # If BeforeAll stopped early, whatever exists is cleaned up; nothing is deleted without the guard.
  $saved = Get-Variable -Name SavedEnv -Scope Script -ValueOnly -ErrorAction SilentlyContinue
  try {
    if ($saved) { foreach ($v in 'HOME', 'USERPROFILE', 'NETBOT_HOME') { [Environment]::SetEnvironmentVariable($v, $saved[$v]) } }
    if ($saved -and (Get-Command Remove-NbTestPath -ErrorAction SilentlyContinue)) { Remove-NbTestPath @($script:Box) }
  } finally {
    if ($saved) { foreach ($v in 'NETBOT_PROTECT_PATHS', 'NETBOT_DRY_RUN_LOG', 'PIP_NO_INDEX', 'PIP_FIND_LINKS', 'NETBOT_ANSWERS') { [Environment]::SetEnvironmentVariable($v, $saved[$v]) } }
  }
  foreach ($v in 'NETBOT_NONINTERACTIVE', 'NETBOT_ALLOW_NON_WINDOWS', 'NETBOT_NO_GUI', 'NETBOT_SKIP_PIP_UPGRADE',
                 'NETBOT_PIP_EXTRA', 'NETBOT_DISH_LIB_URL', 'NETBOT_DISH_LIB_SHA256', 'NETBOT_DISH_HOST', 'NETBOT_DISH_PORT',
                 'NETBOT_CLOUD_DIRS', 'NETBOT_FAKE_ROUTER', 'NETBOT_ROUTER_CANDIDATES', 'NETBOT_FAKE_SLEEP', 'NETBOT_FAKE_TASK_FAIL',
                 'NETBOT_FAKE_CRED_FAIL', 'NETBOT_FAKE_BAD_SHA', 'NETBOT_FAKE_ROUTER_NEEDS_PW') { Remove-Item "Env:$v" -ErrorAction SilentlyContinue }
}

Describe 'Remove-NbPath: the guard every delete goes through' {
  BeforeAll {
    Set-StrictMode -Version Latest
    $script:G = Join-Path $script:Box 'guard'
    $script:GRoot = Join-Path $script:G 'NetBot'           # an allowed root: the last segment is NetBot
    $script:Outside = Join-Path $script:G 'outside'        # outside that root (still inside the test folder)
    $script:Escape = Join-Path $script:GRoot 'escape'      # link inside the root -> outside it
    $script:InnerLink = Join-Path $script:GRoot 'inner-link'   # link inside the root -> keep, also inside it
    New-Item -ItemType Directory -Force -Path $script:GRoot, $script:Outside, (Join-Path $script:GRoot 'keep') | Out-Null
    Set-Content (Join-Path $script:Outside 'sentinel.txt') 'must survive' -Encoding ASCII
    Set-Content (Join-Path $script:GRoot 'keep/file.txt') 'kept' -Encoding ASCII
    function New-NbTestLink([string] $LinkPath, [string] $Target) {
      try { New-Item -ItemType SymbolicLink -Path $LinkPath -Target $Target -ErrorAction Stop | Out-Null; return $true } catch { }
      try { New-Item -ItemType Junction -Path $LinkPath -Target $Target -ErrorAction Stop | Out-Null; return $true } catch { }   # Windows without the symlink right
      return $false
    }
    $script:CanLink = (New-NbTestLink $script:Escape $script:Outside) -and (New-NbTestLink $script:InnerLink (Join-Path $script:GRoot 'keep'))
  }

  It 'refuses $HOME, and the HOME and USERPROFILE the tests use, as a path and as a root' {
    { Remove-NbPath @($HOME) -Root $script:Box } | Should -Throw '*refused*'
    { Remove-NbPath @($env:HOME) -Root $script:Box } | Should -Throw '*home folder*'
    { Remove-NbPath @($env:USERPROFILE) -Root $script:Box } | Should -Throw '*home folder*'
    { Remove-NbPath @((Join-Path $HOME 'NetBot')) -Root $HOME } | Should -Throw '*refused*'
    { Remove-NbPath @($HOME) -Root $script:Box -DryRun } | Should -Throw '*refused*'     # a dry run checks too
    (Test-Path -LiteralPath $HOME) | Should -BeTrue
    (Test-Path -LiteralPath $env:HOME) | Should -BeTrue
  }

  It "refuses '/', a drive root, '' and blank paths" {
    { Remove-NbPath @('/') -Root $script:Box } | Should -Throw '*refused*'
    { Remove-NbPath @('') -Root $script:Box } | Should -Throw '*empty path*'
    { Remove-NbPath @('   ') -Root $script:Box } | Should -Throw '*empty path*'
    { Remove-NbPath @() -Root $script:Box } | Should -Throw '*empty path*'
    { Remove-NbPath $null -Root $script:Box } | Should -Throw '*empty path*'
    { Remove-NbPath @((Join-Path $script:Box 'state')) -Root '/' } | Should -Throw '*refused*'
    { Remove-NbPath @((Join-Path $script:Box 'state')) -Root '' } | Should -Throw
    if (Test-NbIsWindowsFs) {
      foreach ($p in 'C:\', 'C:', 'C:foo', '\foo', '\\?\C:\foo', '\\.\C:\foo') { { Remove-NbPath @($p) -Root $script:Box } | Should -Throw '*refused*' }
    }
    (Test-Path -LiteralPath $script:State) | Should -BeTrue
  }

  It 'refuses a relative path, a path outside the root, and a root that is not NetBot or temp/nbw-GUID' {
    { Remove-NbPath @('state') -Root $script:Box } | Should -Throw '*not an absolute path*'
    { Remove-NbPath @((Join-Path $script:GRoot '../outside')) -Root $script:GRoot } | Should -Throw '*not inside*'
    { Remove-NbPath @($script:Outside) -Root $script:GRoot } | Should -Throw '*not inside*'
    { Remove-NbPath @((Join-Path $script:State 'x')) -Root $script:State } | Should -Throw '*not an allowed root*'
    $nested = Join-Path $script:Box ('nbw-' + [guid]::NewGuid().ToString('N'))      # nbw-<guid>, but not in the temp folder
    { Remove-NbPath @((Join-Path $nested 'x')) -Root $nested } | Should -Throw '*not an allowed root*'
    { Remove-NbPath @((Join-Path $script:G 'netbot/x')) -Root (Join-Path $script:G 'netbot') } | Should -Throw '*not an allowed root*'
    (Test-Path (Join-Path $script:Outside 'sentinel.txt')) | Should -BeTrue
  }

  It 'refuses the test folder while HOME points inside it' {
    { Remove-NbPath @($script:Box) -Root $script:Box } | Should -Throw '*contains a home folder*'
    (Test-Path -LiteralPath $script:Box) | Should -BeTrue
  }

  It 'has no -Force, and no environment variable turns a check off' {
    $common = @([System.Management.Automation.PSCmdlet]::CommonParameters) + @([System.Management.Automation.PSCmdlet]::OptionalCommonParameters)
    $own = @((Get-Command Remove-NbPath).Parameters.Keys | Where-Object { $_ -notin $common } | Sort-Object)
    $own | Should -Be @('DryRun', 'Path', 'Root')
    { Remove-NbPath @((Join-Path $script:GRoot 'keep')) -Root $script:GRoot -Force } | Should -Throw
    (Test-Path (Join-Path $script:GRoot 'keep/file.txt')) | Should -BeTrue
    # the guard section reads only these variables; each one can only make it stricter (or a dry run)
    $src = Get-Content -LiteralPath (Join-Path $script:Root 'lib/win/common.ps1') -Raw -Encoding UTF8
    $m = [regex]::Match($src, '(?s)# ---- guarded delete\.(.*?)# ---- end guarded delete')
    $m.Success | Should -BeTrue
    $names = @([regex]::Matches($m.Groups[1].Value, '\$env:(\w+)') | ForEach-Object { $_.Groups[1].Value.ToUpperInvariant() } | Sort-Object -Unique)
    $names | Should -Be @('HOME', 'NETBOT_DRY_RUN', 'NETBOT_DRY_RUN_LOG', 'NETBOT_PROTECT_PATHS', 'USERPROFILE')
    $tries = 'NETBOT_FORCE', 'NETBOT_UNSAFE_DELETE', 'NETBOT_GUARD_OFF', 'NETBOT_NO_GUARD'
    try {
      foreach ($v in $tries) { Set-Item "Env:$v" '1' }
      $env:NETBOT_PROTECT_PATHS = $env:NETBOT_PROTECT_PATHS + ';'      # an empty entry adds nothing and removes nothing
      { Remove-NbPath @($HOME) -Root $script:Box } | Should -Throw '*refused*'
      { Remove-NbPath @($env:HOME) -Root $script:Box } | Should -Throw '*home folder*'
    } finally {
      foreach ($v in $tries) { Remove-Item "Env:$v" -ErrorAction SilentlyContinue }
      $env:NETBOT_PROTECT_PATHS = $env:NETBOT_PROTECT_PATHS.TrimEnd(';')
    }
  }

  It 'every path is checked before anything is deleted: a good path plus one through an outward link deletes nothing' {
    if (-not $script:CanLink) { Set-ItResult -Skipped -Because 'this machine cannot create symlinks or junctions'; return }
    { Remove-NbPath @((Join-Path $script:GRoot 'keep'), (Join-Path $script:Escape 'sentinel.txt')) -Root $script:GRoot } | Should -Throw '*is a link to*'
    (Test-Path (Join-Path $script:GRoot 'keep/file.txt')) | Should -BeTrue
    (Test-Path (Join-Path $script:Outside 'sentinel.txt')) | Should -BeTrue
  }

  It 'aborts when a folder is swapped for an outward link between planning and deleting, and the outside target survives' -Skip:([bool]$env:NETBOT_DRY_RUN) {
    if (-not $script:CanLink) { Set-ItResult -Skipped -Because 'this machine cannot create symlinks or junctions'; return }
    $swap = Join-Path $script:GRoot 'swap'
    New-Item -ItemType Directory -Force -Path (Join-Path $swap 'sub'), (Join-Path $script:Outside 'sub') | Out-Null
    Set-Content (Join-Path $swap 'sub/f.txt') 'inside' -Encoding ASCII
    Set-Content (Join-Path $script:Outside 'sub/f.txt') 'outside, must survive' -Encoding ASCII
    $script:SwapOk = $false
    Mock Invoke-NbBeforeDelete {
      Move-Item -LiteralPath $swap -Destination (Join-Path $script:GRoot 'swap-old')     # moved, not deleted
      $script:SwapOk = New-NbTestLink $swap $script:Outside
    }
    { Remove-NbPath @((Join-Path $swap 'sub')) -Root $script:GRoot } | Should -Throw '*is a link*'
    $script:SwapOk | Should -BeTrue
    (Get-Content (Join-Path $script:Outside 'sub/f.txt') -Raw).Trim() | Should -Be 'outside, must survive'
    (Test-Path (Join-Path $script:GRoot 'swap-old/sub/f.txt')) | Should -BeTrue
  }

  It 'refuses a path reached through a link that points outside the root, and deletes nothing' {
    if (-not $script:CanLink) { Set-ItResult -Skipped -Because 'this machine cannot create symlinks or junctions'; return }
    { Remove-NbPath @((Join-Path $script:Escape 'sentinel.txt')) -Root $script:GRoot } | Should -Throw '*is a link to*'   # a link on the way
    { Remove-NbPath @((Join-Path $script:Escape 'sentinel.txt')) -Root $script:GRoot -DryRun } | Should -Throw '*is a link to*'
    (Test-Path (Join-Path $script:Outside 'sentinel.txt')) | Should -BeTrue
    (Test-Path -LiteralPath $script:Escape) | Should -BeTrue
  }

  It 'a dry run lists an inside link that points outside the root as a link only, and deletes nothing' {
    if (-not $script:CanLink) { Set-ItResult -Skipped -Because 'this machine cannot create symlinks or junctions'; return }
    $out = @(Remove-NbPath @($script:Escape) -Root $script:GRoot -DryRun 6>&1 | ForEach-Object { "$_" })
    ($out -join "`n") | Should -Match ([regex]::Escape("DRY RUN would delete: $script:Escape  (1 items)  (link only)"))
    (Test-Path -LiteralPath $script:Escape) | Should -BeTrue
    (Test-Path (Join-Path $script:Outside 'sentinel.txt')) | Should -BeTrue
  }

  It 'removes an inside link that points outside the root (a venv python3 -> system python) as a link; its target survives' -Skip:([bool]$env:NETBOT_DRY_RUN) {
    if (-not $script:CanLink) { Set-ItResult -Skipped -Because 'this machine cannot create symlinks or junctions'; return }
    # a venv-like folder with a file link to a file outside the root, and a folder link to a folder outside it
    $venv = Join-Path $script:GRoot 'venv-link'
    New-Item -ItemType Directory -Force -Path (Join-Path $venv 'bin') | Out-Null
    $pyTarget = Join-Path $script:Outside 'python3'
    Set-Content $pyTarget 'system python stand-in' -Encoding ASCII
    $pyLink = Join-Path $venv 'bin/python3'
    $fileLinked = $true
    try { New-Item -ItemType SymbolicLink -Path $pyLink -Target $pyTarget -ErrorAction Stop | Out-Null } catch { $fileLinked = $false }
    $dirLinked = New-NbTestLink (Join-Path $venv 'lib-out') $script:Outside
    if (-not ($fileLinked -and $dirLinked)) { Set-ItResult -Skipped -Because 'this machine cannot create a file symlink and a folder link'; return }
    Remove-NbPath @($venv) -Root $script:GRoot
    (Test-Path -LiteralPath $venv) | Should -BeFalse
    (Get-Content -LiteralPath $pyTarget -Raw).Trim() | Should -Be 'system python stand-in'
    (Test-Path (Join-Path $script:Outside 'sentinel.txt')) | Should -BeTrue
    (Test-Path (Join-Path $script:GRoot 'keep/file.txt')) | Should -BeTrue
  }

  It 'a dry run lists what it would delete and deletes nothing' {
    $w = Join-Path $script:GRoot 'work-dry'
    New-Item -ItemType Directory -Force -Path (Join-Path $w 'sub') | Out-Null
    Set-Content (Join-Path $w 'sub/a.txt') 'a' -Encoding ASCII
    $out = @(Remove-NbPath @($w) -Root $script:GRoot -DryRun 6>&1 | ForEach-Object { "$_" })
    ($out -join "`n") | Should -Match ([regex]::Escape("DRY RUN would delete: $w"))
    (Test-Path (Join-Path $w 'sub/a.txt')) | Should -BeTrue
  }

  It 'deletes inside the root, and removes an inside link without touching its target' -Skip:([bool]$env:NETBOT_DRY_RUN) {
    $w = Join-Path $script:GRoot 'work'
    New-Item -ItemType Directory -Force -Path (Join-Path $w 'sub') | Out-Null
    Set-Content (Join-Path $w 'sub/b.txt') 'b' -Encoding ASCII
    Remove-NbPath @($w) -Root $script:GRoot
    (Test-Path -LiteralPath $w) | Should -BeFalse
    Remove-NbPath @((Join-Path $script:GRoot 'not-there')) -Root $script:GRoot      # nothing there: nothing to do
    if ($script:CanLink) {
      Remove-NbPath @($script:InnerLink) -Root $script:GRoot
      (Test-Path -LiteralPath $script:InnerLink) | Should -BeFalse
      (Test-Path (Join-Path $script:GRoot 'keep/file.txt')) | Should -BeTrue
    }
  }

  It 'no file is deleted anywhere except inside the guard (static check of the installer, uninstaller and tests)' {
    $files = @('install.ps1', 'uninstall.ps1') +
             @(Get-ChildItem -LiteralPath (Join-Path $script:Root 'lib/win') -Filter '*.ps1' | ForEach-Object { "lib/win/$($_.Name)" }) +
             @(Get-ChildItem -LiteralPath (Join-Path $script:Root 'tests/windows') -Filter '*.ps1' | ForEach-Object { "tests/windows/$($_.Name)" })
    $del = ('Remove-' + 'Item') + '(?!\s+"Env:)'      # built in two parts so this line does not match itself
    $io = '\[IO\.(File|Directory)\]::' + 'Delete'
    $bad = @()
    foreach ($f in $files) {
      $text = Get-Content -LiteralPath (Join-Path $script:Root $f) -Raw -Encoding UTF8
      if ($f -eq 'lib/win/common.ps1') { $text = [regex]::Replace($text, '(?s)# ---- guarded delete\..*?# ---- end guarded delete', '') }
      $n = 0
      foreach ($line in ($text -split "`n")) {
        $n++
        if ($line.TrimStart().StartsWith('#')) { continue }
        if ($line -match $del -or $line -match $io) { $bad += "${f}: $($line.Trim())" }
      }
    }
    $bad | Should -BeNullOrEmpty
  }
}

Describe 'Windows installer: install, re-install, uninstall' {
  BeforeEach { Reset-NbBox }

  It 'installs with numbered steps, the pinned dish library, the scheduled task and no secrets in config' {
    $rc = Invoke-NbTestRun Invoke-NbInstall @('y', 'linksys', 'x100', 'y', 'n')
    $rc | Should -Be 0
    $log = Get-Content -LiteralPath (Join-Path $env:NETBOT_HOME 'install.log') -Raw
    $log | Should -Match 'Step 1 of 9: Checking this PC'
    $log | Should -Match 'Step 9 of 9'
    $log | Should -Match ("verified \(sha256 " + $script:TgzSha.Substring(0, 12))
    (Test-Path (Join-Path $env:NETBOT_HOME "$($script:K.DISH_LIB_DIR)/$($script:K.DISH_LIB_MODULE).py")) | Should -BeTrue
    (Test-Path (Join-Path $env:NETBOT_HOME "$($script:K.DISH_LIB_DIR).tar.gz")) | Should -BeFalse
    (Test-NbTask 'io.netbot.collect') | Should -BeTrue
    $cfg = Read-NbConfig
    $cfg | Should -Match 'enabled = true'
    $cfg | Should -Match 'host = "router-a"'
    $cfg | Should -Match 'use_password = false'
    $cfg | Should -Match 'keychain_service = "netbot-linksys"'
    $cfg | Should -Not -Match '(?m)^\s*(password|secret)\s*='     # a use_password flag is fine; a stored password is not
    $cfg | Should -Not -Match 'router-secret'
    (Test-Path (Join-Path $script:State 'first-reading')) | Should -BeTrue
  }

  It 're-running reuses the library and the environment and leaves exactly one task' {
    $rc = Invoke-NbTestRun Invoke-NbInstall @('y', 'linksys', 'x100', 'y', 'n')
    $rc = Invoke-NbTestRun Invoke-NbInstall @('y', 'linksys', 'x100', 'y', 'n')
    $rc | Should -Be 0
    $log = Get-Content -LiteralPath (Join-Path $env:NETBOT_HOME 'install.log') -Raw
    $log | Should -Match 'already installed here'
    $log | Should -Match 'already downloaded, reusing it'
    $log | Should -Match 'reusing the existing Python environment'
    @(Get-ChildItem (Join-Path $script:State 'tasks') -File).Count | Should -Be 1
  }

  It 'uninstall deletes the task and program files, and deleting history leaves nothing behind' {
    $rc = Invoke-NbTestRun Invoke-NbInstall @('y', 'linksys', 'x100', 'y', 'n')
    $rc = Invoke-NbTestRun Invoke-NbUninstall @('y')
    $rc | Should -Be 0
    Assert-NbClean 'uninstall'
  }

  It 'uninstall a second time is harmless' {
    $rc = Invoke-NbTestRun Invoke-NbUninstall @('n')
    $rc | Should -Be 0
  }

  It 'keeping history removes the program and the task but leaves the data folder' {
    $rc = Invoke-NbTestRun Invoke-NbInstall @('y', 'linksys', 'x100', 'y', 'n')
    $rc = Invoke-NbTestRun Invoke-NbUninstall @('n')
    (Test-Path (Join-Path $env:NETBOT_HOME 'data')) | Should -BeTrue
    (Test-Path (Join-Path $env:NETBOT_HOME 'venv')) | Should -BeFalse
    (Test-Path (Join-Path $env:NETBOT_HOME 'netbot')) | Should -BeFalse
    (Test-Path (Join-Path $env:NETBOT_HOME 'config.toml')) | Should -BeFalse
    (Test-NbTask 'io.netbot.collect') | Should -BeFalse
    $rc = Invoke-NbTestRun Invoke-NbUninstall @('y')
    Assert-NbClean 'second uninstall'
  }
}

Describe 'Windows installer: router password and Credential Manager' {
  BeforeEach { Reset-NbBox; $env:NETBOT_FAKE_ROUTER_NEEDS_PW = '1' }

  It 'saves the password under netbot-linksys only after the router accepts it, and uninstall removes it' {
    $sec = ConvertTo-SecureString 'router-secret' -AsPlainText -Force
    Mock Read-NbSecret { return $sec }
    $rc = Invoke-NbTestRun Invoke-NbInstall @('y', 'linksys', 'x100', 'y', 'y', 'n')
    $rc | Should -Be 0
    (Read-NbConfig) | Should -Match 'use_password = true'
    (Test-NbCredential 'netbot-linksys') | Should -BeTrue
    (Get-Content (Join-Path $script:State 'creds/netbot-linksys')) | Should -Be 'admin'
    $log = Get-Content -LiteralPath (Join-Path $env:NETBOT_HOME 'install.log') -Raw
    $log | Should -Not -Match 'router-secret'          # the password is never logged
    (Read-NbConfig) | Should -Not -Match 'router-secret'   # nor written to config.toml
    $rc = Invoke-NbTestRun Invoke-NbUninstall @('y')
    Assert-NbClean 'uninstall after password'
  }

  It 'a password that the router rejects is not stored' {
    $sec = ConvertTo-SecureString 'wrong' -AsPlainText -Force
    Mock Read-NbSecret { return $sec }
    Mock Invoke-NbJnap { param($RouterHost, $Action, $Auth) if ($Action -like 'networkconnections/*') { return 'ErrorUnauthorized' } return 'OK' }   # needs a password, rejects this one
    $rc = Invoke-NbTestRun Invoke-NbInstall @('y', 'linksys', 'x100', 'y', 'y', 'n')
    (Read-NbConfig) | Should -Match 'use_password = false'
    (Test-NbCredential 'netbot-linksys') | Should -BeFalse
    (Get-Content (Join-Path $env:NETBOT_HOME 'install.log') -Raw) | Should -Match 'did not accept'
  }

  It 'two different passwords are not stored' {
    $script:SecretQueue = @(
      (ConvertTo-SecureString 'one' -AsPlainText -Force),
      (ConvertTo-SecureString 'two' -AsPlainText -Force))
    $script:i = 0
    Mock Read-NbSecret { $script:i++; return $script:SecretQueue[$script:i - 1] }
    $rc = Invoke-NbTestRun Invoke-NbInstall @('y', 'linksys', 'x100', 'y', 'y', 'n')
    (Test-NbCredential 'netbot-linksys') | Should -BeFalse
    (Get-Content (Join-Path $env:NETBOT_HOME 'install.log') -Raw) | Should -Match 'did not match'
  }

  It 'a credential NetBot did not create is used but never removed' {
    New-Item -ItemType Directory -Force -Path (Join-Path $script:State 'creds') | Out-Null
    Set-Content (Join-Path $script:State 'creds/netbot-linksys') 'someone-else' -Encoding ASCII
    $rc = Invoke-NbTestRun Invoke-NbInstall @('y', 'linksys', 'x100', 'y', 'n')
    (Read-NbConfig) | Should -Match 'use_password = true'
    (Get-Content (Join-Path $env:NETBOT_HOME 'install.log') -Raw) | Should -Match 'already in Windows Credential Manager'
    $rc = Invoke-NbTestRun Invoke-NbUninstall @('y')
    (Test-NbCredential 'netbot-linksys') | Should -BeTrue
    (Test-Path -LiteralPath $env:NETBOT_HOME) | Should -BeFalse
    Remove-NbTestPath @((Join-Path $script:State 'creds/netbot-linksys'))
  }
}

Describe 'Windows installer: failure paths leave nothing half-done' {
  BeforeEach { Reset-NbBox }

  It 'a bad checksum stops the install and unpacks nothing' {
    $env:NETBOT_FAKE_BAD_SHA = '1'
    $rc = Invoke-NbTestRun Invoke-NbInstall @('n')
    $rc | Should -Be 1
    (Get-Content (Join-Path $env:NETBOT_HOME 'install.log') -Raw) | Should -Match 'not the expected version'
    (Test-Path (Join-Path $env:NETBOT_HOME $script:K.DISH_LIB_DIR)) | Should -BeFalse
    (Test-Path (Join-Path $env:NETBOT_HOME "$($script:K.DISH_LIB_DIR).tar.gz")) | Should -BeFalse
    (Test-NbTask 'io.netbot.collect') | Should -BeFalse
  }

  It 'a download failure stops the install' {
    Mock Invoke-NbDownload { throw 'network down' }
    $rc = Invoke-NbTestRun Invoke-NbInstall @('n')
    $rc | Should -Be 1
    (Get-Content (Join-Path $env:NETBOT_HOME 'install.log') -Raw) | Should -Match 'could not download a required component'
  }

  It 'a refused scheduled task stops the install and says so' {
    $env:NETBOT_FAKE_TASK_FAIL = '1'
    $rc = Invoke-NbTestRun Invoke-NbInstall @('n')
    $rc | Should -Be 1
    (Get-Content (Join-Path $env:NETBOT_HOME 'install.log') -Raw) | Should -Match 'permission to create a scheduled task'
    (Test-NbTask 'io.netbot.collect') | Should -BeFalse
  }

  It 'a Credential Manager failure stores nothing' {
    $env:NETBOT_FAKE_ROUTER_NEEDS_PW = '1'
    $env:NETBOT_FAKE_CRED_FAIL = '1'
    $sec = ConvertTo-SecureString 'router-secret' -AsPlainText -Force
    Mock Read-NbSecret { return $sec }
    $rc = Invoke-NbTestRun Invoke-NbInstall @('y', 'linksys', 'x100', 'y', 'y', 'n')
    (Test-NbCredential 'netbot-linksys') | Should -BeFalse
    (Read-NbConfig) | Should -Match 'use_password = false'
    (Get-Content (Join-Path $env:NETBOT_HOME 'install.log') -Raw) | Should -Match 'Nothing was stored'
  }

  It 'skipping the router leaves the add-on off and the install still works' {
    $rc = Invoke-NbTestRun Invoke-NbInstall @('n', 'n')
    $rc | Should -Be 0
    (Read-NbConfig) | Should -Match 'enabled = false'
  }
}

Describe 'Windows installer: each run returns exactly one value (its exit code)' {
  BeforeEach { Reset-NbBox }
  It 'install and uninstall, success and failure' {
    $env:NETBOT_ANSWERS = "y`nlinksys`nx100`ny`nn"
    $out = @(Invoke-NbInstall); $out.Count | Should -Be 1; $out[0] | Should -Be 0
    $env:NETBOT_ANSWERS = 'y'
    $out = @(Invoke-NbUninstall); $out.Count | Should -Be 1; $out[0] | Should -Be 0
    $env:NETBOT_ANSWERS = 'n'
    $out = @(Invoke-NbUninstall); $out.Count | Should -Be 1; $out[0] | Should -Be 0     # nothing installed
    $env:NETBOT_FAKE_BAD_SHA = '1'; $env:NETBOT_ANSWERS = 'n'
    $out = @(Invoke-NbInstall); $out.Count | Should -Be 1; $out[0] | Should -Be 1
    $env:NETBOT_FAKE_BAD_SHA = ''
    $env:NETBOT_FAKE_TASK_FAIL = '1'; $env:NETBOT_ANSWERS = 'n'
    $out = @(Invoke-NbInstall); $out.Count | Should -Be 1; $out[0] | Should -Be 1
    $env:NETBOT_FAKE_TASK_FAIL = ''
    Reset-NbBox                                      # so the library is downloaded again
    Mock Invoke-NbDownload { throw 'network down' }
    $env:NETBOT_ANSWERS = 'n'
    $out = @(Invoke-NbInstall); $out.Count | Should -Be 1; $out[0] | Should -Be 1
    $env:NETBOT_ANSWERS = ''
  }
  It 'uninstall failure returns exactly one value (1)' {   # own It block: the download mock above lasts for its whole It
    $env:NETBOT_ANSWERS = "y`nlinksys`nx100`ny`nn"
    $out = @(Invoke-NbInstall); $out.Count | Should -Be 1; $out[0] | Should -Be 0
    # Throw only for the step-3 program-files call (the only one whose list holds dish-lib.tar.gz).
    # It is not inside the step-4 history try/catch, so it reaches the outer catch: return 1.
    # Pester 6 throws when no filtered mock matches, so an unfiltered fallback sends every other call to the real guard.
    $script:NbRealRemovePath = (Get-Command Remove-NbPath -CommandType Function).ScriptBlock
    Mock Remove-NbPath { & $script:NbRealRemovePath @PesterBoundParameters }
    Mock Remove-NbPath { throw 'refused' } -ParameterFilter { @($Path | Where-Object { $_ -and (Split-Path -Leaf $_) -eq 'dish-lib.tar.gz' }).Count -gt 0 }
    $cfg = Join-Path $env:NETBOT_HOME 'config.toml'
    (Test-Path -LiteralPath $cfg) | Should -BeTrue   # the install created it
    $env:NETBOT_ANSWERS = 'y'
    $out = @(Invoke-NbUninstall); $out.Count | Should -Be 1; $out[0] | Should -Be 1
    Should -Invoke Remove-NbPath -Times 1 -Exactly -ParameterFilter { @($Path | Where-Object { $_ -and (Split-Path -Leaf $_) -eq 'dish-lib.tar.gz' }).Count -gt 0 }
    (Test-Path -LiteralPath $cfg) | Should -BeTrue   # step 3 threw before deleting; step 4 never ran
    $env:NETBOT_ANSWERS = ''
  }
}

Describe 'Windows installer: dialogs and wording' {
  It 'dialog colors are read from the shipped theme tokens' {
    . (Join-Path $script:Root 'lib/win/dialogs.ps1')
    $t = Read-NbTokens (Join-Path $script:Root 'netbot/theme/tokens.css')
    $t.Accent | Should -Be @(61, 242, 111)
    $t.Bg | Should -Be @(6, 8, 11)
    $t.Keys | Should -Contain 'AccentH'
  }
  It 'every dialog string the spec requires is in the strings file' {
    foreach ($s in @('Dish monitoring is on', 'What router do you have?', 'There is an add-on for your router',
                     'NetBot will use dish and network monitoring', 'Router password (optional)', 'NetBot is installed',
                     'NetBot could not finish installing', 'Windows Credential Manager', "I'm not sure", 'Open Dashboard')) {
      ($MSG.Values -join "`n") | Should -Match ([regex]::Escape($s))
    }
  }
  It 'the window title comes from ui_text.py APP_NAME and the banner from PRODUCT_TITLE' {
    $MSG.TITLE | Should -Be 'NetBot'
    $MSG.PRODUCT_TITLE | Should -Be 'NetBot: Connection Monitor'
    $MSG.INSTALL_BANNER | Should -Be 'NetBot: Connection Monitor installer'
  }
  It 'screen specs follow the spec: sizes, buttons, escape targets' {
    . (Join-Path $script:Root 'lib/win/dialogs.ps1')
    (Get-NbScreenSpec 'DishMonitoring' @{ Address = 'x'; Found = $true }).H | Should -Be 245
    (Get-NbScreenSpec 'RouterPassword' @{}).Buttons[1][0] | Should -Be 'Save'
    (Get-NbScreenSpec 'RouterPassword' @{}).Esc | Should -Be 'secondary'
    (Get-NbScreenSpec 'Error' @{ Body = 'short' }).H | Should -Be 228
    (Get-NbScreenSpec 'Success' @{}).Buttons[1][0] | Should -Be 'Open Dashboard'
    (Get-NbScreenSpec 'NoAddon' @{ NotSure = $true }).Body | Should -Be $MSG.D3B_BODY_NOT_SURE
  }
}

Describe 'Windows installer: speed test script' {
  BeforeAll { . (Join-Path $script:Root 'netbot/win_speedtest.ps1') }
  It 'computes download speed from bytes and seconds and rejects a tiny download' {
    function Invoke-NbTimedDownload { param($Url, $TimeoutSec) @{ Bytes = 25000000; Seconds = 2.0 } }
    $r = Measure-NbSpeed -Url 'test'
    $r.down_mbps | Should -Be 100.0
    function Invoke-NbTimedDownload { param($Url, $TimeoutSec) @{ Bytes = 100; Seconds = 1.0 } }
    (Measure-NbSpeed -Url 'test').error | Should -Match 'too small'
  }
  It 'a failed download becomes an error, never a throw' {
    function Invoke-NbTimedDownload { param($Url, $TimeoutSec) throw 'no network' }
    (Measure-NbSpeed -Url 'test').error | Should -Match 'download failed'
  }
}

Describe 'Windows installer: double-click launchers' {
  It 'both launchers close on success and stay open on failure' {
    foreach ($name in @('Install NetBot.cmd', 'Uninstall NetBot.cmd')) {
      $t = Get-Content -LiteralPath (Join-Path $script:Root $name) -Raw
      $t | Should -Match 'if errorlevel 1'
      $t | Should -Match 'pause'
      $t | Should -Match 'timeout /t 3'
      $t | Should -Match 'NETBOT_NO_AUTOCLOSE'
    }
  }
}
