<#
  Helpers for install.ps1 and uninstall.ps1 (Windows). Dot-sourced; defines functions only.
  Every call that touches the system (Task Scheduler, Credential Manager, downloads, hashes, the network,
  Python, power settings, console input) goes through one small Nb* function here, so the Pester tests in
  tests/windows/ can replace exactly those with mocks.
#>

# ---------------------------------------------------------------- console output and steps
$script:NbStepNum = 0; $script:NbStepName = ''; $script:NbStepTotal = 0; $script:NbLog = $null
function Write-NbLine([string] $Text) {     # console + install log (the log never receives secrets: none pass through here)
  Write-Host $Text
  if ($script:NbLog) { try { [IO.File]::AppendAllText($script:NbLog, $Text + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding $false)) } catch { } }
}
function Write-NbSay([string] $Text) { Write-NbLine ''; Write-NbLine $Text }
function Write-NbOk([string] $Text) { Write-NbLine ($MSG.OK_PREFIX + $Text) }
function Write-NbWarn([string] $Text) { Write-NbLine ($MSG.WARN_PREFIX + $Text) }
function Write-NbErr([string] $Text) { Write-NbLine ($MSG.ERR_PREFIX + $Text) }
function Write-NbStep([string] $Title) {
  $script:NbStepNum++; $script:NbStepName = $Title
  Write-NbLine ''; Write-NbLine ($MSG.STEP_FMT -f $script:NbStepNum, $script:NbStepTotal, $Title)
}
# A failure the person can act on: the message is shown in the console and in the error dialog.
function Stop-Nb([string] $Text) { $e = New-Object System.Exception $Text; $e.Data['NetBot'] = $true; throw $e }

# ---------------------------------------------------------------- answers (console; the dialogs live in dialogs.ps1)
function Test-NbInteractive { return -not $env:NETBOT_NONINTERACTIVE }
# With NETBOT_NONINTERACTIVE set, nothing reads the console (no Read-Host, no stdin): each question takes the next
# line of NETBOT_ANSWERS (newline-separated, consumed in order; the tests set it), or its default when none is left.
function Read-NbAnswer([string] $Prompt, [string] $Default = '') {
  if (-not (Test-NbInteractive)) {
    $a = $null
    if ($env:NETBOT_ANSWERS) {
      $q = @($env:NETBOT_ANSWERS -split "`r?`n")
      $a = $q[0]; $env:NETBOT_ANSWERS = ($q | Select-Object -Skip 1) -join "`n"
    }
    Write-NbLine ("$Prompt " + $(if ($null -eq $a -or $a -eq '') { "[$Default]" } else { $a }))
  } else { $a = Read-Host $Prompt }
  if ($null -eq $a -or $a -eq '') { return $Default }
  return $a.Trim()
}
function Confirm-Nb([string] $Prompt, [bool] $Default) {
  $a = Read-NbAnswer "$Prompt $($MSG.YES_NO)" ($(if ($Default) { 'y' } else { 'n' }))
  return $a -match '^(y|yes)$'
}
function Read-NbSecret([string] $Prompt) {             # SecureString, never echoed; $null without a console
  if (-not (Test-NbInteractive)) { return $null }
  return (Read-Host -AsSecureString $Prompt)
}

# ---------------------------------------------------------------- platform
function Test-NbWindows { return ($PSVersionTable.PSEdition -eq 'Desktop') -or $IsWindows }
function Get-NbPowerShellVersion { return $PSVersionTable.PSVersion }

# -> path of a python.exe that is 3.9 or newer, or $null. The Microsoft Store placeholder python.exe (which
#    opens the Store instead of running) fails the version check and is skipped.
function Find-NbPython {
  $cands = @()
  if ($env:NETBOT_PYTHON) { $cands += , @($env:NETBOT_PYTHON) }
  $cands += , @('py', '-3'); $cands += , @('python'); $cands += , @('python3')
  foreach ($c in $cands) {
    $exe = Get-Command $c[0] -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $exe) { continue }
    $pre = @($c | Select-Object -Skip 1)
    try {
      $out = & $exe.Source @pre -c 'import sys; print(sys.executable); print("%d.%d.%d" % sys.version_info[:3]); sys.exit(0 if sys.version_info >= (3, 9) else 1)' 2>$null
      if ($LASTEXITCODE -eq 0 -and $out.Count -ge 2) { return @{ Exe = [string]$out[0]; Version = [string]$out[1] } }
    } catch { }
  }
  return $null
}
# Runs python with arguments; output goes to the console and the log. -> exit code
function Invoke-NbPython([string] $Exe, [string[]] $Arguments) {
  $eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'    # Python writes warnings to stderr; only the exit code counts
  try { & $Exe @Arguments 2>&1 | ForEach-Object { Write-NbLine "    $_" } } finally { $ErrorActionPreference = $eap }
  return $LASTEXITCODE
}
function Get-NbPythonOutput([string] $Exe, [string[]] $Arguments) {
  $out = & $Exe @Arguments 2>$null
  if ($LASTEXITCODE -ne 0) { return $null }
  return ($out -join "`n")
}
function Get-NbVenvPython([string] $Venv, [switch] $NoWindow) {
  $win = [IO.Path]::Combine($Venv, 'Scripts', $(if ($NoWindow) { 'pythonw.exe' } else { 'python.exe' }))
  if ((Test-NbWindows) -or (Test-Path -LiteralPath $win)) { return $win }
  return (Join-Path $Venv 'bin/python')    # only for the offline tests on a non-Windows box
}

# ---------------------------------------------------------------- downloads and hashes
function Invoke-NbDownload([string] $Url, [string] $OutFile) {
  $ProgressPreference = 'SilentlyContinue'
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
  Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing -TimeoutSec 120
}
function Get-NbSha256([string] $Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }

# ---------------------------------------------------------------- network
function Test-NbTcp([string] $HostName, [int] $Port, [int] $TimeoutMs = 3000) {
  $c = [Net.Sockets.TcpClient]::new()
  try { $t = $c.ConnectAsync($HostName, $Port); return ($t.Wait($TimeoutMs) -and $c.Connected) } catch { return $false } finally { $c.Dispose() }
}
function Get-NbGateway {
  try {
    $r = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop | Sort-Object RouteMetric | Select-Object -First 1
    if ($r -and $r.NextHop -ne '0.0.0.0') { return $r.NextHop }
  } catch { }
  return $null
}
# One read-only JNAP call (the same Get* calls netbot/linksys_jnap.py makes). -> result string: OK, an error name, or NOT_JSON
function Invoke-NbJnap([string] $RouterHost, [string] $Action, [string] $Auth = '') {
  $h = @{ 'X-JNAP-Action' = "http://linksys.com/jnap/$Action" }
  if ($Auth) { $h['X-JNAP-Authorization'] = $Auth }
  try {
    $r = Invoke-WebRequest -Uri "http://$RouterHost/JNAP/" -Method Post -Body '{}' -ContentType 'application/json' -Headers $h -UseBasicParsing -TimeoutSec 4
    return [string](($r.Content | ConvertFrom-Json).result)
  } catch [Net.WebException] {
    return 'NOT_JSON'
  } catch {
    return 'NOT_JSON'
  }
}

# ---------------------------------------------------------------- Windows Credential Manager (generic credentials)
$script:NbCredLoaded = $false
function Initialize-NbCred {
  if ($script:NbCredLoaded) { return }
  Add-Type -ErrorAction Stop -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace NetBotCred {
  public static class Native {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct CREDENTIAL {
      public int Flags; public int Type; public string TargetName; public string Comment;
      public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
      public int CredentialBlobSize; public IntPtr CredentialBlob; public int Persist;
      public int AttributeCount; public IntPtr Attributes; public string TargetAlias; public string UserName;
    }
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] public static extern bool CredWriteW(ref CREDENTIAL c, int flags);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] public static extern bool CredReadW(string target, int type, int flags, out IntPtr c);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] public static extern bool CredDeleteW(string target, int type, int flags);
    [DllImport("advapi32.dll")] public static extern void CredFree(IntPtr c);
    public static bool Exists(string target) { IntPtr p; if (!CredReadW(target, 1, 0, out p)) return false; CredFree(p); return true; }
    // The password goes from the SecureString straight into the credential blob; no managed string is made.
    public static int Write(string target, string user, string comment, System.Security.SecureString pw) {
      IntPtr blob = Marshal.SecureStringToGlobalAllocUnicode(pw);
      try {
        CREDENTIAL c = new CREDENTIAL();
        c.Type = 1; c.TargetName = target; c.UserName = user; c.Comment = comment; c.Persist = 2;   // generic, local machine
        c.CredentialBlob = blob; c.CredentialBlobSize = pw.Length * 2;
        return CredWriteW(ref c, 0) ? 0 : Marshal.GetLastWin32Error();
      } finally { Marshal.ZeroFreeGlobalAllocUnicode(blob); }
    }
    public static int Delete(string target) { return CredDeleteW(target, 1, 0) ? 0 : Marshal.GetLastWin32Error(); }
  }
}
'@
  $script:NbCredLoaded = $true
}
function Test-NbCredential([string] $Target) { Initialize-NbCred; return [NetBotCred.Native]::Exists($Target) }
function Set-NbCredential([string] $Target, [string] $User, [System.Security.SecureString] $Password) {
  Initialize-NbCred; return [NetBotCred.Native]::Write($Target, $User, $MSG.CRED_COMMENT, $Password)   # -> 0 or a Windows error code
}
function Remove-NbCredential([string] $Target) { Initialize-NbCred; return ([NetBotCred.Native]::Delete($Target) -eq 0) }
# JNAP auth header for a password check at setup. The plain text exists only inside this function.
function Get-NbJnapAuth([string] $User, [System.Security.SecureString] $Password) {
  $p = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
  try { return 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($User + ':' + [Runtime.InteropServices.Marshal]::PtrToStringBSTR($p))) }
  finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($p) }
}

function Test-NbSecretEqual([System.Security.SecureString] $A, [System.Security.SecureString] $B) {
  $pa = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($A); $pb = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($B)
  try { return ([Runtime.InteropServices.Marshal]::PtrToStringBSTR($pa) -ceq [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pb)) }
  finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pa); [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pb) }
}

# ---------------------------------------------------------------- Task Scheduler (current user, no admin rights)
function Test-NbTask([string] $Name) { return [bool](Get-ScheduledTask -TaskName $Name -TaskPath '\' -ErrorAction SilentlyContinue) }
function Register-NbTask([string] $Name, [string] $PythonW, [string] $Script, [string] $WorkDir, [string] $Description) {
  $action = New-ScheduledTaskAction -Execute $PythonW -Argument ('"' + $Script + '"') -WorkingDirectory $WorkDir
  # every 5 minutes from now on (no end date); also after logon, so a restart picks it up again
  $every = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(1)) -RepetitionInterval (New-TimeSpan -Minutes 5)
  $logon = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
  $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
  $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
  Register-ScheduledTask -TaskName $Name -TaskPath '\' -Action $action -Trigger @($every, $logon) -Settings $settings `
    -Principal $principal -Description $Description -Force -ErrorAction Stop | Out-Null
}
function Unregister-NbTask([string] $Name) {
  Stop-ScheduledTask -TaskName $Name -TaskPath '\' -ErrorAction SilentlyContinue
  Unregister-ScheduledTask -TaskName $Name -TaskPath '\' -Confirm:$false -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------- power (sleep on AC power, current power plan)
# -> minutes before sleep on AC power, 0 = never, or $null if it can't be read
function Get-NbSleepMinutes {
  $out = powercfg /query SCHEME_CURRENT SUB_SLEEP STANDBYIDLE 2>$null
  $m = [regex]::Match(($out -join "`n"), '(?im)^\s*Current AC Power Setting Index:\s*0x([0-9a-f]+)')
  if (-not $m.Success) { return $null }
  return [int]([Convert]::ToInt64($m.Groups[1].Value, 16) / 60)
}
function Set-NbSleepMinutes([int] $Minutes) { powercfg /change standby-timeout-ac $Minutes 2>$null | Out-Null; return ($LASTEXITCODE -eq 0) }

# ---------------------------------------------------------------- files
# ---- guarded delete. Every delete NetBot makes (installer, uninstaller and tests) goes through Remove-NbPath.
# The checks look at the paths themselves. There is no switch, parameter or environment variable that turns
# them off; -DryRun only replaces the delete with a log line, and the checks still run first.
# Allowed roots (-Root):
#   production: the NetBot folder, whose last path segment is exactly 'NetBot'
#   tests:      a folder named nbw-<32 hex digits> directly inside the system temp folder
# A path is deleted only if it is the root itself or inside it. Refused, before anything is deleted:
#   an empty path, a relative path (on Windows also 'C:foo', '\foo' and '\\?\' / '\\.\' device paths),
#   a drive or filesystem root, $HOME / $env:HOME / $env:USERPROFILE /
#   the user-profile folder (or any folder that contains one of them), anything outside the root, a root
#   that is itself a link, and any link (symlink or junction) on the way to a path (a folder between the root and
#   the path) whose target is outside the root. A link that is itself the path or lies inside it is removed as a
#   link entry only (unlinked, whatever it points to); it is never entered and its target is never touched.
# Environment variables can only make this stricter: NETBOT_PROTECT_PATHS (';'-separated) adds protected
# folders (the test runner lists the real home there), and NETBOT_DRY_RUN=1 turns deletes into log lines
# (the console gets one line per path; NETBOT_DRY_RUN_LOG, if set, gets that line plus every file, folder and
# link the delete would remove). Nothing can turn a check off. The guard functions run under
# Set-StrictMode -Version Latest whatever the caller's mode is.
$script:NbDryRun = [bool]$env:NETBOT_DRY_RUN
$script:NbDryRunLog = if ($env:NETBOT_DRY_RUN_LOG) { $env:NETBOT_DRY_RUN_LOG } else { $null }
function Test-NbIsWindowsFs { return [IO.Path]::DirectorySeparatorChar -eq '\' }
function Get-NbPathCmp { if (Test-NbIsWindowsFs) { return [StringComparison]::OrdinalIgnoreCase } return [StringComparison]::Ordinal }
function ConvertTo-NbFullPath([string] $Path) {
  if ([string]::IsNullOrWhiteSpace($Path)) { throw "Remove-NbPath refused: empty path" }
  if (-not [IO.Path]::IsPathRooted($Path)) { throw "Remove-NbPath refused: not an absolute path: '$Path'" }
  if (Test-NbIsWindowsFs) {
    # IsPathRooted is also true for 'C:foo' (relative to C:'s current folder) and '\foo' (the current drive's root),
    # so only 'X:\...' and '\\server\share\...' are accepted; device paths are refused.
    if ($Path -match '^[\\/]{2}[?.][\\/]') { throw "Remove-NbPath refused: device path: '$Path'" }
    if ($Path -notmatch '^([A-Za-z]:[\\/]|[\\/]{2}[^\\/])') { throw "Remove-NbPath refused: not a full path: '$Path'" }
  }
  $full = [IO.Path]::GetFullPath($Path)
  $rootOf = [IO.Path]::GetPathRoot($full)
  $trimmed = $full.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
  if (-not $trimmed -or $full.Length -le $rootOf.Length -or [string]::Equals($trimmed, $rootOf.TrimEnd('\', '/'), (Get-NbPathCmp))) {
    throw "Remove-NbPath refused: '$Path' is a drive or filesystem root"
  }
  return $trimmed
}
# $true if $Child is $Parent or inside it (both already full paths without a trailing separator)
function Test-NbPathWithin([string] $Child, [string] $Parent) {
  $cmp = Get-NbPathCmp
  if ([string]::Equals($Child, $Parent, $cmp)) { return $true }
  $sep = [string][IO.Path]::DirectorySeparatorChar
  return $Child.StartsWith($Parent + $sep, $cmp)
}
# Folders that must never be deleted, nor any folder that contains them.
function Get-NbProtectedPaths {
  $out = @()
  $extra = if ($env:NETBOT_PROTECT_PATHS) { @($env:NETBOT_PROTECT_PATHS -split ';') } else { @() }
  foreach ($c in (@($HOME, $env:HOME, $env:USERPROFILE, [Environment]::GetFolderPath('UserProfile')) + $extra)) {
    if ([string]::IsNullOrWhiteSpace($c)) { continue }
    try { if ([IO.Path]::IsPathRooted($c)) { $out += [IO.Path]::GetFullPath($c).TrimEnd('\', '/') } } catch { }
  }
  return , $out
}
# A path to delete must not be a home folder nor contain one. A root must not be a home folder (it may contain
# one: the test folder holds the tests' own HOME; the paths deleted inside it are still checked one by one).
function Assert-NbNotProtected([string] $Full, [string] $Original, [switch] $ExactOnly) {
  foreach ($h in (Get-NbProtectedPaths)) {
    if (-not $h) { continue }
    if ([string]::Equals($h, $Full, (Get-NbPathCmp))) { throw "Remove-NbPath refused: '$Original' is a home folder ($h)" }
    if (-not $ExactOnly -and (Test-NbPathWithin $h $Full)) { throw "Remove-NbPath refused: '$Original' contains a home folder ($h)" }
  }
}
function Test-NbTestRoot([string] $Full) {
  $tmp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
  $parent = [IO.Path]::GetDirectoryName($Full)
  return ($null -ne $parent) -and [string]::Equals($parent.TrimEnd('\', '/'), $tmp, (Get-NbPathCmp)) -and
         ([IO.Path]::GetFileName($Full) -cmatch '^nbw-[0-9a-f]{32}$')
}
# -> the item at $Full, without following a link at that spot, or $null if nothing is there (a broken link is still found)
function Get-NbItem([string] $Full) { return (Get-Item -LiteralPath $Full -Force -ErrorAction SilentlyContinue) }
function Test-NbIsLink($Item) { return [bool]($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) }
# Full path a link points to, or throws if it can't be read (an unreadable link is refused, never guessed).
function Get-NbLinkTarget($Item) {
  $t = $null
  if ($Item.PSObject.Properties['LinkTarget'] -and $Item.LinkTarget) { $t = [string]$Item.LinkTarget }
  elseif ($Item.PSObject.Properties['Target'] -and $Item.Target) { $t = [string](@($Item.Target)[0]) }
  if ([string]::IsNullOrWhiteSpace($t)) { throw "Remove-NbPath refused: can't read where the link '$($Item.FullName)' points" }
  if ($t.StartsWith('\\?\')) { $t = $t.Substring(4) }
  if (-not [IO.Path]::IsPathRooted($t)) { $t = Join-Path ([IO.Path]::GetDirectoryName($Item.FullName.TrimEnd('\', '/'))) $t }
  return [IO.Path]::GetFullPath($t).TrimEnd('\', '/')
}
function Assert-NbLinkInside($Item, [string] $RootFull) {
  $t = Get-NbLinkTarget $Item
  if (-not (Test-NbPathWithin $t $RootFull)) { throw "Remove-NbPath refused: '$($Item.FullName)' is a link to '$t', outside '$RootFull'" }
}
# Checks every folder between the root and $Full (a link there could lead the delete outside the root).
# Any link there is refused (one pointing outside the root says where it points); a delete never goes through a link.
function Assert-NbAncestorsInside([string] $Full, [string] $RootFull) {
  $cur = [IO.Path]::GetDirectoryName($Full)
  while ($cur -and -not [string]::Equals($cur.TrimEnd('\', '/'), $RootFull, (Get-NbPathCmp)) -and (Test-NbPathWithin $cur.TrimEnd('\', '/') $RootFull)) {
    $it = Get-NbItem $cur
    if ($it -and (Test-NbIsLink $it)) {
      Assert-NbLinkInside $it $RootFull
      throw "Remove-NbPath refused: '$($it.FullName)' on the way to '$Full' is a link"
    }
    $cur = [IO.Path]::GetDirectoryName($cur)
  }
  $rootItem = Get-NbItem $RootFull
  if ($rootItem -and (Test-NbIsLink $rootItem)) { throw "Remove-NbPath refused: the root '$RootFull' is a link" }
}
# 'link', 'dir' or 'file': what kind of item a plan entry is
function Get-NbItemKind($Item) { if (Test-NbIsLink $Item) { return 'link' } if ($Item -is [IO.DirectoryInfo]) { return 'dir' } return 'file' }
# Right before one delete: the item is still there, still the kind that was planned, and every folder from it up
# to the root is still inside the root and not a link. Anything else aborts the whole operation.
function Assert-NbUnchanged($Item, [string] $Kind, [string] $RootFull) {
  $full = $Item.FullName.TrimEnd('\', '/')
  if (-not (Test-NbPathWithin $full $RootFull)) { throw "Remove-NbPath refused: '$full' is no longer inside '$RootFull'" }
  Assert-NbAncestorsInside $full $RootFull
  $now = Get-NbItem $full
  if (-not $now) { throw "Remove-NbPath refused: '$full' changed while deleting (it is gone)" }
  $k = Get-NbItemKind $now
  if ($k -ne $Kind) { throw "Remove-NbPath refused: '$full' changed while deleting (planned $Kind, now $k)" }
  return $now
}
# Called once between planning and deleting. Does nothing; the tests mock it to change the disk at that moment.
function Invoke-NbBeforeDelete { }
# Walks the tree without entering links. Links are planned as link entries (removed, never followed).
function Get-NbDeletePlan($Item, [string] $RootFull) {
  $plan = New-Object System.Collections.Generic.List[object]
  $stack = New-Object System.Collections.Generic.Stack[object]
  $stack.Push(@($Item, $false))
  while ($stack.Count -gt 0) {
    $e = $stack.Pop(); $it = $e[0]; $expanded = $e[1]
    $isLink = Test-NbIsLink $it
    # A link found here is inside the root (the path and every folder above it were checked). It is planned as a
    # link entry only: never entered, and its target (inside or outside the root, e.g. a venv's python3 ->
    # /usr/bin/python3) is never read for the delete nor touched. Remove-NbOneItem unlinks the entry itself.
    if ($it -is [IO.DirectoryInfo] -and -not $isLink -and -not $expanded) {
      $stack.Push(@($it, $true))               # the folder itself comes after its contents
      foreach ($c in @(Get-ChildItem -LiteralPath $it.FullName -Force -ErrorAction Stop)) { $stack.Push(@($c, $false)) }
      continue
    }
    $plan.Add(@($it, (Get-NbItemKind $it)))
  }
  return , $plan
}
function Write-NbDryRun([string] $Text, [switch] $LogOnly) {
  if (-not $LogOnly) { Write-Host $Text }
  if ($script:NbDryRunLog) { [IO.File]::AppendAllText($script:NbDryRunLog, $Text + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding $false)) }
}
function Remove-NbPath {
  param(
    [Parameter(Position = 0)] [AllowNull()] [AllowEmptyString()] [AllowEmptyCollection()] [string[]] $Path,
    [Parameter(Mandatory = $true)] [string] $Root,
    [switch] $DryRun
  )
  Set-StrictMode -Version Latest               # this scope and every guard helper it calls
  $dry = $DryRun.IsPresent -or [bool]$script:NbDryRun
  # 1. the root
  $rootFull = ConvertTo-NbFullPath $Root
  Assert-NbNotProtected $rootFull $Root -ExactOnly
  if (-not ((Split-Path -Leaf $rootFull) -ceq 'NetBot') -and -not (Test-NbTestRoot $rootFull)) {
    throw "Remove-NbPath refused: '$Root' is not an allowed root (a folder named NetBot, or a test folder nbw-<guid> in the temp folder)"
  }
  $rootItem = Get-NbItem $rootFull
  if ($rootItem -and (Test-NbIsLink $rootItem)) { throw "Remove-NbPath refused: the root '$Root' is a link" }
  if ($null -eq $Path -or @($Path).Count -eq 0) { throw "Remove-NbPath refused: empty path" }
  # 2. every path is checked before anything is deleted
  $todo = @()
  foreach ($p in @($Path)) {
    $full = ConvertTo-NbFullPath $p
    Assert-NbNotProtected $full $p
    if (-not (Test-NbPathWithin $full $rootFull)) { throw "Remove-NbPath refused: '$p' is not inside '$rootFull'" }
    Assert-NbAncestorsInside $full $rootFull
    $it = Get-NbItem $full
    if (-not $it) { continue }                  # nothing there: nothing to do
    $todo += , @($full, (Get-NbDeletePlan $it $rootFull))
  }
  # a path inside another path in this call is already covered by that one's plan
  $todo = @($todo | Where-Object { $t = $_; -not @($todo | Where-Object { -not [string]::Equals($_[0], $t[0], (Get-NbPathCmp)) -and (Test-NbPathWithin $t[0] $_[0]) }).Count })
  $seen = @{}
  $todo = @($todo | Where-Object { $k = if (Test-NbIsWindowsFs) { $_[0].ToUpperInvariant() } else { $_[0] }; if ($seen.ContainsKey($k)) { $false } else { $seen[$k] = 1; $true } })
  # 3. delete (or, in a dry run, only list)
  foreach ($t in $todo) {
    if ($dry) {
      $only = if ($t[1].Count -eq 1 -and $t[1][0][1] -eq 'link') { '  (link only)' } else { '' }
      Write-NbDryRun ("DRY RUN would delete: {0}  ({1} items){2}" -f $t[0], $t[1].Count, $only)
      foreach ($e in $t[1]) { Write-NbDryRun ("DRY RUN   item: {0}{1}" -f $e[0].FullName, $(if ($e[1] -eq 'link') { '  (link only)' } else { '' })) -LogOnly }
      continue
    }
  }
  if ($dry) { return }
  Invoke-NbBeforeDelete
  foreach ($t in $todo) {
    foreach ($e in $t[1]) { Remove-NbOneItem (Assert-NbUnchanged $e[0] $e[1] $rootFull) $e[1] }
  }
}
# Deletes one planned item: a file, an already-emptied folder, or a link (the link only, never its target).
function Remove-NbOneItem($Item, [string] $Kind) {
  if ($Kind -eq 'link') {
    if (($Item -is [IO.DirectoryInfo]) -and (Test-NbIsWindowsFs)) { [IO.Directory]::Delete($Item.FullName, $false) }   # junction or folder symlink
    else { [IO.File]::Delete($Item.FullName) }                                                                       # Unix: unlink
    return
  }
  if ($Item.Attributes -band [IO.FileAttributes]::ReadOnly) { $Item.Attributes = $Item.Attributes -bxor [IO.FileAttributes]::ReadOnly }
  if ($Item -is [IO.DirectoryInfo]) { [IO.Directory]::Delete($Item.FullName, $false) }    # never recursive: contents went first
  else { [IO.File]::Delete($Item.FullName) }
}
# ---- end guarded delete
function Write-NbUtf8([string] $Path, [string] $Text) {   # UTF-8 without a byte-order mark (Python's tomllib refuses one)
  [IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding $false))
}
function Open-NbFile([string] $Path, [string] $Argument = '') {
  if ($Argument) { Start-Process -FilePath $Path -ArgumentList ('"' + $Argument + '"') } else { Start-Process -FilePath $Path }
}

# ---------------------------------------------------------------- router add-ons
# Makes NetBot has a router add-on for (matched against what the person types; the add-on reads the router
# with the same read-only calls on every model of that make that answers them).
$script:NbRouterAddons = @(@{ Make = 'linksys'; Kind = 'jnap' })
function Find-NbRouterAddon([string] $Make) {
  if (-not $Make) { return $null }
  foreach ($a in $script:NbRouterAddons) { if ($Make.Trim().ToLowerInvariant().Contains($a.Make)) { return $a } }
  return $null
}
