# Milestone 2 acceptance test for the nuts Nocturn driver.
#
#   Direction 1 (surface -> DAW): run without -SendLedTest, turn knobs and
#   press buttons on the Nocturn; decoded MIDI messages print live
#   (Ctrl+C to stop).
#
#   Direction 2 (DAW -> surface): run with -SendLedTest; watch the Nocturn
#   light up (page button 1 green, Learn red, encoder 1 ring full, speed
#   dial ring mid) and go dark again ~2s later.
#
# The nuts driver must be running (it owns the other end of the loopback
# endpoint and creates the endpoint on first start).

param(
    [string]$ModuleName = 'C:\Program Files\Windows MIDI Services\PowerShell\WindowsMidiServices\WindowsMidiServices.psd1',
    [string]$MonitorExe = 'C:\Program Files\Windows MIDI Services\Tools\midi.exe',
    [string]$EndpointName = 'Nocturn',
    [switch]$SendLedTest
)

$ErrorActionPreference = 'Stop'
Import-Module $ModuleName

$session = Start-MidiSession -Name 'nuts-test'
$ep = Get-MidiEndpointDeviceInfo | Where-Object { $_.Name -eq $EndpointName } | Select-Object -First 1
if (-not $ep) {
    throw "Endpoint '$EndpointName' not found. Is the nuts driver running? (It creates the loopback at startup.)"
}
$conn = Open-MidiEndpointConnection -Session $session -EndpointDeviceId $ep.EndpointDeviceId
Write-Host "Connected to '$EndpointName'."
Write-Host ""

if ($SendLedTest) {
    Write-Host "LED test: watch the Nocturn -- page button 1, Learn, encoder 1 ring, speed dial ring ..."
    Send-MidiMessage -Connection $conn -Words 0x2090007F   # note-on 0  -> page button 1 on
    Send-MidiMessage -Connection $conn -Words 0x2090087F   # note-on 8  -> Learn on
    Send-MidiMessage -Connection $conn -Words 0x20B0200B   # CC 32 = 11 -> encoder 1 ring full
    Send-MidiMessage -Connection $conn -Words 0x20B02805   # CC 40 = 5  -> speed dial ring mid
    Start-Sleep -Seconds 2
    Write-Host "Releasing ..."
    Send-MidiMessage -Connection $conn -Words 0x20900000   # note-off 0
    Send-MidiMessage -Connection $conn -Words 0x20900800   # note-off 8
    Send-MidiMessage -Connection $conn -Words 0x20B02000   # CC 32 = 0  -> ring empty
    Send-MidiMessage -Connection $conn -Words 0x20B02800   # CC 40 = 0  -> speed dial dark
    Start-Sleep -Milliseconds 500
    Write-Host "LED test done."
    Write-Host ""
}

Write-Host "Listening for surface input -- turn encoders, press buttons, use the"
Write-Host "speed dial and crossfader (Ctrl+C to stop):"
Write-Host ""
& $MonitorExe endpoint monitor $ep.EndpointDeviceId --verbose --include-timestamp --auto-reconnect
