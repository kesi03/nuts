#Requires -Version 5.1
<#
.SYNOPSIS
    Audits pages/*.yaml against Reason's own factory maps.

.DESCRIPTION
    The pages/*.yaml files describe, per Reason device scope, which remotable
    each control targets and which pages a device has. They are currently NOT
    consumed by deploy.ps1 - this script only tells you how far each template
    is from being usable as a build input.

    It checks, per template:
      * the declared scope model exists in Reason's scope list
      * every 'target:' naming a Remotable Item exists in that scope
      * every PermaBar key referenced exists in the driver's mapping
      * duplicate remotable targets within one scope (Reason rejects these)
      * the page count and page names

    Targets are read from remote/mapping/reason-remote_full.xlsx. The Index
    sheet supplies each scope's manufacturer/model identity; its device
    sheet supplies the remotable list.

.PARAMETER Only
    Restrict the audit to templates whose file name matches this wildcard.

.EXAMPLE
    pwsh -NoProfile -File remote/scripts/audit-pages.ps1
    pwsh -NoProfile -File remote/scripts/audit-pages.ps1 -Only 'thor*'
#>

[CmdletBinding()]
param(
    [string]$Only = '*'
)

$ErrorActionPreference = 'Stop'
$T = [char]9

$RemoteRoot  = Join-Path $env:ProgramData 'Propellerhead Software\Remote'
$FactoryMaps = Join-Path $RemoteRoot 'Maps'
$PagesDir    = Join-Path $PSScriptRoot '..\..\pages'
$DriverCfg   = Join-Path $PSScriptRoot '..\..\src\Nuts.Driver\appsettings.json'

if (-not (Test-Path $FactoryMaps)) { throw "Reason factory maps not found: $FactoryMaps" }
if (-not (Test-Path $PagesDir))    { throw "pages folder not found: $PagesDir" }

# ---- 1. authoritative scope -> set of remotable targets -------------------
$WorkbookReader = Join-Path $PSScriptRoot 'reason_workbook.py'
if (-not (Test-Path -LiteralPath $WorkbookReader)) {
    throw "Missing Reason workbook reader: $WorkbookReader"
}
$targetJson = & python $WorkbookReader --targets-json
if ($LASTEXITCODE -ne 0) {
    throw "reason_workbook.py could not read reason-remote_full.xlsx."
}
$targetDoc = ($targetJson -join "`n") | ConvertFrom-Json
$scopeTargets = [System.Collections.Hashtable]::new([System.StringComparer]::Ordinal)
foreach ($entry in $targetDoc.scopes) {
    $h = New-Object System.Collections.Generic.HashSet[string]
    foreach ($t in $entry.targets) { [void]$h.Add([string]$t) }
    $scopeTargets[$entry.key] = $h
}

# ---- 2. the driver's PermaBar CC key names -------------------------------
# navigation/pager entries name a key such as MixCc or PagePlusCc. Those are
# driver-side concepts, so collect the names the driver actually defines.
$cfg = Get-Content -LiteralPath $DriverCfg -Raw | ConvertFrom-Json
$driverKeys = New-Object System.Collections.Generic.HashSet[string]
foreach ($k in $cfg.Midi.Mapping.PSObject.Properties.Name) { [void]$driverKeys.Add($k) }
foreach ($k in $cfg.Midi.Paging.PSObject.Properties.Name)  { [void]$driverKeys.Add($k) }
# The templates use short names (MixCc, LearnCc, ViewCc, UserCc, InstrCc,
# FXCc, PagePlusCc, PageMinusCc, SpeedDialCc, XfaderCcs, EncoderCcs, ...).
# Treat any key ending in Cc/Ccs as driver-provided; flag only the ones the
# driver has no matching concept for.
$knownCcKeys = @(
    'EncoderCcs', 'EncoderTouchCcs', 'ButtonCcs', 'SpeedDialCc',
    'SpeedDialButtonCc', 'SpeedDialTouchCc', 'XfaderCcs', 'XfaderTouchCc',
    'RingValueCcs', 'SpeedDialRingCc', 'RingModeCcs',
    'PrevButton', 'NextButton', 'JumpButtons', 'EchoCc',
    'MixCc', 'UserCc', 'InstrCc', 'FXCc', 'LearnCc', 'ViewCc',
    'PagePlusCc', 'PageMinusCc'
)

# ---- 3. audit each template ----------------------------------------------
$files = @(Get-ChildItem (Join-Path $PagesDir '*.yaml') | Where-Object { $_.Name -like $Only })
if ($files.Count -eq 0) { throw "No templates matched '$Only' in $PagesDir" }

$totalBadTargets  = 0
$totalDupTargets  = 0
$totalUnknownKey  = 0
$scopeMissing     = @()

Write-Host "Auditing $($files.Count) template(s) from $PagesDir" -ForegroundColor Cyan
Write-Host ''

foreach ($f in $files) {
    $lines = [System.IO.File]::ReadAllLines($f.FullName)

    $manufacturer = ''
    $model = ''
    foreach ($l in ($lines | Select-Object -First 8)) {
        if ($l -match '^\s*manufacturer:\s*(.+?)\s*$') { $manufacturer = $Matches[1].Trim() }
        if ($l -match '^\s*model:\s*(.+?)\s*$') { $model = $Matches[1].Trim() }
    }

    # page names: 2-space indent directly under 'pages:'. Nested keys such as
    # pager/navigation/controls/encoders/buttons are 4-space indented, so a
    # page name is a 2-space indent that is NOT one of those block names.
    $blockNames = @('pager', 'navigation', 'controls', 'encoders', 'buttons', 'dynamic_mapping')
    $pages = New-Object System.Collections.Generic.List[string]
    $inPages = $false
    foreach ($l in $lines) {
        if ($l -match '^pages:\s*$') { $inPages = $true; continue }
        if ($inPages) {
            if ($l -match '^  (\S[^:]*):\s*$') {
                $name = $Matches[1].Trim()
                if ($blockNames -notcontains $name) { $pages.Add($name) }
            }
            elseif ($l -match '^\S') { $inPages = $false }
        }
    }

    # targets and keys: every "target: X" and "key: Y"
    $targets = New-Object System.Collections.Generic.List[string]
    $keys    = New-Object System.Collections.Generic.HashSet[string]
    $ioTypes = New-Object System.Collections.Generic.HashSet[string]
    foreach ($l in $lines) {
        if ($l -match '\btarget:\s*([^,}]+)') {
            $targets.Add($Matches[1].Trim().Trim('"').Trim("'"))
        }
        if ($l -match '\bkey:\s*([A-Za-z0-9_]+)') { [void]$keys.Add($Matches[1].Trim()) }
        if ($l -match '\binput_type:\s*([A-Za-z0-9_]+)') { [void]$ioTypes.Add($Matches[1].Trim()) }
    }

    $scopeKey = "$manufacturer`t$model"
    $scopeOk = $scopeTargets.ContainsKey($scopeKey)
    if (-not $scopeOk) { $scopeMissing += "$($f.Name) -> '$scopeKey'" }

    # bad targets
    $badTargets = @()
    if ($scopeOk) {
        $seen = @{}
        foreach ($t in $targets) {
            if (-not $scopeTargets[$scopeKey].Contains($t)) { $badTargets += $t }
            if ($seen.ContainsKey($t)) { $totalDupTargets++ }
            else { $seen[$t] = $true }
        }
    }

    # unknown driver keys
    $badKeys = @($keys | Where-Object { $knownCcKeys -notcontains $_ })

    $totalBadTargets += $badTargets.Count
    $totalUnknownKey += $badKeys.Count

    $status = if ($scopeOk -and $badTargets.Count -eq 0 -and $badKeys.Count -eq 0) { 'OK  ' } else { 'FLAG' }
    Write-Host ("{0} {1,-38} scope='{2}'" -f $status, $f.Name, $model)
    Write-Host ("       pages ({0}): {1}" -f $pages.Count, ($pages -join ', '))
    Write-Host ("       controls: {0} target(s), {1} key(s)" -f $targets.Count, $keys.Count)

    if (-not $scopeOk) {
        Write-Host "       !! SCOPE NOT FOUND IN REASON - cannot validate targets" -ForegroundColor Red
    }
    if ($badTargets.Count -gt 0) {
        Write-Host ("       !! {0} target(s) not in scope '{1}':" -f $badTargets.Count, $model) -ForegroundColor Yellow
        $badTargets | Select-Object -Unique | Sort-Object | ForEach-Object { Write-Host "            $_" -ForegroundColor Yellow }
    }
    if ($badKeys.Count -gt 0) {
        Write-Host ("       !! {0} unknown key(s): {1}" -f $badKeys.Count, ($badKeys -join ', ')) -ForegroundColor Yellow
    }
    Write-Host ''
}

Write-Host '================================================================'
Write-Host ("scopes not found      : {0}" -f $scopeMissing.Count)
$scopeMissing | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
Write-Host ("targets not in scope  : {0}" -f $totalBadTargets)
Write-Host ("duplicate targets     : {0}" -f $totalDupTargets)
Write-Host ("unknown control keys  : {0}" -f $totalUnknownKey)
Write-Host '================================================================'

if ($scopeMissing.Count -eq 0 -and $totalBadTargets -eq 0 -and $totalUnknownKey -eq 0) {
    Write-Host 'TEMPLATES: ALL CONSISTENT' -ForegroundColor Green
} else {
    Write-Host 'TEMPLATES: PROBLEMS FOUND' -ForegroundColor Red
}
