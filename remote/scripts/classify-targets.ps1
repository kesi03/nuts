#Requires -Version 5.1
<#
.SYNOPSIS
    Classifies every invalid target in pages/*.yaml so the fixes are mechanical.

.DESCRIPTION
    For each template control whose target is not a remotable item of the
    device's reason-targets.json entry, this tries to find a candidate real
    name using the conventions that actually appear in Reason's maps:

      * an exact match after case/space normalisation
      * the other drum-prefix convention ("Level" -> "Drum 1 Level")
      * a substring match, so a rename can be reviewed by eye

    Output is one line per bad target:
        <template>  '<bad>'  ->  <candidate or NONE>

    This is a report only; it never edits the templates.
#>

[CmdletBinding()]
param(
    [string]$Only = '*'
)

$ErrorActionPreference = 'Stop'

$ScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$PagesDir   = Join-Path $ScriptRoot '..\..\pages'
$TargetsJson = Join-Path $ScriptRoot '..\mapping\reason-targets.json'

if (-not (Test-Path $TargetsJson)) { throw "Missing $TargetsJson. Run extract-targets.ps1 first." }

$targetDoc = Get-Content -LiteralPath $TargetsJson -Raw | ConvertFrom-Json
$scopeTargets = @{}
foreach ($prop in $targetDoc.PSObject.Properties) {
    $scopeTargets[$prop.Name] = @($prop.Value)
}

function Normalize([string]$s) {
    return ($s -replace '[_\s]', '').ToLowerInvariant()
}

$files = @(Get-ChildItem (Join-Path $PagesDir '*.yaml') | Where-Object { $_.Name -like $Only })

foreach ($f in $files) {
    $lines = [System.IO.File]::ReadAllLines($f.FullName)
    $model = ''
    foreach ($l in ($lines | Select-Object -First 6)) {
        if ($l -match '^\s*model:\s*(.+?)\s*$') { $model = $Matches[1].Trim() }
    }
    if (-not $scopeTargets.ContainsKey($model)) {
        Write-Host ""
        Write-Host "### $($f.Name)  scope='$model'  -- SCOPE HAS NO TARGET LIST" -ForegroundColor Yellow
        continue
    }
    $real = $scopeTargets[$model]
    $normMap = @{}
    foreach ($t in $real) {
        $n = Normalize $t
        if (-not $normMap.ContainsKey($n)) { $normMap[$n] = New-Object System.Collections.Generic.List[string] }
        $normMap[$n].Add($t)
    }

    $bad = New-Object System.Collections.Generic.List[string]
    foreach ($l in $lines) {
        if ($l -match '\btarget:\s*([^,}]+)') {
            $t = $Matches[1].Trim()
            if ($real -notcontains $t) { $bad.Add($t) }
        }
    }
    if ($bad.Count -eq 0) { continue }

    Write-Host ""
    Write-Host "### $($f.Name)  scope='$model'  ($($bad.Count) bad of $($real.Count) known)" -ForegroundColor Cyan
    foreach ($t in ($bad | Select-Object -Unique)) {
        $candidate = 'NONE'
        # 1. exact after normalisation
        $n = Normalize $t
        if ($normMap.ContainsKey($n)) {
            $candidate = ($normMap[$n] | Select-Object -First 1)
        }
        else {
            # 2. try the per-drum / per-osc prefix conventions
            $stripped = $t
            foreach ($pre in @('Drum 1 ', 'Osc1 ', 'Osc 1 ', 'Env 1 ', 'LFO 1 ')) {
                $try = $pre + $t
                if ($real -contains $try) { $candidate = $try; break }
            }
            if ($candidate -eq 'NONE') {
                # 3. substring: does any real target contain the normalised text?
                $hits = $real | Where-Object { (Normalize $_) -like ('*' + $n + '*') }
                if ($hits) { $candidate = ($hits | Select-Object -First 3) -join ' | ' }
            }
        }
        Write-Host ("    {0,-38} -> {1}" -f "'$t'", $candidate)
    }
}
