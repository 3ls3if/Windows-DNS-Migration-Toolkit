# Windows DNS Migration Toolkit

PowerShell toolkit for migrating standard primary DNS zones from one Windows Server DNS server to another.

## Features

- Export standard primary DNS zones
- Export `.dns` zone files
- Export DNS resource records
- Export DNS forwarders
- Export conditional forwarders
- Generate migration metadata
- Import zones on the destination server
- Import DNS resource records
- Restore forwarders
- Restore conditional forwarders
- Dry-run import mode
- Generate import and validation reports
- Skip built-in Windows DNS zones

## Supported scenario

This project is intended primarily for migrations involving **standard primary DNS zones**.

Example:

```text
Windows Server 2019 DNS
        |
        | Export
        v
DNS Migration Package
        |
        | Copy
        v
Windows Server 2019/2022/2025 DNS
        |
        | Import
        v
Migrated DNS zones
```

## Important

This toolkit does **not** blindly import the exported registry file into the destination server.

The registry export is retained as a reference/backup artifact. DNS servers contain machine-specific settings, so blindly merging the source DNS registry into another server is not recommended.

AD-integrated zones require a different migration approach because their zone data is stored in Active Directory.

## Requirements

- Windows Server with DNS Server role or DNS management tools
- PowerShell 5.1 or later
- Administrator privileges
- `DnsServer` PowerShell module
- Source server access
- Destination server access

Check the module:

```powershell
Get-Module -ListAvailable -Name DnsServer
```

If required:

```powershell
Install-WindowsFeature -Name RSAT-DNS-Server
```

## Project structure

```text
Windows-DNS-Migration-Toolkit/
│
├── Scripts/
│   ├── Export-DNSMigration.ps1
│   └── Import-DNSMigration.ps1
│
├── Docs/
│   └── MIGRATION-GUIDE.md
│
├── Examples/
│   └── README.md
│
├── .gitignore
├── LICENSE
└── README.md
```

## Step 1 - Export from source

Copy `Scripts\Export-DNSMigration.ps1` to the source DNS server.

Run PowerShell as Administrator:

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
.\Export-DNSMigration.ps1
```

Default output:

```text
C:\DNS-Migration
```

To specify another location:

```powershell
.\Export-DNSMigration.ps1 -OutputPath "D:\DNS-Migration"
```

## Exported files

The export package looks like:

```text
C:\DNS-Migration
│
├── ZoneInventory.csv
├── ExportResults.csv
├── MigrationInfo.json
├── DNS-Server-Registry.reg
├── Forwarders.txt
├── ConditionalForwarders.xml
│
├── Zones/
│   ├── example.com.dns
│   └── ...
│
└── Records/
    ├── example.com.xml
    └── ...
```

## Step 2 - Copy the migration package

Copy the complete `C:\DNS-Migration` directory to the destination server.

For example:

```text
C:\DNS-Migration
```

Do not copy only the `.dns` files. The inventory and record files are also required.

## Step 3 - Perform a dry run

On the destination server:

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
.\Import-DNSMigration.ps1 -WhatIfMode
```

Review the output before performing the actual migration.

## Step 4 - Import

Run:

```powershell
.\Import-DNSMigration.ps1
```

Or:

```powershell
.\Import-DNSMigration.ps1 -MigrationPath "D:\DNS-Migration"
```

## Step 5 - Validate

Check zones:

```powershell
Get-DnsServerZone
```

Check records:

```powershell
Get-DnsServerResourceRecord -ZoneName "example.com"
```

Check forwarders:

```powershell
Get-DnsServerForwarder
```

Check SOA:

```powershell
Get-DnsServerResourceRecord -ZoneName "example.com" -RRType SOA
```

Test resolution through the new DNS server:

```powershell
Resolve-DnsName example.com -Server <DESTINATION-DNS-IP>
```

Test a specific record:

```powershell
Resolve-DnsName www.example.com -Server <DESTINATION-DNS-IP>
```

## Reports

The import script creates:

```text
C:\DNS-Migration\ImportReport\
│
├── ZoneImportResults.csv
├── RecordImportResults.csv
└── ValidationResults.csv
```

These files can be retained as migration evidence.

## Built-in zones excluded

The export script excludes:

```text
0.in-addr.arpa
127.in-addr.arpa
255.in-addr.arpa
TrustAnchors
```

These are not treated as customer/application DNS zones.

## AD-integrated zones

If a zone has:

```text
IsDsIntegrated = True
```

do not use this toolkit as the primary migration mechanism.

For AD-integrated DNS, install DNS on the new domain controller/member server as appropriate and allow Active Directory replication to provide the zone data.

## Production migration recommendation

Before changing the production DNS IP:

1. Export the source DNS.
2. Copy the migration package.
3. Install DNS on the destination.
4. Perform a dry run.
5. Import the zones.
6. Validate zone and record counts.
7. Test A, CNAME, MX, TXT, SRV and PTR records as applicable.
8. Test SOA and NS records.
9. Test forwarders.
10. Test application name resolution.
11. Only then move the production IP/DNS delegation as appropriate.
12. Keep the source server available for rollback until the migration is confirmed.

## Security

The migration package may contain internal DNS information, hostnames, IP addresses, TXT records and other infrastructure information.

Do not commit real customer migration packages to a public GitHub repository.

Recommended:

```text
GitHub repository
    └── Scripts + documentation only

Customer environment
    └── C:\DNS-Migration
        ├── actual zone files
        ├── actual DNS records
        └── migration reports
```

## License

MIT License. See `LICENSE`.

## Disclaimer

Test the toolkit in a lab before using it for production DNS migration. DNS migrations can affect application connectivity, mail delivery, authentication, domain resolution and other services.
