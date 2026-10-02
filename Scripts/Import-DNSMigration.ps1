#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Import a Windows DNS migration package.

.DESCRIPTION
    Imports standard primary zones, DNS resource records, forwarders,
    conditional forwarders, and produces validation reports.

    Use -WhatIfMode first to perform a dry run.

.NOTES
    Run as Administrator on the DESTINATION DNS server.
#>

param(
    [string]$MigrationPath = "C:\DNS-Migration",
    [switch]$WhatIfMode
)

$ErrorActionPreference = "Continue"

function Write-Section {
    param([string]$Message)
    Write-Host ""
    Write-Host "==============================================" -ForegroundColor Cyan
    Write-Host $Message -ForegroundColor Cyan
    Write-Host "==============================================" -ForegroundColor Cyan
}

function Write-Success { param([string]$Message); Write-Host "[SUCCESS] $Message" -ForegroundColor Green }
function Write-WarningMessage { param([string]$Message); Write-Host "[WARNING] $Message" -ForegroundColor Yellow }
function Write-Failure { param([string]$Message); Write-Host "[FAILED] $Message" -ForegroundColor Red }

Write-Section "WINDOWS DNS MIGRATION - IMPORT"

if ($WhatIfMode) {
    Write-Host "DRY RUN MODE ENABLED - no DNS changes will be made." -ForegroundColor Yellow
}

if (-not (Test-Path $MigrationPath)) {
    Write-Failure "Migration folder not found: $MigrationPath"
    exit 1
}

$InventoryFile = Join-Path $MigrationPath "ZoneInventory.csv"
$ZonePath = Join-Path $MigrationPath "Zones"
$RecordPath = Join-Path $MigrationPath "Records"
$ForwarderFile = Join-Path $MigrationPath "Forwarders.txt"
$ConditionalForwarderFile = Join-Path $MigrationPath "ConditionalForwarders.xml"

if (-not (Test-Path $InventoryFile)) {
    Write-Failure "ZoneInventory.csv not found."
    exit 1
}

if (-not (Get-Module -ListAvailable -Name DnsServer)) {
    Write-Failure "DnsServer PowerShell module is not installed."
    Write-Host "Install-WindowsFeature -Name RSAT-DNS-Server"
    exit 1
}

Import-Module DnsServer

$DnsFeature = Get-WindowsFeature -Name DNS -ErrorAction SilentlyContinue
if (-not $DnsFeature.Installed) {
    if ($WhatIfMode) {
        Write-Host "Would install DNS Server role." -ForegroundColor Yellow
    }
    else {
        Install-WindowsFeature -Name DNS -IncludeManagementTools
        Write-Success "DNS Server role installed."
    }
}

$DnsService = Get-Service -Name DNS -ErrorAction SilentlyContinue
if (-not $DnsService) {
    Write-Failure "DNS service not found."
    exit 1
}

if ($DnsService.Status -ne "Running" -and -not $WhatIfMode) {
    Start-Service DNS
}

$Inventory = Import-Csv $InventoryFile
$ZoneImportResults = @()
$RecordImportResults = @()
$ValidationResults = @()

Write-Section "IMPORTING DNS ZONES"

foreach ($Zone in $Inventory) {
    $ZoneName = $Zone.ZoneName
    Write-Host "Processing zone: $ZoneName" -ForegroundColor Cyan

    if ($Zone.IsDsIntegrated -eq "True") {
        Write-WarningMessage "$ZoneName is AD-integrated; skipping."
        $ZoneImportResults += [PSCustomObject]@{
            ZoneName = $ZoneName
            Status = "SKIPPED"
            Reason = "AD-integrated zone"
        }
        continue
    }

    $ZoneFile = Get-ChildItem -Path $ZonePath -Filter "*.dns" -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq "$ZoneName.dns" } |
        Select-Object -First 1

    if (-not $ZoneFile) {
        $SafeName = $ZoneName -replace '[\\/:*?"<>|]', '_'
        $ZoneFile = Get-ChildItem -Path $ZonePath -Filter "*.dns" -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -eq "$SafeName.dns" } |
            Select-Object -First 1
    }

    if (-not $ZoneFile) {
        Write-Failure "Zone file not found for $ZoneName"
        $ZoneImportResults += [PSCustomObject]@{
            ZoneName = $ZoneName
            Status = "FAILED"
            Reason = "Zone file not found"
        }
        continue
    }

    $ExistingZone = Get-DnsServerZone -Name $ZoneName -ErrorAction SilentlyContinue
    if ($ExistingZone) {
        Write-WarningMessage "Zone already exists: $ZoneName"
        $ZoneImportResults += [PSCustomObject]@{
            ZoneName = $ZoneName
            Status = "EXISTS"
            Reason = "Zone already exists"
        }
        continue
    }

    if ($WhatIfMode) {
        Write-Host "Would create zone: $ZoneName" -ForegroundColor Yellow
        $ZoneImportResults += [PSCustomObject]@{
            ZoneName = $ZoneName
            Status = "WHATIF"
            Reason = "Would create zone"
        }
        continue
    }

    $DestinationZoneFile = Join-Path "$env:SystemRoot\System32\dns" $ZoneFile.Name

    try {
        Copy-Item $ZoneFile.FullName $DestinationZoneFile -Force -ErrorAction Stop
        Add-DnsServerPrimaryZone `
            -Name $ZoneName `
            -ZoneFile $ZoneFile.Name `
            -DynamicUpdate None `
            -ErrorAction Stop

        Write-Success "Zone created: $ZoneName"

        $ZoneImportResults += [PSCustomObject]@{
            ZoneName = $ZoneName
            Status = "SUCCESS"
            Reason = "Zone created"
        }
    }
    catch {
        Write-Failure "Failed to create $ZoneName : $($_.Exception.Message)"
        $ZoneImportResults += [PSCustomObject]@{
            ZoneName = $ZoneName
            Status = "FAILED"
            Reason = $_.Exception.Message
        }
    }
}

Write-Section "IMPORTING DNS RESOURCE RECORDS"

if (Test-Path $RecordPath) {
    $RecordFiles = Get-ChildItem -Path $RecordPath -Filter "*.xml" -File

    foreach ($RecordFile in $RecordFiles) {
        $BaseName = $RecordFile.BaseName
        $ZoneName = $null

        foreach ($Zone in $Inventory) {
            $SafeName = $Zone.ZoneName -replace '[\\/:*?"<>|]', '_'
            if ($SafeName -eq $BaseName) {
                $ZoneName = $Zone.ZoneName
                break
            }
        }

        if (-not $ZoneName) {
            Write-Failure "Unable to determine zone for $($RecordFile.Name)"
            continue
        }

        $DestinationZone = Get-DnsServerZone -Name $ZoneName -ErrorAction SilentlyContinue
        if (-not $DestinationZone) {
            Write-Failure "Destination zone does not exist: $ZoneName"
            continue
        }

        try {
            $Records = @(Import-Clixml $RecordFile.FullName)
        }
        catch {
            Write-Failure "Unable to read $($RecordFile.Name): $($_.Exception.Message)"
            continue
        }

        $ImportedCount = 0
        $FailedCount = 0
        $SkippedCount = 0

        foreach ($Record in $Records) {
            if ($Record.RecordType -in @("SOA", "NS")) {
                $SkippedCount++
                continue
            }

            if ($WhatIfMode) {
                $ImportedCount++
                continue
            }

            try {
                Add-DnsServerResourceRecord `
                    -ZoneName $ZoneName `
                    -InputObject $Record `
                    -ErrorAction Stop

                $ImportedCount++
            }
            catch {
                $FailedCount++
                Write-WarningMessage "Failed record: $($Record.HostName) [$($Record.RecordType)] - $($_.Exception.Message)"
            }
        }

        Write-Host "$ZoneName -> Imported: $ImportedCount | Skipped: $SkippedCount | Failed: $FailedCount"

        $RecordImportResults += [PSCustomObject]@{
            ZoneName = $ZoneName
            TotalRecords = $Records.Count
            Imported = $ImportedCount
            Skipped = $SkippedCount
            Failed = $FailedCount
        }
    }
}

Write-Section "IMPORTING DNS FORWARDERS"

if (Test-Path $ForwarderFile) {
    $ForwarderIPs = @(Get-Content $ForwarderFile | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    if ($ForwarderIPs.Count -gt 0 -and -not $WhatIfMode) {
        try {
            Set-DnsServerForwarder -IPAddress $ForwarderIPs -UseRootHint $true -ErrorAction Stop
            Write-Success "DNS forwarders configured."
        }
        catch {
            Write-Failure "Failed to configure forwarders: $($_.Exception.Message)"
        }
    }
}

Write-Section "IMPORTING CONDITIONAL FORWARDERS"

if (Test-Path $ConditionalForwarderFile) {
    try {
        $ConditionalForwarders = @(Import-Clixml $ConditionalForwarderFile)

        foreach ($CF in $ConditionalForwarders) {
            $DomainName = $CF.Name

            if ($WhatIfMode) {
                Write-Host "Would create conditional forwarder: $DomainName" -ForegroundColor Yellow
                continue
            }

            try {
                $ExistingCF = Get-DnsServerConditionalForwarderZone -Name $DomainName -ErrorAction SilentlyContinue

                if ($ExistingCF) {
                    Write-WarningMessage "Conditional forwarder already exists: $DomainName"
                    continue
                }

                $MasterServers = @(
                    $CF.MasterServers |
                    ForEach-Object { $_.IPAddressToString }
                )

                Add-DnsServerConditionalForwarderZone `
                    -Name $DomainName `
                    -MasterServers $MasterServers `
                    -ReplicationScope None `
                    -ErrorAction Stop

                Write-Success "Conditional forwarder created: $DomainName"
            }
            catch {
                Write-Failure "Failed conditional forwarder $DomainName : $($_.Exception.Message)"
            }
        }
    }
    catch {
        Write-Failure "Unable to read ConditionalForwarders.xml: $($_.Exception.Message)"
    }
}

if (-not $WhatIfMode) {
    Write-Section "REGISTERING DESTINATION DNS"
    ipconfig /registerdns | Out-Null
    Start-Sleep -Seconds 3
    Restart-Service DNS
    Start-Sleep -Seconds 5
}

Write-Section "VALIDATING DNS ZONES"

$DestinationZones = Get-DnsServerZone

foreach ($Zone in $Inventory) {
    $ZoneName = $Zone.ZoneName
    $FoundZone = $DestinationZones | Where-Object { $_.ZoneName -eq $ZoneName }

    if ($FoundZone) {
        Write-Success "Zone exists: $ZoneName"
        $ValidationResults += [PSCustomObject]@{
            ZoneName = $ZoneName
            Status = "PASS"
            Details = "Zone exists"
        }
    }
    else {
        Write-Failure "Zone missing: $ZoneName"
        $ValidationResults += [PSCustomObject]@{
            ZoneName = $ZoneName
            Status = "FAIL"
            Details = "Zone missing"
        }
    }
}

Write-Section "VALIDATING SOA RECORDS"

foreach ($Zone in $Inventory) {
    $ZoneName = $Zone.ZoneName

    try {
        $SOA = Get-DnsServerResourceRecord -ZoneName $ZoneName -RRType SOA -ErrorAction Stop

        if ($SOA) {
            Write-Host ""
            Write-Host "Zone: $ZoneName" -ForegroundColor Cyan
            Write-Host "Primary Server: $($SOA.RecordData.PrimaryServer)"
            Write-Success "SOA record found."
        }
    }
    catch {
        Write-WarningMessage "Unable to read SOA for $ZoneName"
    }
}

Write-Section "CREATING MIGRATION REPORT"

$ReportPath = Join-Path $MigrationPath "ImportReport"
New-Item -ItemType Directory -Path $ReportPath -Force | Out-Null

$ZoneImportResults |
    Export-Csv (Join-Path $ReportPath "ZoneImportResults.csv") -NoTypeInformation -Encoding UTF8

$RecordImportResults |
    Export-Csv (Join-Path $ReportPath "RecordImportResults.csv") -NoTypeInformation -Encoding UTF8

$ValidationResults |
    Export-Csv (Join-Path $ReportPath "ValidationResults.csv") -NoTypeInformation -Encoding UTF8

$SuccessfulZones = @($ZoneImportResults | Where-Object Status -eq "SUCCESS").Count
$FailedZones = @($ZoneImportResults | Where-Object Status -eq "FAILED").Count
$SkippedZones = @($ZoneImportResults | Where-Object Status -eq "SKIPPED").Count
$TotalImportedRecords = @($RecordImportResults | Measure-Object -Property Imported -Sum).Sum
$TotalFailedRecords = @($RecordImportResults | Measure-Object -Property Failed -Sum).Sum

Write-Section "DNS MIGRATION SUMMARY"

Write-Host "Destination Server : $env:COMPUTERNAME"
Write-Host "Zones Successful   : $SuccessfulZones" -ForegroundColor Green
Write-Host "Zones Failed       : $FailedZones" -ForegroundColor Red
Write-Host "Zones Skipped      : $SkippedZones" -ForegroundColor Yellow
Write-Host "Records Imported   : $TotalImportedRecords" -ForegroundColor Green
Write-Host "Records Failed     : $TotalFailedRecords" -ForegroundColor Red
Write-Host "Reports            : $ReportPath"

Write-Host ""
Write-Host "DNS IMPORT COMPLETED" -ForegroundColor Green
