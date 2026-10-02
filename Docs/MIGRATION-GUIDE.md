# DNS Migration Guide

## Pre-migration checklist

- [ ] Confirm source DNS server
- [ ] Confirm destination server
- [ ] Confirm DNS Server role/module
- [ ] Confirm zones are standard primary zones
- [ ] Check AD-integrated zones separately
- [ ] Record current DNS server IP
- [ ] Record forwarders
- [ ] Record conditional forwarders
- [ ] Confirm backup exists
- [ ] Schedule maintenance window if required

## Source

Run:

```powershell
.\Export-DNSMigration.ps1
```

Review:

```text
C:\DNS-Migration\ExportResults.csv
```

Do not continue if important zones show `FAILED`.

## Destination

Copy the package and run:

```powershell
.\Import-DNSMigration.ps1 -WhatIfMode
```

Then:

```powershell
.\Import-DNSMigration.ps1
```

## Validation

```powershell
Get-DnsServerZone
```

```powershell
Get-DnsServerForwarder
```

```powershell
Get-DnsServerResourceRecord -ZoneName "example.com"
```

```powershell
Resolve-DnsName example.com -Server <DESTINATION-IP>
```

For mail:

```powershell
Resolve-DnsName example.com -Type MX -Server <DESTINATION-IP>
```

For TXT:

```powershell
Resolve-DnsName example.com -Type TXT -Server <DESTINATION-IP>
```

For SRV:

```powershell
Resolve-DnsName _sip._tcp.example.com -Type SRV -Server <DESTINATION-IP>
```

## Cutover

Only after successful validation should the production DNS IP/delegation be changed.

Keep the source DNS server intact until the migration has been confirmed.
