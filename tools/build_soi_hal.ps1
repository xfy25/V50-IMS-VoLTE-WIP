# ============================================================================
#  build_soi_hal.ps1 -- build the LG V50 SOI HAL (SMS) module zip on Windows
#
#  Same reason as build.ps1: Compress-Archive drops unix mode bits, and the
#  registrar must land as 0755. This script writes the modes explicitly.
#
#  Layout: <repo>/soi_hal/ is the module root (module.prop at its root).
#  Output: <repo>/dist/v50_soi_hal_v0.3.zip
#
#  NOTE: keep this file pure ASCII (PowerShell 5.1 reads .ps1 as ANSI).
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
$ModuleRoot = Join-Path $Root 'soi_hal'
if (-not (Test-Path $ModuleRoot)) { throw "MISSING module dir: $ModuleRoot" }
$ModuleRoot = (Resolve-Path $ModuleRoot).ProviderPath

$Files = @(
    'module.prop','customize.sh','post-fs-data.sh','service.sh',
    'uninstall.sh','soipolicy.txt','NOTICE.md'
)

function Get-Mode([string]$rel) {
    if ($rel -match '\.sh$') { return 0x81ED }            # 0100755
    if ($rel -match '^files/bin/') { return 0x81ED }      # 0100755
    return 0x81A4                                          # 0100644
}

# ---------------------------------------------------------------------------
# Payload
# ---------------------------------------------------------------------------
$payload = New-Object System.Collections.Generic.List[string]
foreach ($f in $Files) {
    if (-not (Test-Path (Join-Path $ModuleRoot $f))) { throw "MISSING required file: $f" }
    $payload.Add($f)
}
Get-ChildItem (Join-Path $ModuleRoot 'files') -Recurse -File | ForEach-Object {
    if ($_.Name -match '\.(bak|orig|disabled|tmp|swp|testd)$') { return }
    $payload.Add($_.FullName.Substring($ModuleRoot.Length + 1).Replace('\','/'))
}

$must = 'files/bin/vendor.lge.hardware.soi@1.0-service'
if ($payload -notcontains $must) { throw "MISSING critical binary: $must" }

# ---------------------------------------------------------------------------
# Release guards
# ---------------------------------------------------------------------------
$policy = [IO.File]::ReadAllText((Join-Path $ModuleRoot 'soipolicy.txt'))
# Ignore comment lines: the header explains which dead types were removed.
$policyRules = (($policy -split "`r?`n") | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
foreach ($dead in @('hal_lge_soi_hwservice','vendor_lge_ril_prop','vendor_lge_sms_framework_prop')) {
    if ($policyRules -match [regex]::Escape($dead)) {
        throw "POLICY GUARD FAILED: soipolicy.txt still references absent type '$dead'"
    }
}
$svc = [IO.File]::ReadAllText((Join-Path $ModuleRoot 'service.sh'))
if ($svc -notmatch 'wait_soi') {
    throw "SERVICE GUARD FAILED: watchdog does not wait for ISoi before restarting IMS"
}
if ($svc -match 'sleep\s+5\s*\r?\n\s*restart_ims') {
    throw "SERVICE GUARD FAILED: fixed sleep before restart_ims is back"
}
# Catch the exact bug found on the 22:49 boot: the call was truncated to
# "start_registra", so the registrar never started. `sh -n` cannot see this.
if ($svc -match '(?m)^\s*start_registra\s*$') {
    throw "SERVICE GUARD FAILED: truncated start_registra call (missing final r)"
}
if ($svc -notmatch '(?m)^start_registrar$') {
    throw "SERVICE GUARD FAILED: no start_registrar call in service.sh"
}

$prop    = [IO.File]::ReadAllText((Join-Path $ModuleRoot 'module.prop'))
$version = ([regex]::Match($prop,'(?m)^version=(.+)$')).Groups[1].Value.Trim()
$code    = ([regex]::Match($prop,'(?m)^versionCode=(.+)$')).Groups[1].Value.Trim()
if (-not $version) { throw "cannot read version= from module.prop" }

if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir | Out-Null }
$zipPath = Join-Path $OutDir ("v50_soi_hal_v{0}.zip" -f $version)
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }

Write-Host ("Building v{0} (versionCode {1})" -f $version, $code)
Write-Host ("  {0} files -> {1}" -f $payload.Count, $zipPath)

# ---------------------------------------------------------------------------
# Write zip
# ---------------------------------------------------------------------------
$fs  = [System.IO.File]::Open($zipPath, [System.IO.FileMode]::CreateNew)
$zip = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create)

$dirs = New-Object System.Collections.Generic.HashSet[string]
foreach ($rel in $payload) {
    $parts = $rel.Split('/')
    for ($i = 1; $i -lt $parts.Count; $i++) {
        [void]$dirs.Add(($parts[0..($i-1)] -join '/') + '/')
    }
}
foreach ($d in ($dirs | Sort-Object)) {
    $e = $zip.CreateEntry($d, [System.IO.Compression.CompressionLevel]::NoCompression)
    $e.ExternalAttributes = 0x41ED0000   # 040755
    $e.LastWriteTime = (Get-Date '2024-01-01')
}

foreach ($rel in $payload) {
    $src = Join-Path $ModuleRoot ($rel.Replace('/','\'))
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
    if ($e.FullName -match '\.(bak|orig|testd)$|\.bak-') {
        Write-Host ("  !! BACKUP FILE: {0}" -f $e.FullName); $bad++
    }
}
$exe = $z.Entries | Where-Object { $_.FullName -match '^files/bin/' }
foreach ($e in $exe) {
    $m = ($e.ExternalAttributes -shr 16) -band 0xFFFF
    $ok = ($m -band 0x49) -eq 0x49
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
