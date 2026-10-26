# ---------------------------------------------------------------------------
# Resolve the machine-local paths this repo needs, and export them as
# environment variables.
#
# WHY THIS EXISTS
#
# The repo lives on more than one computer. Anything machine-specific (where
# DevEco Studio is installed, where the upstream ReadAny checkout lives, which
# local proxy reaches GitHub) must therefore NOT be hard-coded in the repo.
# It comes from exactly three places, in this order:
#
#   1. the process environment  ($env:DEVECO_HOME, $env:READANY_REF,
#      $env:READANY_PROXY)                     <- one-off override / CI
#   2. AGENTS.local.md in the repo root         <- this machine's truth
#   3. the candidate lists below                <- auto-detect
#
# If none of them answers, this script fails loudly. It must never guess: a
# build that silently uses the wrong SDK produces confusing errors much later.
#
# USAGE
#
#   .\scripts\env.ps1                 # resolve and export into the caller
#   .\scripts\env.ps1 -Print          # same, plus a report
#   .\scripts\env.ps1 -Get DEVECO_HOME  # print one value (exit 2 if unknown)
#
# The exported variables are:
#
#   DEVECO_HOME        DevEco Studio install directory
#   DEVECO_SDK_HOME    <DEVECO_HOME>\sdk
#   READANY_REPO_ROOT  this repository's root (from git, not hard-coded)
#   READANY_REF        upstream ReadAny checkout (may be empty: optional)
#   READANY_PROXY      proxy for GitHub (may be empty: means direct)
#
# ASCII ONLY, deliberately: Windows PowerShell 5.1 reads a UTF-8 file without a
# BOM as ANSI, so non-ASCII text in this file would be garbled by `powershell.exe`
# (which is what build.bat/device.bat call). Keep messages English.
# ---------------------------------------------------------------------------

[CmdletBinding()]
param(
  # Print one resolved value and exit. Used by the .bat wrappers.
  [string] $Get = '',

  # Print the full resolution report.
  [switch] $Print
)

$ErrorActionPreference = 'Stop'

# --- repo root -------------------------------------------------------------
# Ask git rather than hard-coding a path: the same file must work in any clone.
$repoRoot = ''
try {
  $repoRoot = (& git -C $PSScriptRoot rev-parse --show-toplevel 2>$null | Select-Object -First 1)
} catch {
  $repoRoot = ''
}
if ([string]::IsNullOrWhiteSpace($repoRoot)) {
  # Fallback: this script lives in <root>\scripts
  $repoRoot = (Split-Path $PSScriptRoot -Parent)
}
$repoRoot = $repoRoot.Trim()

# --- AGENTS.local.md (optional, never committed) ---------------------------
# Format is deliberately dumb: KEY = value, one per line, '#' starts a comment.
# Anything whose value starts with '<' is a template placeholder and is ignored,
# so copying the example file without filling it in cannot break a build.
$localFile = Join-Path $repoRoot 'AGENTS.local.md'
$local = @{}
if (Test-Path $localFile) {
  foreach ($line in (Get-Content -LiteralPath $localFile -Encoding UTF8)) {
    $trimmed = $line.Trim()
    if ($trimmed.Length -eq 0) { continue }
    if ($trimmed.StartsWith('#')) { continue }
    $eq = $trimmed.IndexOf('=')
    if ($eq -lt 1) { continue }
    $key = $trimmed.Substring(0, $eq).Trim().ToUpperInvariant()
    $value = $trimmed.Substring($eq + 1).Trim()
    if ($value.StartsWith('<')) { continue }   # unfilled placeholder
    if ($value.Length -eq 0) { continue }
    $local[$key] = $value
  }
}

function Get-LocalValue([string] $key) {
  if ($local.ContainsKey($key)) { return [string]$local[$key] }
  return ''
}

# --- candidates ------------------------------------------------------------
# Two machines, two layouts: both are listed here so neither needs a local file
# just to say where DevEco is. Add a line only when a machine installs somewhere
# unusual AND the error message below is not telling enough.
$devecoCandidates = @(
  'D:\Dev\DevEco Studio',
  'D:\DevEco Studio',
  'C:\Program Files\Huawei\DevEco Studio',
  'C:\Program Files\DevEco Studio',
  (Join-Path $env:LOCALAPPDATA 'Huawei\DevEco Studio')
)

$refCandidates = @(
  (Join-Path (Split-Path $repoRoot -Parent) 'ReadAny'),
  'D:\Code\ReadAny',
  (Join-Path $env:USERPROFILE 'Code\ReadAny')
)

function Resolve-DevecoHome {
  if (-not [string]::IsNullOrWhiteSpace($env:DEVECO_HOME)) {
    if (Test-Path (Join-Path $env:DEVECO_HOME 'sdk')) { return $env:DEVECO_HOME }
  }
  $fromFile = Get-LocalValue 'DEVECO_HOME'
  if ($fromFile.Length -gt 0 -and (Test-Path (Join-Path $fromFile 'sdk'))) { return $fromFile }
  foreach ($cand in $devecoCandidates) {
    if ([string]::IsNullOrWhiteSpace($cand)) { continue }
    if (Test-Path (Join-Path $cand 'sdk')) { return $cand }
  }
  return ''
}

function Resolve-RefImpl {
  if (-not [string]::IsNullOrWhiteSpace($env:READANY_REF)) {
    if (Test-Path (Join-Path $env:READANY_REF '.git')) { return $env:READANY_REF }
  }
  $fromFile = Get-LocalValue 'REF_IMPL'
  if ($fromFile.Length -gt 0 -and (Test-Path (Join-Path $fromFile '.git'))) { return $fromFile }
  foreach ($cand in $refCandidates) {
    if ([string]::IsNullOrWhiteSpace($cand)) { continue }
    if (Test-Path (Join-Path $cand '.git')) { return $cand }
  }
  return ''
}

function Resolve-Proxy {
  # No probing: whether a proxy is needed (and on which port) is a per-machine
  # decision this script cannot make. Empty means "try direct".
  if (-not [string]::IsNullOrWhiteSpace($env:READANY_PROXY)) { return $env:READANY_PROXY }
  $fromFile = Get-LocalValue 'PROXY'
  if ($fromFile.Length -gt 0) { return $fromFile }
  return ''
}

$devecoHome = Resolve-DevecoHome
$refImpl = Resolve-RefImpl
$proxy = Resolve-Proxy

# --- -Get mode -------------------------------------------------------------
if ($Get.Length -gt 0) {
  $name = $Get.Trim().ToUpperInvariant()
  switch ($name) {
    'DEVECO_HOME' { if ($devecoHome.Length -gt 0) { Write-Output $devecoHome; exit 0 } }
    'REF_IMPL'    { Write-Output $refImpl; exit 0 }
    'PROXY'       { Write-Output $proxy; exit 0 }
    'WORKSPACE'   { Write-Output $repoRoot; exit 0 }
    default       { }
  }
  # Unresolved: say why on stderr, print nothing on stdout, fail the caller.
  [Console]::Error.WriteLine("[env] cannot resolve '$name'.")
  [Console]::Error.WriteLine("[env] repo root: $repoRoot")
  if ($name -eq 'DEVECO_HOME') {
    [Console]::Error.WriteLine('[env] tried:')
    foreach ($cand in $devecoCandidates) { if ($cand) { [Console]::Error.WriteLine("         $cand") } }
    [Console]::Error.WriteLine('[env] fix one of:')
    [Console]::Error.WriteLine('[env]   1) set the DEVECO_HOME environment variable')
    [Console]::Error.WriteLine("[env]   2) add to $localFile :  DEVECO_HOME = <install dir>")
    [Console]::Error.WriteLine('[env]   3) add the install dir to $devecoCandidates in scripts\env.ps1')
  }
  exit 2
}

# --- export ----------------------------------------------------------------
$env:READANY_REPO_ROOT = $repoRoot
if ($devecoHome.Length -gt 0) {
  $env:DEVECO_HOME = $devecoHome
  $env:DEVECO_SDK_HOME = (Join-Path $devecoHome 'sdk')

  # DevEco ships a JBR but does not put it on PATH; hvigor's packaging step then
  # fails with "spawn java ENOENT" (00308018) *after* a successful compile.
  # Exporting it here makes the documented manual path work too, not just
  # build.bat (which cannot inherit env vars from a child PowerShell).
  $jbr = Join-Path $devecoHome 'jbr'
  if (Test-Path (Join-Path $jbr 'bin\java.exe')) {
    if ([string]::IsNullOrWhiteSpace($env:JAVA_HOME)) { $env:JAVA_HOME = $jbr }
    if (-not ($env:PATH -like "$jbr*")) { $env:PATH = (Join-Path $jbr 'bin') + ';' + $env:PATH }
  }
} else {
  Remove-Item Env:\DEVECO_HOME -ErrorAction SilentlyContinue
  Remove-Item Env:\DEVECO_SDK_HOME -ErrorAction SilentlyContinue
}
if ($refImpl.Length -gt 0) { $env:READANY_REF = $refImpl } else { Remove-Item Env:\READANY_REF -ErrorAction SilentlyContinue }
if ($proxy.Length -gt 0) { $env:READANY_PROXY = $proxy } else { Remove-Item Env:\READANY_PROXY -ErrorAction SilentlyContinue }

# --- report ----------------------------------------------------------------
if ($Print) {
  Write-Output "repo root      : $repoRoot"
  Write-Output "AGENTS.local.md: $(if (Test-Path $localFile) { $localFile } else { '(absent)' })"
  Write-Output "DEVECO_HOME    : $(if ($devecoHome) { $devecoHome } else { '(NOT FOUND)' })"
  Write-Output "DEVECO_SDK_HOME: $(if ($devecoHome) { Join-Path $devecoHome 'sdk' } else { '(NOT FOUND)' })"
  Write-Output "READANY_REF    : $(if ($refImpl) { $refImpl } else { '(absent - optional)' })"
  Write-Output "READANY_PROXY  : $(if ($proxy) { $proxy } else { '(direct)' })"
  Write-Output "JAVA_HOME      : $(if ($env:JAVA_HOME) { $env:JAVA_HOME } else { '(not set)' })"
}

if ($devecoHome.Length -eq 0) {
  [Console]::Error.WriteLine('[env] DEVECO_HOME could not be resolved; build and install will fail.')
  [Console]::Error.WriteLine("[env] add  DEVECO_HOME = <install dir>  to $localFile")
  # Deliberately no `exit` here: this branch is reachable by dot-sourcing
  # (`. .\scripts\env.ps1`), where `exit` would terminate the interactive shell.
  # $ErrorActionPreference is 'Stop', so this is loud and non-zero anyway.
  # The .bat wrappers use -Get, which exits with 2 on failure.
  Write-Error 'DEVECO_HOME could not be resolved.'
  return
}
