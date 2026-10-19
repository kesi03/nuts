#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Binds WinUSB to the Novation Nocturn - no Zadig, no downloads.
.DESCRIPTION
    1. Verifies Secure Boot is OFF (self-signed driver packages are rejected
       with Secure Boot ON; that is an OS constraint, not a Zadig one).
    2. Creates (or reuses) a self-signed code-signing cert and trusts it
       locally (Root + TrustedPublisher), like Zadig's libwdi does.
    3. Stages the package, builds a catalog (New-FileCatalog), signs it.
    4. pnputil /add-driver /install - binds WinUSB to the device.
    5. Verifies the device switched from NvnUsbAudio to the WinUSB service.
.NOTES
    Contingency: if pnputil rejects the New-FileCatalog catalog under
    current enforcement, build it with Inf2Cat from the WDK instead - the
    rest of this script is unaffected.
#>
param(
    [string]$PackageDir = $PSScriptRoot,
    [string]$CertSubject = 'CN=nuts WinUSB Signing'
)
$ErrorActionPreference = 'Stop'

# --- 0. Guards ---------------------------------------------------------------
try { $secureBoot = Confirm-SecureBootUEFI } catch { $secureBoot = $null }
if ($secureBoot -eq $true) {
    throw "Secure Boot is ON. Self-signed driver packages cannot install. " +
          "Suspend BitLocker (Suspend-BitLocker -MountPoint C: -RebootCount 2), " +
          "reboot into UEFI firmware, disable Secure Boot, boot back, re-run this."
}

$dev = Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -like 'USB\VID_1235&PID_000A\*' }
if (-not $dev) { throw "Nocturn not found. Plug it in (and do NOT run AutoMap)." }
$currentService = (Get-PnpDeviceProperty -InstanceId $dev.InstanceId -KeyName 'DEVPKEY_Device_Service').Data
Write-Host "Nocturn: $($dev.InstanceId)  service=$currentService"

# --- 1. Signing certificate (machine store, reused across runs) --------------
$cert = Get-ChildItem Cert:\LocalMachine\My |
    Where-Object { $_.Subject -eq $CertSubject -and $_.HasPrivateKey -and $_.NotAfter -gt (Get-Date) } |
    Sort-Object NotAfter -Descending | Select-Object -First 1
if (-not $cert) {
    $cert = New-SelfSignedCertificate -Type CodeSigningCert -Subject $CertSubject `
        -CertStoreLocation Cert:\LocalMachine\My -KeyExportPolicy NonExportable `
        -NotAfter (Get-Date).AddYears(5)
    Write-Host "Created signing cert $($cert.Thumbprint)"
}
foreach ($store in 'Root', 'TrustedPublisher') {
    $target = "Cert:\LocalMachine\$store"
    if (-not (Get-ChildItem $target | Where-Object { $_.Thumbprint -eq $cert.Thumbprint })) {
        $tmp = Join-Path $env:TEMP 'nuts-signing.cer'
        Export-Certificate -Cert $cert -FilePath $tmp -Force | Out-Null
        Import-Certificate -FilePath $tmp -CertStoreLocation $target | Out-Null
        Remove-Item $tmp
        Write-Host "Trusted cert in LocalMachine\$store"
    }
}

# --- 2. Stage package + catalog + sign ---------------------------------------
$stage = Join-Path $env:TEMP 'nuts-nocturn-pkg'
Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
New-Item $stage -ItemType Directory | Out-Null
$inf = Join-Path $stage 'nocturn-winusb.inf'
Copy-Item (Join-Path $PackageDir 'nocturn-winusb.inf') $inf

$cat = Join-Path $stage 'nocturn-winusb.cat'
New-FileCatalog -Path $stage -CatalogFilePath $cat -CatalogVersion 2.0 | Out-Null
Set-AuthenticodeSignature -FilePath $cat -Cert $cert -HashAlgorithm SHA256 | Out-Null
$sig = Get-AuthenticodeSignature $cat
if ($sig.Status -ne 'Valid') { throw "Catalog signature invalid: $($sig.Status) - $($sig.StatusMessage)" }
Write-Host "Catalog signed."

# --- 3. Install ---------------------------------------------------------------
Write-Host "Installing driver package..."
pnputil /add-driver $inf /install
if ($LASTEXITCODE -ne 0) { throw "pnputil failed with exit code $LASTEXITCODE" }

# --- 4. Verify ----------------------------------------------------------------
Start-Sleep -Seconds 2
$dev = Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -like 'USB\VID_1235&PID_000A\*' }
if ($dev) {
    $svc = (Get-PnpDeviceProperty -InstanceId $dev.InstanceId -KeyName 'DEVPKEY_Device_Service').Data
    $status = $dev.Status
    Write-Host "After swap: status=$status service=$svc"
    if ($svc -eq 'winusb') { Write-Host "SUCCESS - raw USB access is available." -ForegroundColor Green }
    else { Write-Host "Device did not switch to winusb yet; unplug/replug, or check Event Viewer." -ForegroundColor Yellow }
}
