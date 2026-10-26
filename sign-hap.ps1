# ---------------------------------------------------------------------------
# Sign an InkBoat HAP with the OpenHarmony debug certificate chain bundled with
# the SDK.
#
#   .\sign-hap.ps1 -Udid <device-udid> [-BundleName com.inkboat.reader]
#
# THIS IS A FALLBACK PATH, NOT THE PRIMARY ONE.
#
# The primary path is to hand the *unsigned* HAP to a HarmonyOS debug installer
# (for example https://github.com/likuai2010/auto-installer, "小白调试助手"),
# which performs its own signing/resigning and needs no Huawei account. Prefer
# that: it is what the project is set up for, and `dist/inkboat-*-unsigned.hap`
# is built for exactly that purpose.
#
# Use this script only when you want to install with bare `hdc install` and have
# no installer tool available.
#
# KNOWN LIMITATION — the signing chain is incomplete:
# `keytool -exportcert -alias 'openharmony application release'` returns a single
# certificate, but `sign-app` requires a full chain (leaf -> intermediate -> root)
# and fails with:
#
#     ERROR 11013004 Profile cert must a cert chain
#
# To make this path work, build app-release.cer by exporting the three
# certificates in order:
#
#     keytool -exportcert -rfc -alias 'openharmony application release' ...
#     keytool -exportcert -rfc -alias 'openharmony application ca' ...
#     keytool -exportcert -rfc -alias 'openharmony application root ca' ...
#
# and concatenating the PEM blocks leaf-first into one file.
#
# SEPARATE CAVEAT: this chain is the *OpenHarmony* test chain that ships with the
# SDK. An OpenHarmony device trusts it; a HarmonyOS device may not, because
# HarmonyOS validates against Huawei-issued certificates. If installation reports
# a signature or profile error after the chain is fixed, this route cannot work on
# that device and a Huawei-issued certificate is required instead.
# ---------------------------------------------------------------------------
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string] $Udid,

  [string] $BundleName = 'com.inkboat.reader',

  [string] $DevEcoHome = '',

  [string] $UnsignedHap = '',

  [string] $OutDir = ''
)

$ErrorActionPreference = 'Stop'

# Resolve the DevEco Studio install directory without hard-coding a machine path:
# parameter -> DEVECO_HOME -> AGENTS.local.md -> candidate probe (scripts\env.ps1).
if ([string]::IsNullOrWhiteSpace($DevEcoHome)) {
  $DevEcoHome = (& (Join-Path $PSScriptRoot 'scripts\env.ps1') -Get DEVECO_HOME)
  if ([string]::IsNullOrWhiteSpace($DevEcoHome)) {
    throw 'DevEco Studio not found. Set DEVECO_HOME or fill DEVECO_HOME in AGENTS.local.md.'
  }
}

$sdkLib  = Join-Path $DevEcoHome 'sdk\default\openharmony\toolchains\lib'
$java    = Join-Path $DevEcoHome 'jbr\bin\java.exe'
$signJar = Join-Path $sdkLib 'hap-sign-tool.jar'
$keyStore = Join-Path $sdkLib 'OpenHarmony.p12'
$profileCert = Join-Path $sdkLib 'OpenHarmonyProfileDebug.pem'
$profileTemplate = Join-Path $sdkLib 'UnsgnedDebugProfileTemplate.json'

# The OpenHarmony keystore ships with a well-known password; it is a public test
# fixture, not a secret.
$storePwd = '123456'
$keyPwd = '123456'

$projectRoot = $PSScriptRoot
if ([string]::IsNullOrEmpty($UnsignedHap)) {
  $UnsignedHap = Join-Path $projectRoot 'entry\build\default\outputs\default\entry-default-unsigned.hap'
}
if ([string]::IsNullOrEmpty($OutDir)) {
  $OutDir = Join-Path $projectRoot 'dist'
}

foreach ($required in @($java, $signJar, $keyStore, $profileCert, $profileTemplate, $UnsignedHap)) {
  if (-not (Test-Path $required)) { throw "Missing required file: $required" }
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$work = Join-Path $OutDir 'work'
New-Item -ItemType Directory -Force -Path $work | Out-Null

Write-Host "[sign] bundle=$BundleName"
Write-Host "[sign] udid=$Udid"
Write-Host "[sign] input=$UnsignedHap"

# ---------------------------------------------------------------------------
# 1. Export the application signing certificate chain.
#
# `sign-app` wants the chain ordered leaf -> intermediate -> root, which is what
# `keytool -exportcert` on a PrivateKeyEntry emits only that entry's own
# certificate, but `sign-app` requires a chain ordered leaf -> intermediate ->
# root. Each level is therefore exported separately and concatenated in order;
# using a single export fails with "Profile cert must a cert chain".
# ---------------------------------------------------------------------------
$appCertFile = Join-Path $work 'app-release.cer'
$keytool = Join-Path $DevEcoHome 'jbr\bin\keytool.exe'

$chainAliases = @(
  'openharmony application release',
  'openharmony application ca',
  'openharmony application root ca'
)

if (Test-Path $appCertFile) { Remove-Item $appCertFile -Force }
$certCount = 0
foreach ($alias in $chainAliases) {
  $part = Join-Path $work (($alias -replace ' ', '_') + '.cer')
  & $keytool -exportcert -rfc -alias $alias `
    -keystore $keyStore -storetype PKCS12 -storepass $storePwd `
    -file $part 2>&1 | Out-Null
  if (Test-Path $part) {
    Get-Content $part -Raw | Add-Content -Path $appCertFile -NoNewline
    $certCount++
  } else {
    Write-Warning "Could not export a certificate for alias '$alias'."
  }
}

if (-not (Test-Path $appCertFile)) { throw 'Failed to export the application certificate chain.' }
Write-Host "[sign] exported certificate chain ($certCount certificate(s), leaf -> root)"
if ($certCount -lt 3) {
  Write-Warning 'The chain has fewer than 3 certificates; sign-app may still reject it.'
}

# ---------------------------------------------------------------------------
# 2. Build the provision profile from the SDK template.
#
# Two fields must be rewritten:
#   - bundle-name: must match AppScope/app.json5 exactly, or installation fails
#     with a bundle-name mismatch.
#   - device-ids: a debug profile is only installable on the devices it lists.
#
# The template's validity window expired on 2024-01-13, so it is replaced with a
# fresh ten-year window. Reusing the expired window makes the device reject the
# profile as out of date regardless of the signature.
# ---------------------------------------------------------------------------
$profileJson = Join-Path $work 'profile.json'
$template = Get-Content $profileTemplate -Raw | ConvertFrom-Json

$template.'bundle-info'.'bundle-name' = $BundleName
$template.'debug-info'.'device-ids' = @($Udid)
$now = [int][double]::Parse((Get-Date -UFormat %s))
$template.validity.'not-before' = $now
$template.validity.'not-after' = $now + (10 * 365 * 24 * 60 * 60)

$template | ConvertTo-Json -Depth 20 | Set-Content -Path $profileJson -Encoding UTF8
Write-Host "[sign] profile written (valid from $($template.validity.'not-before') to $($template.validity.'not-after'))"

# ---------------------------------------------------------------------------
# 3. Sign the profile into a p7b.
# ---------------------------------------------------------------------------
$profileP7b = Join-Path $OutDir 'inkboat.p7b'

& $java -jar $signJar sign-profile `
  -mode localSign `
  -keyAlias 'openharmony application profile debug' `
  -keyPwd $keyPwd `
  -profileCertFile $profileCert `
  -inFile $profileJson `
  -signAlg SHA256withECDSA `
  -keystoreFile $keyStore `
  -keystorePwd $storePwd `
  -outFile $profileP7b 2>&1 | ForEach-Object { Write-Host "  [sign-profile] $_" }

if (-not (Test-Path $profileP7b)) { throw 'Failed to sign the provision profile.' }
Write-Host "[sign] profile signed -> $profileP7b"

# ---------------------------------------------------------------------------
# 4. Sign the HAP.
#
# `compatibleVersion` must be the API level the HAP was built against, not the
# target API: the device uses it to decide installability on older systems.
# ---------------------------------------------------------------------------
$signedHap = Join-Path $OutDir 'inkboat-signed.hap'
if (Test-Path $signedHap) { Remove-Item $signedHap -Force }

& $java -jar $signJar sign-app `
  -mode localSign `
  -keyAlias 'openharmony application release' `
  -keyPwd $keyPwd `
  -appCertFile $appCertFile `
  -profileFile $profileP7b `
  -inFile $UnsignedHap `
  -signAlg SHA256withECDSA `
  -keystoreFile $keyStore `
  -keystorePwd $storePwd `
  -outFile $signedHap `
  -compatibleVersion 24 2>&1 | ForEach-Object { Write-Host "  [sign-app] $_" }

if (-not (Test-Path $signedHap)) { throw 'Failed to sign the HAP.' }

$size = [math]::Round((Get-Item $signedHap).Length / 1KB, 1)
Write-Host "[sign] HAP signed -> $signedHap ($size KB)"

# ---------------------------------------------------------------------------
# 5. Verify both artifacts, so a failure is caught here rather than on the device.
# ---------------------------------------------------------------------------
Write-Host '[sign] verifying...'
& $java -jar $signJar verify-profile -inFile $profileP7b -outFile (Join-Path $work 'verify-profile.json') 2>&1 |
  ForEach-Object { Write-Host "  [verify-profile] $_" }
& $java -jar $signJar verify-app -inFile $signedHap -outCertChain (Join-Path $work 'verify-chain.cer') `
  -outProfile (Join-Path $work 'verify-profile.p7b') 2>&1 |
  ForEach-Object { Write-Host "  [verify-app] $_" }

Write-Host ''
Write-Host 'Install with:'
Write-Host "  `"$DevEcoHome\sdk\default\openharmony\toolchains\hdc.exe`" install -r `"$signedHap`""
