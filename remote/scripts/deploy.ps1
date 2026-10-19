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

$RepoRoot   = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$RemoteRoot = Join-Path $env:ProgramData 'Propellerhead Software\Remote'
$BackupRoot = Join-Path $RepoRoot 'backups'

$Manufacturer = 'Nuts'
$CodecDest    = Join-Path $RemoteRoot "Codecs\Lua Codecs\$Manufacturer"
$MapsDest     = Join-Path $RemoteRoot "Maps\$Manufacturer"

$codecSrcDir = Join-Path $RepoRoot "Codecs\Lua Codecs\$Manufacturer"
$codecFiles  = @(Get-ChildItem -Path (Join-Path $codecSrcDir 'Nocturn.*') -ErrorAction SilentlyContinue)
$mapFiles    = Join-Path $RepoRoot "Maps\$Manufacturer\*.remotemap"

if (-not (Test-Path -LiteralPath $RemoteRoot)) {
    throw "Reason Remote folder not found: $RemoteRoot. Is Reason installed?"
}
if ($codecFiles.Count -eq 0) {
    throw "Codec files not found in $codecSrcDir (expected Nocturn.lua/.luacodec/.png)"
}
$foundMaps = @(Get-ChildItem -Path $mapFiles -ErrorAction SilentlyContinue)
if ($foundMaps.Count -eq 0) {
    throw "No .remotemap files found in $RepoRoot\Maps\$Manufacturer\"
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
    Write-Host "  Map    -> $dest" -ForegroundColor Green
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
