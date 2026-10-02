#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Export Windows DNS zones for migration.

.DESCRIPTION
    Exports standard primary DNS zones, zone files, resource records,
    forwarders, conditional forwarders, and migration metadata.

    Built-in zones are excluded:
      0.in-addr.arpa
      127.in-addr.arpa
      255.in-addr.arpa
      TrustAnchors

.NOTES
    Run as Administrator on the SOURCE DNS server.
#>

param(
    [string]$OutputPath = "C:\DNS-Migration"
)

$ErrorActionPreference = "Continue"

Write-Host ""
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "      WINDOWS DNS MIGRATION - EXPORT" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""

$ZonePath   = Join-Path $OutputPath "Zones"
$RecordPath = Join-Path $OutputPath "Records"

New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
New-Item -ItemType Directory -Path $ZonePath -Force | Out-Null
New-Item -ItemType Directory -Path $RecordPath -Force | Out-Null

if (-not (Get-Module -ListAvailable -Name DnsServer)) {
    Write-Host "ERROR: DnsServer PowerShell module is not installed." -ForegroundColor Red
    Write-Host "Install-WindowsFeature -Name RSAT-DNS-Server"
    exit 1
}

Import-Module DnsServer

$DnsService = Get-Service -Name DNS -ErrorAction SilentlyContinue
if (-not $DnsService) {
    Write-Host "ERROR: DNS Server service not found." -ForegroundColor Red
    exit 1
}

$AllZones = Get-DnsServerZone

$ExcludedZones = @(
    "0.in-addr.arpa",
    "127.in-addr.arpa",
    "255.in-addr.arpa",
    "TrustAnchors"
)

$Zones = $AllZones | Where-Object {
    $_.ZoneName -notin $ExcludedZones -and
    $_.ZoneType -eq "Primary"
}

$Zones |
    Select-Object ZoneName, ZoneType, IsDsIntegrated, IsReverseLookupZone, DynamicUpdate |
    Export-Csv (Join-Path $OutputPath "ZoneInventory.csv") -NoTypeInformation -Encoding UTF8

$ZoneResults = @()

foreach ($Zone in $Zones) {
    $ZoneName = $Zone.ZoneName
    Write-Host "Processing zone: $ZoneName" -ForegroundColor Cyan

    try {
        $ZoneDetails = Get-DnsServerZone -Name $ZoneName -ErrorAction Stop
        $ZoneFile = $ZoneDetails.ZoneFile

        if ([string]::IsNullOrWhiteSpace($ZoneFile)) {
            Write-Warning "No zone file configured for $ZoneName"
            $ZoneResults += [PSCustomObject]@{
                ZoneName = $ZoneName
                Status = "FAILED"
                Reason = "No zone file configured"
            }
            continue
        }

        $SourceFile = Join-Path "$env:SystemRoot\System32\dns" $ZoneFile

        if (-not (Test-Path $SourceFile)) {
            Write-Warning "Zone file not found: $SourceFile"
            $ZoneResults += [PSCustomObject]@{
                ZoneName = $ZoneName
                Status = "FAILED"
                Reason = "Zone file not found"
            }
            continue
        }

        Copy-Item $SourceFile $ZonePath -Force -ErrorAction Stop
        Write-Host "  Exported zone file: $ZoneFile" -ForegroundColor Green

        $SafeName = $ZoneName -replace '[\\/:*?"<>|]', '_'
        $RecordFile = Join-Path $RecordPath "$SafeName.xml"

        try {
            $Records = Get-DnsServerResourceRecord -ZoneName $ZoneName -ErrorAction Stop
            $Records | Export-Clixml $RecordFile -Depth 10
            $RecordCount = @($Records).Count
            Write-Host "  Exported records: $RecordCount" -ForegroundColor Green
        }
        catch {
            Write-Warning "Unable to export records for $ZoneName : $($_.Exception.Message)"
            $RecordCount = 0
        }

        $ZoneResults += [PSCustomObject]@{
            ZoneName = $ZoneName
            ZoneFile = $ZoneFile
            ZoneType = $ZoneDetails.ZoneType
            IsDsIntegrated = $ZoneDetails.IsDsIntegrated
            ReverseZone = $ZoneDetails.IsReverseLookupZone
            RecordCount = $RecordCount
            Status = "SUCCESS"
        }
    }
    catch {
        Write-Warning "Failed to export $ZoneName : $($_.Exception.Message)"
        $ZoneResults += [PSCustomObject]@{
            ZoneName = $ZoneName
            Status = "FAILED"
            Reason = $_.Exception.Message
        }
    }
}

$ZoneResults |
    Export-Csv (Join-Path $OutputPath "ExportResults.csv") -NoTypeInformation -Encoding UTF8

Write-Host "Exporting DNS registry configuration..." -ForegroundColor Yellow
$RegistryBackup = Join-Path $OutputPath "DNS-Server-Registry.reg"
reg.exe export "HKLM\System\CurrentControlSet\Services\DNS" $RegistryBackup /y | Out-Null

Write-Host "Exporting DNS forwarders..." -ForegroundColor Yellow
try {
    $Forwarders = Get-DnsServerForwarder -ErrorAction Stop
    $Forwarders |
        Select-Object -ExpandProperty IPAddress |
        ForEach-Object { $_.IPAddressToString } |
        Set-Content (Join-Path $OutputPath "Forwarders.txt") -Encoding UTF8
}
catch {
    Write-Warning "Forwarder export failed: $($_.Exception.Message)"
}

Write-Host "Exporting conditional forwarders..." -ForegroundColor Yellow
try {
    Get-DnsServerConditionalForwarderZone -ErrorAction Stop |
        Export-Clixml (Join-Path $OutputPath "ConditionalForwarders.xml")
}
catch {
    Write-Warning "No conditional forwarders found or export failed."
}

$OS = Get-CimInstance Win32_OperatingSystem
$MigrationInfo = [PSCustomObject]@{
    SourceServer = $env:COMPUTERNAME
    SourceFQDN = [System.Net.Dns]::GetHostByName($env:COMPUTERNAME).HostName
    ExportDate = Get-Date
    WindowsVersion = $OS.Caption
    WindowsBuild = $OS.BuildNumber
    PowerShellVersion = $PSVersionTable.PSVersion.ToString()
    ZoneCount = @($Zones).Count
    SuccessfulZones = @($ZoneResults | Where-Object Status -eq "SUCCESS").Count
    FailedZones = @($ZoneResults | Where-Object Status -eq "FAILED").Count
}

$MigrationInfo |
    ConvertTo-Json |
    Set-Content (Join-Path $OutputPath "MigrationInfo.json") -Encoding UTF8

Write-Host ""
Write-Host "DNS EXPORT COMPLETED" -ForegroundColor Green
Write-Host "Export location: $OutputPath"
Write-Host "Successful zones: $($MigrationInfo.SuccessfulZones)"
Write-Host "Failed zones: $($MigrationInfo.FailedZones)"
