#Requires -Version 5.1
<#
.SYNOPSIS
    Deploys the "Nuts" Nocturn Remote codec and maps into Reason's Remote folder (Windows).

.DESCRIPTION
    The control surface is registered under the manufacturer "Nuts" (not
    "Novation"), so it is unmistakable in Reason's device list and cannot be
    confused with the factory Novation surfaces.

    Copies:
        Codecs/Lua Codecs/Nuts/Nocturn.lua
        Codecs/Lua Codecs/Nuts/Nocturn.luacodec
        Codecs/Lua Codecs/Nuts/Nocturn.png
            -> <ProgramData>\Propellerhead Software\Remote\Codecs\Lua Codecs\Nuts\
        Maps/Nuts/*.remotemap
            -> <ProgramData>\Propellerhead Software\Remote\Maps\Nuts\

    With -Backup, every file that is about to be overwritten is first copied
    into <repo>\backups\<timestamp>\ (same folder structure), so a bad deploy
    can be rolled back. The backups folder is git-ignored.

    Reason must be closed before running. Restart Reason afterwards and add
    the surface manually: Preferences > Control Surfaces > Add >
    Nuts > Nocturn, with the "Nocturn" port selected for BOTH MIDI Input
    and MIDI Output (that port is the nuts driver's loopback endpoint).

.PARAMETER Backup
    Back up the current Reason Remote files before overwriting them.
#>

[CmdletBinding()]
param(
    [switch]$Backup
)

$ErrorActionPreference = 'Stop'

# $PSScriptRoot is <repo>\remote\scripts, so '..' is the "remote" folder that
# holds Codecs/ and Maps/ - not the repository root.
$RemoteSource = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$RemoteRoot   = Join-Path $env:ProgramData 'Propellerhead Software\Remote'
$BackupRoot   = Join-Path $RemoteSource 'backups'

$Manufacturer = 'Nuts'
$CodecDest    = Join-Path $RemoteRoot "Codecs\Lua Codecs\$Manufacturer"
$MapsDest     = Join-Path $RemoteRoot "Maps\$Manufacturer"

$codecSrcDir = Join-Path $RemoteSource "Codecs\Lua Codecs\$Manufacturer"
$codecFiles  = @(Get-ChildItem -Path (Join-Path $codecSrcDir 'Nocturn.*') -ErrorAction SilentlyContinue)
$mapFiles    = Join-Path $RemoteSource "Maps\$Manufacturer\*.remotemap"

if (-not (Test-Path -LiteralPath $RemoteRoot)) {
    throw "Reason Remote folder not found: $RemoteRoot. Is Reason installed?"
}
if ($codecFiles.Count -eq 0) {
    throw "Codec files not found in $codecSrcDir (expected Nocturn.lua/.luacodec/.png)"
}
$foundMaps = @(Get-ChildItem -Path $mapFiles -ErrorAction SilentlyContinue)
if ($foundMaps.Count -eq 0) {
    throw "No .remotemap files found in $RemoteSource\Maps\$Manufacturer\"
}

# --- regenerate the map from pages/*.yaml -----------------------------------
# The .remotemap is generated (remote/scripts/generate_map.py) from the page
# templates in pages/. Regenerating here means a deploy can never ship a map
# that no longer matches the templates, and a template with a bad target is
# caught before it reaches Reason - one broken target makes Reason refuse the
# WHOLE surface.
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$generator = Join-Path $PSScriptRoot 'generate_map.py'
$workbook = Join-Path $RemoteSource 'mapping\reason-remote_full.xlsx'
if (-not (Test-Path -LiteralPath $workbook)) {
    throw "Reason target workbook not found: $workbook. Nothing was deployed."
}
if (-not (Test-Path -LiteralPath $generator)) {
    throw "generate_map.py not found: $generator. Nothing was deployed."
}

Write-Host "Validating pages\*.yaml against reason-remote_full.xlsx and generating the map ..." -ForegroundColor Cyan
& python $generator
if ($LASTEXITCODE -ne 0) {
    throw "generate_map.py reported errors - the map was NOT regenerated and nothing was deployed. Fix pages\*.yaml or the Reason workbook and run it again."
}

# --- optional backup of the files that will be overwritten ----------------
$backupRunDir = Join-Path $BackupRoot (Get-Date -Format 'yyyyMMdd-HHmmss')
$backedUp = @()

function Backup-One([string]$Path) {
    if (-not $Backup) { return }
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $rel = $Path.Substring($RemoteRoot.Length).TrimStart('\', '/')
    $target = Join-Path $backupRunDir $rel
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
    Copy-Item -LiteralPath $Path -Destination $target -Force
    $script:backedUp += $rel
}

Write-Host "Deploying to: $RemoteRoot" -ForegroundColor Cyan

New-Item -ItemType Directory -Force -Path $CodecDest, $MapsDest | Out-Null

foreach ($codec in $codecFiles) {
    $dest = Join-Path $CodecDest $codec.Name
    Backup-One $dest
    Copy-Item -LiteralPath $codec.FullName -Destination $dest -Force
    Write-Host "  Codec  -> $dest" -ForegroundColor Green
}

foreach ($map in $foundMaps) {
    $dest = Join-Path $MapsDest $map.Name
    Backup-One $dest
    Copy-Item -LiteralPath $map.FullName -Destination $dest -Force
    $scopeCount = @(Select-String -LiteralPath $map.FullName -Pattern '^Scope\t').Count
    Write-Host "  Map    -> $dest  ($scopeCount scopes)" -ForegroundColor Green
}

if ($Backup) {
    if ($backedUp.Count -gt 0) {
        Write-Host "Backed up $($backedUp.Count) file(s) to $backupRunDir" -ForegroundColor Yellow
    } else {
        Write-Host "Backup: no existing target files to back up (nothing overwritten)." -ForegroundColor Yellow
    }
}

Write-Host ""
Write-Host "Done. Close and reopen Reason, then add 'Nuts > Nocturn' under" -ForegroundColor Yellow
Write-Host "Preferences > Control Surfaces (it is added manually, not auto-detected)," -ForegroundColor Yellow
Write-Host "with the 'Nocturn' port selected for both MIDI Input and MIDI Output." -ForegroundColor Yellow
