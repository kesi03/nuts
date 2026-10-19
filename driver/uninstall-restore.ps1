#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Fully reverts the nuts WinUSB binding and restores Novation's
    NvnUsbAudio driver for the Nocturn.
#>
$ErrorActionPreference = 'Stop'

$dev = Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -like 'USB\VID_1235&PID_000A\*' }
if (-not $dev) { throw "Nocturn not found. Plug it in first." }

$infPath = (Get-PnpDeviceProperty -InstanceId $dev.InstanceId -KeyName 'DEVPKEY_Device_DriverInfPath').Data
Write-Host "Current driver package: $infPath"

if ($infPath -match '^oem\d+\.inf$') {
    Write-Host "Removing $infPath (our WinUSB package)..."
    pnputil /delete-driver $infPath /uninstall /force
}

# Rebind Novation's driver from its FileRepository copy.
$novInf = Get-ChildItem 'C:\Windows\System32\DriverStore\FileRepository' -Directory -Filter 'nvnusbaudio.inf_*' |
    ForEach-Object { Join-Path $_.FullName 'nvnusbaudio.inf' } | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $novInf) { throw "nvnusbaudio.inf not found in the DriverStore; reinstall the Novation driver from Unpacked." }

Write-Host "Restoring Novation driver: $novInf"
pnputil /add-driver $novInf /install
if ($LASTEXITCODE -ne 0) { throw "pnputil failed with exit code $LASTEXITCODE" }

Start-Sleep -Seconds 2
$dev = Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -like 'USB\VID_1235&PID_000A\*' }
$svc = (Get-PnpDeviceProperty -InstanceId $dev.InstanceId -KeyName 'DEVPKEY_Device_Service').Data
Write-Host "After restore: status=$($dev.Status) service=$svc  (expect NvnUsbAudio)"
Write-Host "Done. You can re-enable Secure Boot and resume BitLocker now."
