# ============================================================================
#  build.ps1 -- build the V50 IMS + VoLTE module zip on Windows
#
#  Why this script exists instead of just Compress-Archive:
#    The v0.60 zip was built on Windows and ended up with ALL unix permission
#    bits zeroed (external attributes high 16 bits = 0 for all 41 entries).
#    Consequence: imsipsecstarter / imsipsecclient landed as 0644, and
#    service.sh probes them with  [ -x "$IS" ]  -- so the IPSec channel
#    silently never started and the log just said "not found".
#    This script writes the mode bits explicitly.
#
#  NOTE: keep this file pure ASCII. PowerShell 5.1 reads .ps1 as ANSI, so
#        non-ASCII characters here become mojibake and break the parser.
#
#  Usage:
#      powershell -ExecutionPolicy Bypass -File tools\build.ps1
# ============================================================================

param(
    [string]$Root   = (Split-Path -Parent $PSScriptRoot),
    [string]$OutDir = ''
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

if ([string]::IsNullOrEmpty($OutDir)) { $OutDir = Join-Path $Root 'dist' }
# ProviderPath, not Path: on a UNC root (\\wsl$\...) PS 5.1's .Path returns
# "Microsoft.PowerShell.Core\FileSystem::\\..." while FullName stays plain UNC.
$Root = (Resolve-Path $Root).ProviderPath

# ---------------------------------------------------------------------------
# What goes INSIDE the module zip.
# Everything else (README, CHANGELOG, NOTICE, LICENSE, .gitignore, docs/,
# .github/, tools/) stays out -- the zip must be installable, not a repo dump.
# ---------------------------------------------------------------------------
$Files = @(
    'module.prop','customize.sh','post-fs-data.sh','service.sh','uninstall.sh',
    'system.prop','carrier_volte_override.xml','LATENT_DRIFT.txt'
)
# plus v50ims/** and system/** collected below

# Uncomment if you use a system-vendor overlay layout
# $Dirs = @('v50ims','system')

function Get-Mode([string]$rel) {
    # 0755 for anything that must be executable, 0644 otherwise.
    if ($rel -match '\.sh$') { return 0x81ED }          # 0100755
    if ($rel -match 'system/system_ext/bin/') { return 0x81ED }
    return 0x81A4                                       # 0100644
}

# ---------------------------------------------------------------------------
# Collect payload
# ---------------------------------------------------------------------------
$payload = New-Object System.Collections.Generic.List[string]

foreach ($f in $Files) {
    $p = Join-Path $Root $f
    if (-not (Test-Path $p)) { throw "MISSING required file: $f" }
    $payload.Add($f)
}
foreach ($d in @('v50ims','system')) {
    $dp = Join-Path $Root $d
    if (-not (Test-Path $dp)) { throw "MISSING required dir: $d" }
    Get-ChildItem $dp -Recurse -File | ForEach-Object {
        # Never ship runtime backups / state (v0.62: v50ims/ had a .bak-2026...).
        if ($_.Name -match '\.(bak|orig|disabled|tmp|swp)$|\.bak-') { return }
        if ($_.Name -match '^\.boot') { return }
        $payload.Add($_.FullName.Substring($Root.Length + 1).Replace('\','/'))
    }
}

# Sanity: the two binaries that service.sh probes with [ -x ] must be present
foreach ($must in @('system/system_ext/bin/imsipsecstarter','system/system_ext/bin/imsipsecclient')) {
    if ($payload -notcontains $must) { throw "MISSING critical binary: $must" }
}

# ---------------------------------------------------------------------------
# Version
# ---------------------------------------------------------------------------
$prop    = Get-Content (Join-Path $Root 'module.prop') -Raw
$version = ([regex]::Match($prop,'(?m)^version=(.+)$')).Groups[1].Value.Trim()
$code    = ([regex]::Match($prop,'(?m)^versionCode=(.+)$')).Groups[1].Value.Trim()
if (-not $version) { throw "cannot read version= from module.prop" }

# ---------------------------------------------------------------------------
# Release guards (both bugs actually shipped before)
# ---------------------------------------------------------------------------
# 1) Never ship the unpatched PE14 telephony-common.jar.
$jar = Join-Path $Root 'system/framework/telephony-common.jar'
$jarHash = (Get-FileHash $jar -Algorithm MD5).Hash
if ($jarHash -eq '005DADC738F66F186D7120757126E079') {
    throw "JAR GUARD FAILED: system/framework/telephony-common.jar is the unpatched stock jar"
}
# 2) Never ship the SMS-over-IP-disabled config again (the v0.61 zip bug).
$cfg = [IO.File]::ReadAllText((Join-Path $Root 'v50ims/configuration.OPEN.CN.xml'))
foreach ($pair in @(
    @('sdm_sms_over_ip_network','TEXT','true'),
    @('sms_over_ip_networks_indication','TEXT','1'),
    @('LGE_FEATURE_SMS','INTEGER','1'),
    @('config_xml_modified_time','TEXT','105')
)) {
    $pat = 'name="{0}" type="{1}" value="{2}"' -f $pair[0], $pair[1], $pair[2]
    if ($cfg -notmatch [regex]::Escape($pat)) {
        throw "CONFIG GUARD FAILED: missing [$pat] in v50ims/configuration.OPEN.CN.xml"
    }
}

if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir | Out-Null }
$zipPath = Join-Path $OutDir ("v50_ims_volte_v{0}.zip" -f $version)
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }

Write-Host ("Building v{0} (versionCode {1})" -f $version, $code)
Write-Host ("  {0} files -> {1}" -f $payload.Count, $zipPath)

# ---------------------------------------------------------------------------
# Write zip
# ---------------------------------------------------------------------------
$fs  = [System.IO.File]::Open($zipPath, [System.IO.FileMode]::CreateNew)
$zip = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create)

# explicit directory entries, matching how the original module zip was laid out
$dirs = New-Object System.Collections.Generic.HashSet[string]
foreach ($rel in $payload) {
    $parts = $rel.Split('/')
    for ($i = 1; $i -lt $parts.Count; $i++) {
        [void]$dirs.Add(($parts[0..($i-1)] -join '/') + '/')
    }
}
foreach ($d in ($dirs | Sort-Object)) {
    $e = $zip.CreateEntry($d, [System.IO.Compression.CompressionLevel]::NoCompression)
    $e.ExternalAttributes = 0x41ED0000   # 040755 directory
    $e.LastWriteTime = (Get-Date '2024-01-01')
}

foreach ($rel in $payload) {
    $src = Join-Path $Root ($rel.Replace('/','\'))
    $e   = $zip.CreateEntry($rel, [System.IO.Compression.CompressionLevel]::Optimal)
    $e.ExternalAttributes = (Get-Mode $rel) -shl 16
    $e.LastWriteTime = (Get-Date '2024-01-01')
    $out = $e.Open()
    $in  = [System.IO.File]::OpenRead($src)
    $in.CopyTo($out)
    $in.Close(); $out.Close()
}
$zip.Dispose(); $fs.Close()

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------
$z = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
Write-Host ""
Write-Host "--- verification ---"
$bad = 0
$rootProp = $false
foreach ($e in $z.Entries) {
    if ($e.FullName -eq 'module.prop') { $rootProp = $true }
    if ($e.FullName.EndsWith('/')) { continue }
    $mode = ($e.ExternalAttributes -shr 16) -band 0xFFFF
    if ($mode -eq 0) { Write-Host ("  !! NO MODE: {0}" -f $e.FullName); $bad++ }
}
$exe = $z.Entries | Where-Object { $_.FullName -match 'imsipsec(starter|client)$' }
foreach ($e in $exe) {
    # mask to 16 bits: -shr on a negative Int32 sign-extends, so without the
    # mask the octal printout comes out as 037777700755 instead of 0100755
    $m = ($e.ExternalAttributes -shr 16) -band 0xFFFF
    $ok = ($m -band 0x49) -eq 0x49     # all three x bits
    Write-Host ("  {0} {1} mode=0{2}" -f $(if($ok){'OK  '}else{'FAIL'}), $e.FullName, ([Convert]::ToString($m,8)))
    if (-not $ok) { $bad++ }
}
Write-Host ("  module.prop at zip root: {0}" -f $rootProp)
Write-Host ("  entries: {0}" -f $z.Entries.Count)
$z.Dispose()

if ($bad -gt 0 -or -not $rootProp) {
    Write-Host ""
    Write-Host "  VERIFY FAILED" -ForegroundColor Red
    exit 1
}

$size = (Get-Item $zipPath).Length
$hash = (Get-FileHash $zipPath -Algorithm SHA256).Hash
Write-Host ""
Write-Host ("  {0:N1} MB" -f ($size / 1MB))
Write-Host ("  sha256 {0}" -f $hash)
Write-Host ""
Write-Host "OK"
