<#
  NetBot speed test for Windows: times one download of a test file with PowerShell's own web client.
  Nothing is installed. Download speed only (no upload figure). Run by network_checks.py at most once per
  speedtest_every_h hours. Prints one JSON line: {"down_mbps": 123.4, "bytes": 25000000, "seconds": 1.62}
  or {"error": "..."} with exit code 1. The URL comes from config.toml ([network] speedtest_url).
#>
param([string] $Url = '', [int] $TimeoutSec = 90)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'     # the progress bar slows Invoke-WebRequest down a lot on PowerShell 5.1

function Invoke-NbTimedDownload([string] $Url, [int] $TimeoutSec) {
  # -> @{ Bytes; Seconds }. The body is kept in memory only and discarded.
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $r = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec $TimeoutSec -Headers @{ 'Cache-Control' = 'no-cache' }
  $sw.Stop()
  $n = if ($r.RawContentStream) { $r.RawContentStream.Length } else { [int64]$r.RawContentLength }
  return @{ Bytes = [int64]$n; Seconds = $sw.Elapsed.TotalSeconds }
}

function Measure-NbSpeed([string] $Url, [int] $TimeoutSec = 90) {
  try {
    $d = Invoke-NbTimedDownload -Url $Url -TimeoutSec $TimeoutSec
  } catch {
    return @{ error = "download failed: $($_.Exception.GetType().Name)" }
  }
  if ($d.Bytes -lt 1000000 -or $d.Seconds -le 0) { return @{ error = 'download too small to time' } }
  return @{ down_mbps = [Math]::Round($d.Bytes * 8 / $d.Seconds / 1e6, 1); bytes = $d.Bytes; seconds = [Math]::Round($d.Seconds, 2) }
}

if ($MyInvocation.InvocationName -ne '.') {      # dot-sourced by the Pester tests: define functions only
  if (-not $Url) { Write-Output '{"error": "no url"}'; exit 1 }
  $res = Measure-NbSpeed -Url $Url -TimeoutSec $TimeoutSec
  Write-Output ($res | ConvertTo-Json -Compress)
  if ($res.error) { exit 1 }
}
