$ErrorActionPreference = 'Stop'
$T = [char]9

# =============================================================================
#  verify-map.ps1
#
#  The three-way contract check for the Nocturn's Reason Remote:
#
#      pages/*.yaml  ->  remote/Maps/Nuts/Nocturn.remotemap  ->  codec
#      remote/mapping/scope-index.json  ->  the map (are the targets real?)
#      src/Nuts.Driver/appsettings.json  ->  the codec (are the CCs the same?)
#
#  Everything is checked, not just the mixer channel: the map now carries one
#  scope per device, and a single bad target in one of them stops Reason from
#  loading the whole surface.
# =============================================================================

$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$mapPath = Join-Path $repo 'remote\Maps\Nuts\Nocturn.remotemap'
$codecPath = Join-Path $repo 'remote\Codecs\Lua Codecs\Nuts\Nocturn.lua'
$indexPath = Join-Path $repo 'remote\mapping\scope-index.list.json'
$cfgPath = Join-Path $repo 'src\Nuts.Driver\appsettings.json'

$problems = 0
function Bad([string]$message) {
    Write-Host "  PROBLEM: $message"
    $script:problems++
}

# -----------------------------------------------------------------------------
# 1. The scope index: which targets are real for which scope
# -----------------------------------------------------------------------------
# remote/remote-info gives the complete remotable list of a scope; Reason's
# factory maps cover the scopes that have no remote-info file (the mixer
# channel is one). The union is what a surface may map.
#
# The list form of the index is read here, not the dictionary form:
# ConvertFrom-Json is case-insensitive about property names and refuses a
# document with two keys that differ only in case, and Reason has scopes
# called "se.propellerheads.PX7" and "se.propellerheads.px7".
$flat = Get-Content -LiteralPath $indexPath -Raw | ConvertFrom-Json

# Ordinal (case-sensitive) dictionaries: Reason has scopes and targets that
# differ only in case ("se.propellerheads.PX7" / "se.propellerheads.px7",
# "Eq On" / "EQ On"), and PowerShell's default hashtable would merge them.
$scopeTargets = [System.Collections.Hashtable]::new([System.StringComparer]::Ordinal)
$scopeNames = [System.Collections.Hashtable]::new([System.StringComparer]::Ordinal)
foreach ($entry in $flat.scopes) {
    $names = New-Object System.Collections.Generic.HashSet[string]
    foreach ($tname in $entry.targets) { [void]$names.Add([string]$tname) }
    $scopeTargets[$entry.key] = $names
    $scopeNames[$entry.key] = $entry.display
}
Write-Host "scope index            : $($scopeTargets.Count) scopes"

# -----------------------------------------------------------------------------
# 2. Parse our map
# -----------------------------------------------------------------------------
$mapScopes = @()        # ordered list of scope keys
$scopeDisplay = [System.Collections.Hashtable]::new([System.StringComparer]::Ordinal)
$targetOwner = [System.Collections.Hashtable]::new([System.StringComparer]::Ordinal)
$items = New-Object System.Collections.Generic.HashSet[string]
$rows = 0

$scope = ''
foreach ($l in [System.IO.File]::ReadAllLines($mapPath)) {
    $sp = $l.Split($T)
    if ($sp.Count -ge 3 -and $sp[0] -eq 'Scope') {
        $scope = ($sp[1..($sp.Count-1)] -join "`t").Trim()
        if (-not $mapScopes.Contains($scope)) { $mapScopes += $scope }
        continue
    }
    if ($sp.Count -lt 4 -or $sp[0] -ne 'Map') { continue }
    $item = $sp[1].Trim(); $target = $sp[3].Trim()
    if ($item -eq '_Scope') {
        if (-not $scopeDisplay.ContainsKey($scope)) { $scopeDisplay[$scope] = $target.Trim('"') }
        [void]$items.Add($item)
        continue
    }
    if ($target -eq '') { continue }
    $rows++
    [void]$items.Add($item)

    if (-not $scopeTargets.ContainsKey($scope)) {
        Bad "scope '$scope' is not a known Reason scope"
        continue
    }
    if (-not $scopeTargets[$scope].Contains($target)) {
        Bad "target '$target' is not a remotable of '$scope'"
    }

    # Reason allows each Remotable Item only ONCE per Scope. A second Map
    # line for the same target aborts the whole surface.
    $key = "$scope`t$target"
    if ($targetOwner.ContainsKey($key)) {
        Bad "duplicate target in scope '$scope': '$target' mapped by '$($targetOwner[$key])' and '$item'"
    } else {
        $targetOwner[$key] = $item
    }
}

$dupScopes = @($mapScopes | Group-Object | Where-Object { $_.Count -gt 1 })
foreach ($d in $dupScopes) { Bad "scope '$($d.Name)' appears $($d.Count) times in the map" }

Write-Host "scopes in the map      : $($mapScopes.Count)"
Write-Host "mapped rows            : $rows"
Write-Host "distinct items         : $($items.Count)"
Write-Host ""

# -----------------------------------------------------------------------------
# 3. Every mapped item must exist in the codec's item set
# -----------------------------------------------------------------------------
# The items are generic: "Knob n P<page>" and "Button n P<page>", where P1..P4
# are the driver's four page slots. Only the shared Speed Dial / Speed Dial
# Button / Crossfader are outside the paging.
$lua = Get-Content -LiteralPath $codecPath -Raw
$pageCount = 4
$defined = New-Object System.Collections.Generic.HashSet[string]
[void]$defined.Add('_Scope'); [void]$defined.Add('Page')
[void]$defined.Add('Speed Dial'); [void]$defined.Add('Speed Dial Button'); [void]$defined.Add('Crossfader')
for ($p = 1; $p -le $pageCount; $p++) {
    for ($n = 1; $n -le 8; $n++) {
        [void]$defined.Add("Knob $n P$p")
        [void]$defined.Add("Button $n P$p")
    }
}

$missing = @($items | Where-Object { -not $defined.Contains($_) })
foreach ($m in $missing) { Bad "item '$m' is mapped but the codec does not define it" }
Write-Host "items not in the codec : $($missing.Count)"

# ... and every item the codec defines for a page must be reachable from the
# map. An unmapped item is legal (it simply does nothing), so this is a note,
# not a failure.
$mappedItems = @($items | Where-Object { $_ -match '^(Knob|Button) \d+ P\d+$' })
Write-Host "paged items in the map : $($mappedItems.Count) of $($pageCount * 16)"
Write-Host ""

# -----------------------------------------------------------------------------
# 4. Driver config <-> codec CC tables
# -----------------------------------------------------------------------------
$cfg = Get-Content -LiteralPath $cfgPath -Raw | ConvertFrom-Json
$encList = $cfg.Midi.Paging.EncoderCcs
$btnList = $cfg.Midi.Paging.ButtonCcs
$codecPairs = [regex]::Matches($lua, '\[0x([0-9a-f]{2})\]=(\d)') | ForEach-Object { $_.Groups[1].Value + '=' + $_.Groups[2].Value }
$mm = 0
for ($p = 0; $p -lt $cfg.Midi.Paging.Names.Count; $p++) {
    for ($n = 0; $n -lt 8; $n++) {
        if ($codecPairs -notcontains (('{0:x2}' -f $encList[$p*8+$n]) + '=' + ($n+1))) { Bad "encoder mismatch page $($p+1) dial $($n+1)"; $mm++ }
        if ($codecPairs -notcontains (('{0:x2}' -f $btnList[$p*8+$n]) + '=' + ($n+1))) { Bad "button mismatch page $($p+1) button $($n+1)"; $mm++ }
    }
}
Write-Host "codec CC entry count   : $($codecPairs.Count) (expect 64)"
Write-Host "driver/codec mismatch  : $mm"

# The codec mirrors the driver's page slot names. They are informational
# (the items are named "Knob n P<n>"), but a mismatch means the codec and
# the driver disagree about what a slot is called.
$codecNames = @()
$m = [regex]::Match($lua, 'gPageNames\s*=\s*\{([^}]*)\}')
if ($m.Success) {
    $codecNames = @($m.Groups[1].Value -split ',' | ForEach-Object { $_.Trim().Trim('"') } | Where-Object { $_ -ne '' })
}
$driverNames = @($cfg.Midi.Paging.Names)
if (($codecNames -join '|') -ne ($driverNames -join '|')) {
    Bad "the codec's gPageNames ($($codecNames -join ', ')) do not match the driver's Midi:Paging:Names ($($driverNames -join ', '))"
}
Write-Host "page slot names        : $($driverNames -join ', ')"
Write-Host ""

# -----------------------------------------------------------------------------
# 5. The codec must declare auto-inputs
# -----------------------------------------------------------------------------
# Reason only routes port MIDI into a codec through registered auto-inputs;
# remote_process_midi() is an ADDITIONAL hook, not a replacement for them.
# A codec with no define_auto_inputs() is silent in Reason - the surface
# appears and does nothing, with no error shown.
$hasAutoInputs = $lua -match 'define_auto_inputs'
if (-not $hasAutoInputs) { Bad "the codec declares no auto-inputs - Reason will not route MIDI to it" }
Write-Host "codec auto-inputs      : $(if ($hasAutoInputs) { 'declared' } else { 'MISSING' })"
Write-Host ""

# -----------------------------------------------------------------------------
# 6. Every scope needs a display name
# -----------------------------------------------------------------------------
# "Map _Scope" carries the scope's DISPLAY name (what Reason shows and what
# the codec reads back), which is not always the scope's model name.
foreach ($s in $mapScopes) {
    if (-not $scopeDisplay.ContainsKey($s) -or $scopeDisplay[$s] -eq '') {
        Bad "scope '$s' has no 'Map _Scope' display name"
    }
}
Write-Host "scopes with a name     : $(@($mapScopes | Where-Object { $scopeDisplay.ContainsKey($_) }).Count) of $($mapScopes.Count)"
Write-Host ""

# -----------------------------------------------------------------------------
# 7. The committed map must be what the generator produces
# -----------------------------------------------------------------------------
# The map is generated from pages/*.yaml. If the two drift apart, the map in
# the repo is not the map that was validated.
$gen = Join-Path $repo 'remote\scripts\generate_map.py'
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('Nocturn-' + [System.Guid]::NewGuid().ToString('N') + '.remotemap')
try {
    & python $gen --out $tmp --quiet | Out-Null
    if ($LASTEXITCODE -ne 0) { Bad "the generator reported errors" }
    $a = (Get-FileHash -LiteralPath $mapPath -Algorithm SHA256).Hash
    $b = (Get-FileHash -LiteralPath $tmp -Algorithm SHA256).Hash
    if ($a -ne $b) { Bad "the committed map is out of date - run: python remote\scripts\generate_map.py" }
    else { Write-Host "map matches generator  : yes" }
} finally {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
}
Write-Host ""

if ($problems -eq 0) { Write-Host 'MAP + CODEC + CONFIG: ALL CONSISTENT' }
else { Write-Host "PROBLEMS FOUND: $problems"; exit 1 }
