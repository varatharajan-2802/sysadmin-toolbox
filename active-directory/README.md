
# Active Directory Health Check

Read-only PowerShell script for auditing Domain Controller health.

## What it checks
- Domain / Forest info and functional levels
- Per-DC: connectivity, core services, disk space, SYSVOL/NETLOGON access,
  time sync source, key DCDIAG tests, recent System/DS/DNS log errors
- Forest-wide: FSMO role holders, replication summary

## Usage
```powershell
.\AD_HealthCheck.ps1
.\AD_HealthCheck.ps1 -ReportPath "C:\Reports\ad_health.html"
```

## Requirements
- ActiveDirectory PowerShell module
- Run with Domain Admin (or equivalent read) rights

Entirely read-only — makes no configuration changes.
