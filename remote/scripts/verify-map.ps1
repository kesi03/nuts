$ErrorActionPreference = 'Stop'
$T = [char]9

# ---- 1. Collect authoritative targets from Reasons factory maps ----
$targets = @{}   # "manufacturer`tmodel" -> HashSet of target names
Get-ChildItem 'C:\ProgramData\Propellerhead Software\Remote\Maps' -Recurse -Filter '*.remotemap' | ForEach-Object {
    $scope = ''
    foreach ($l in [System.IO.File]::ReadAllLines($_.FullName)) {
        $sp = $l.Split($T)
        if ($sp.Count -ge 3 -and $sp[0] -eq 'Scope') { $scope = ($sp[1..($sp.Count-1)] -join "`t").Trim(); continue }
        if ($sp.Count -ge 4 -and $sp[0] -eq 'Map' -and $sp[1] -ne '_Scope' -and $sp[3].Trim() -ne '') {
            if (-not $targets.ContainsKey($scope)) { $targets[$scope] = New-Object System.Collections.Generic.HashSet[string] }
            [void]$targets[$scope].Add($sp[3].Trim())
        }
    }
}

# ---- 2. Check our map ----
$ourPath = Join-Path $PSScriptRoot '..\Maps\Nuts\Nocturn.remotemap'
$scope = ''
$rows = 0; $bad = 0; $items = New-Object System.Collections.Generic.HashSet[string]
# Reason allows each Remotable Item only ONCE per Scope. A second Map line for
# the same target aborts the whole surface ("remotable item already mapped in
# this scope"), so track every target -> the item that claimed it. This is the
# check that was missing when "Filters Dyn S/C" got mapped on two pages.
$targetOwner = @{}
$dupes = 0
foreach ($l in [System.IO.File]::ReadAllLines($ourPath)) {
    $sp = $l.Split($T)
    if ($sp.Count -ge 3 -and $sp[0] -eq 'Scope') { $scope = ($sp[1..($sp.Count-1)] -join "`t").Trim(); continue }
    if ($sp.Count -lt 4 -or $sp[0] -ne 'Map') { continue }
    $item = $sp[1]; $target = $sp[3].Trim()
    if ($item -eq '_Scope') { [void]$items.Add($item); continue }
    if ($target -eq '') { continue }
    $rows++
    [void]$items.Add($item)
    if (-not $targets.ContainsKey($scope)) { Write-Host "  UNKNOWN SCOPE: '$scope'"; $bad++; continue }
    if (-not $targets[$scope].Contains($target)) { Write-Host "  BAD TARGET [$scope] '$target'"; $bad++ }

    $key = "$scope`t$target"
    if ($targetOwner.ContainsKey($key)) {
        Write-Host "  DUPLICATE TARGET [$scope] '$target' mapped by '$($targetOwner[$key])' and '$item'"
        $dupes++
    } else {
        $targetOwner[$key] = $item
    }
}

Write-Host "scope          : $scope"
Write-Host "mapped rows    : $rows"
Write-Host "distinct items : $($items.Count)"
Write-Host "duplicate targets: $dupes"
Write-Host "bad targets    : $bad"
Write-Host ''

# ---- 3. Check every mapped item against the codec item set ----
$lua = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\Codecs\Lua Codecs\Nuts\Nocturn.lua') -Raw
$pageNames = @('Mixer','Dynamics','EQ','FX')
$defined = New-Object System.Collections.Generic.HashSet[string]
[void]$defined.Add('_Scope'); [void]$defined.Add('Page')
[void]$defined.Add('Speed Dial'); [void]$defined.Add('Speed Dial Button'); [void]$defined.Add('Crossfader')
foreach ($p in $pageNames) { foreach ($n in 1..8) { [void]$defined.Add("Knob $n $p"); [void]$defined.Add("Button $n $p") } }

$missing = @($items | Where-Object { -not $defined.Contains($_) })
Write-Host "items not defined in codec : $($missing.Count)"
$missing | ForEach-Object { Write-Host "  MISSING: $_" }

# ---- 4. Check driver config <-> codec CC tables ----
$cfg = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\src\Nuts.Driver\appsettings.json') -Raw | ConvertFrom-Json
$encList = $cfg.Midi.Paging.EncoderCcs
$btnList = $cfg.Midi.Paging.ButtonCcs
$codecPairs = [regex]::Matches($lua, '\[0x([0-9a-f]{2})\]=(\d)') | ForEach-Object { $_.Groups[1].Value + '=' + $_.Groups[2].Value }
$mm = 0
for ($p = 0; $p -lt $cfg.Midi.Paging.Names.Count; $p++) {
    for ($n = 0; $n -lt 8; $n++) {
        if ($codecPairs -notcontains (('{0:x2}' -f $encList[$p*8+$n]) + '=' + ($n+1))) { Write-Host "  ENC MISMATCH page $p dial $($n+1)"; $mm++ }
        if ($codecPairs -notcontains (('{0:x2}' -f $btnList[$p*8+$n]) + '=' + ($n+1))) { Write-Host "  BTN MISMATCH page $p button $($n+1)"; $mm++ }
    }
}
Write-Host "codec CC entry count : $($codecPairs.Count) (expect 64)"
Write-Host "driver/codec mismatch: $mm"
Write-Host ''

# ---- 5. Codec must declare auto-inputs -----------------------------------
# Reason only routes port MIDI into a codec through registered auto-inputs;
# remote_process_midi() is an ADDITIONAL hook, not a replacement for them.
# A codec with no define_auto_inputs() is silent in Reason - the surface
# appears and does nothing, with no error shown. Every factory codec declares
# them (76 of 76), so their absence here is always a bug.
$hasAutoInputs = $lua -match 'define_auto_inputs'
Write-Host "codec auto-inputs    : $(if ($hasAutoInputs) { 'declared' } else { 'MISSING - Reason will not route MIDI to this codec' })"

# ---- 6. "Map _Scope" must name the scope, not the surface model ----------
# The _Scope item is the scope's display name; factory and reference maps set
# it to the scope name ("Combinator", "Reason Main Mixer Channel", ...).
$scopeValue = $null
$mapScope = ''
foreach ($l in [System.IO.File]::ReadAllLines($ourPath)) {
    $sp = $l.Split($T)
    # "Scope <manufacturer> <scope name>" - the _Scope value is the LAST field,
    # i.e. just the scope name, not the manufacturer + name pair.
    if ($sp.Count -ge 3 -and $sp[0] -eq 'Scope') { $mapScope = $sp[$sp.Count - 1].Trim(); continue }
    if ($sp.Count -ge 4 -and $sp[0] -eq 'Map' -and $sp[1] -eq '_Scope') {
        $scopeValue = $sp[3].Trim().Trim('"')
    }
}
$scopeOk = ($null -eq $scopeValue) -or ($scopeValue -eq $mapScope)
$scopeDesc =
    if ($null -eq $scopeValue) { '(no _Scope line - optional, OK)' }
    elseif ($scopeOk) { "$scopeValue (matches scope)" }
    else { "$scopeValue but the scope is '$mapScope' - MISMATCH" }
Write-Host "_Scope maps to        : $scopeDesc"
Write-Host ''

if ($hasAutoInputs -and $scopeOk -and $bad -eq 0 -and $dupes -eq 0 -and $missing.Count -eq 0 -and $mm -eq 0 -and $codecPairs.Count -eq 64) { Write-Host 'MAP + CODEC + CONFIG: ALL CONSISTENT' }
else { Write-Host 'PROBLEMS FOUND'; exit 1 }
