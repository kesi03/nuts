#Requires -Version 5.1
<#
.SYNOPSIS
    Extracts an authoritative scope -> remotable-target list from Reason's
    factory remote maps.

.DESCRIPTION
    A remote map line is:

        Map<TAB>ControlSurfaceItem<TAB>[blank]<TAB>RemotableItem<TAB>[Scale]<TAB>[Mode]

    The 4th field is the remotable item. Some fields are NOT real device
    parameters but surface-side selectors, and they must be filtered out:

        Display=DeviceName   Display=ParaName
        Flip=Flipped         Flip=Normal         Flip=Flip On   Flip=Flip Off
        Shift=ShiftUp        Shift=ShiftDown
        Active=On            Active=Off
        RedClickState=...    GreenClickState=... BlueClickState=...
        WhiteClickState=...

    (Mackie/M-Audio surface maps drive their LCDs and button colours with
    these. They are meaningless as device remotables and would otherwise
    pollute the target list, which is exactly what made an earlier audit
    report false "invalid target" hits.)

    The union of all factory maps gives the widest coverage, because no
    single surface map maps every parameter of every device.

    Output is written as JSON so other scripts and generators can consume it.
    This script is READ-ONLY: it does not deploy anything.

.PARAMETER OutputPath
    Where to write the JSON. Defaults to remote/mapping/reason-targets.json.

.PARAMETER Quiet
    Do not print the per-scope summary.

.EXAMPLE
    pwsh -NoProfile -File remote/scripts/extract-targets.ps1
    pwsh -NoProfile -File remote/scripts/extract-targets.ps1 -Quiet
#>

[CmdletBinding()]
param(
    [string]$OutputPath = '',
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
$T = [char]9

$ScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $OutputPath) { $OutputPath = Join-Path $ScriptRoot '..\mapping\reason-targets.json' }

$FactoryMaps = Join-Path $env:ProgramData 'Propellerhead Software\Remote\Maps'
if (-not (Test-Path $FactoryMaps)) { throw "Reason factory maps not found: $FactoryMaps" }

# Surface-side selector targets that are not device parameters.
$selectorPrefixes = @(
    'Display=', 'Flip=', 'Shift=', 'Active=',
    'RedClickState=', 'GreenClickState=', 'BlueClickState=', 'WhiteClickState=',
    'YellowClickState=', 'OrangeClickState='
)

function Test-IsSelector([string]$t) {
    foreach ($p in $selectorPrefixes) { if ($t.StartsWith($p)) { return $true } }
    return $false
}

# LCD-driving surface maps (Mackie Control, M-Audio ProjectMix) put a literal
# screen caption in the target field, wrapped in double quotes, e.g.
#     Map<T>LCD Row 1 Channel 1<T><T>"Faders "<T><T><T>Multi-Channel<T>EQ<T>Flipped
# The caption is not a remotable item; the real target is a later field. Those
# real targets are also mapped plainly by the non-LCD maps, so the safest
# filter is to discard any quoted caption outright.
function Test-IsCaption([string]$t) {
    return ($t.Length -ge 2 -and $t.StartsWith('"') -and $t.EndsWith('"'))
}

$scopeTargets = @{}

Get-ChildItem $FactoryMaps -Recurse -Filter '*.remotemap' | ForEach-Object {
    $scope = ''
    foreach ($l in [System.IO.File]::ReadAllLines($_.FullName)) {
        $sp = $l.Split($T)
        if ($sp.Count -ge 3 -and $sp[0].Trim() -eq 'Scope') {
            $scope = $sp[$sp.Count - 1].Trim()
            continue
        }
        if ($sp.Count -lt 4) { continue }
        if ($sp[0].Trim() -ne 'Map') { continue }
        if ($sp[1].Trim() -eq '_Scope') { continue }
        if ($scope -eq '') { continue }

        $tgt = $sp[3].Trim()
        if ($tgt -eq '') { continue }
        if (Test-IsSelector $tgt) { continue }
        if (Test-IsCaption $tgt) { continue }

        if (-not $scopeTargets.ContainsKey($scope)) {
            $scopeTargets[$scope] = New-Object System.Collections.Generic.HashSet[string]
        }
        [void]$scopeTargets[$scope].Add($tgt)
    }
}

# Build a sorted, deterministic JSON document.
$doc = [ordered]@{}
foreach ($s in ($scopeTargets.Keys | Sort-Object)) {
    $doc[$s] = @($scopeTargets[$s] | Sort-Object)
}

$dir = Split-Path -Parent $OutputPath
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
$json = $doc | ConvertTo-Json -Depth 4
[System.IO.File]::WriteAllText((Resolve-Path -LiteralPath $dir).Path + '\' + (Split-Path -Leaf $OutputPath), $json)

if (-not $Quiet) {
    Write-Host ("Scopes: {0}" -f $scopeTargets.Count) -ForegroundColor Cyan
    Write-Host ("Total distinct targets: {0}" -f (($scopeTargets.Values | ForEach-Object { $_.Count } | Measure-Object -Sum).Sum))
    Write-Host ''
    Write-Host "Per-scope target counts:"
    foreach ($s in ($scopeTargets.Keys | Sort-Object)) {
        Write-Host ("  {0,-45} {1,4}" -f $s, $scopeTargets[$s].Count)
    }
}
